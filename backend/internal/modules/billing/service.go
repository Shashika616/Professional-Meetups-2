// Package billing is the credits module (plan 29 §3, ADR-010): wallets,
// lots, the ledger, pricing, entitlements, the refund policy, and (29B)
// store purchases, subscriptions and the catalog.
//
// It owns the `billing` schema and nothing else. Other modules reach it
// through ports they define themselves — the meetup module's
// CreationCharger, implemented by an adapter in cmd/monolith — and through
// outbox events, never by reading its tables.
package billing

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/billing/pricing"
	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/flags"
)

// HostingTrustLevel is the level at which a user can host, and so the level
// that earns the welcome grant (D1). It mirrors the meetup module's host bar;
// billing never grants anything for a level below it.
const HostingTrustLevel = 3

// rulesCacheTTL matches the flags cache: a price change is live everywhere
// within 30 seconds.
const rulesCacheTTL = 30 * time.Second

// IdentityFingerprint returns a stable, keyed hash of the user's verified
// phone number (or, failing that, verified personal email), or "" when they
// have neither. Implemented by an adapter over the auth module; billing never
// sees the phone number or the address itself.
type IdentityFingerprint interface {
	Fingerprint(ctx context.Context, userID string) (string, error)
}

// FlagEvaluator is the slice of the flags service billing needs: whether
// plans are shown to a caller, and whether a caller is one of the test
// accounts on that flag's allowlist (sandbox purchases, plan 29 §6).
type FlagEvaluator interface {
	Enabled(ctx context.Context, key string, subject flags.Subject) (bool, error)
	Allowlisted(ctx context.Context, key string, subject flags.Subject) (bool, error)
}

// Store is the stores, as billing uses them.
type Store interface {
	store.Verifier
	store.Finisher
}

// PushVerifier authenticates a Google RTDN push request.
type PushVerifier interface {
	Verify(ctx context.Context, authorization string) (jwt.MapClaims, error)
}

// Caller is who a request is for. TrustLevel comes from the verified JWT,
// passed down by the gateway, never from the request body.
type Caller struct {
	UserID     string
	TrustLevel int
}

// Deps groups the module's dependencies.
type Deps struct {
	Pool         *pgxpool.Pool
	Fingerprints IdentityFingerprint
	Config       config.Config
	Flags        FlagEvaluator
	// Store verifies and finishes purchases. Nil fails every purchase
	// closed (store.Unconfigured).
	Store Store
	// AppleRoots anchors Apple's signatures (the embedded Apple root in
	// production; a test root in tests).
	AppleRoots *x509.CertPool
	// GooglePush authenticates RTDN. Nil refuses every Google webhook.
	GooglePush PushVerifier
	// Now is the server clock. Nil means time.Now.
	Now    func() time.Time
	Logger *slog.Logger
}

// Service is the billing module.
type Service struct {
	pool         *pgxpool.Pool
	q            *sqlcgen.Queries
	ledger       *wallet.Ledger
	fingerprints IdentityFingerprint
	cfg          config.Config
	flags        FlagEvaluator
	store        Store
	appleRoots   *x509.CertPool
	googlePush   PushVerifier
	now          func() time.Time
	logger       *slog.Logger

	mu            sync.Mutex
	rules         pricing.Rules
	rulesLoadedAt time.Time
}

// New constructs the billing Service.
func New(d Deps) *Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	logger := d.Logger
	if logger == nil {
		logger = slog.Default()
	}
	st := d.Store
	if st == nil {
		st = store.Unconfigured{}
	}
	return &Service{
		pool:         d.Pool,
		q:            sqlcgen.New(d.Pool),
		ledger:       wallet.New(d.Pool, now, logger),
		fingerprints: d.Fingerprints,
		cfg:          d.Config,
		flags:        d.Flags,
		store:        st,
		appleRoots:   d.AppleRoots,
		googlePush:   d.GooglePush,
		now:          now,
		logger:       logger,
	}
}

// Config is the module's settings, for /v1/app-config.
func (s *Service) Config() config.Config { return s.cfg }

// Rules returns the active price rules, cached for 30 seconds. A failed
// reload keeps the previous copy; with nothing loaded yet it is an error,
// never a default price.
func (s *Service) Rules(ctx context.Context) (pricing.Rules, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.rules.Version != 0 && s.now().Sub(s.rulesLoadedAt) < rulesCacheTTL {
		return s.rules, nil
	}
	row, err := s.q.GetActivePriceRules(ctx)
	if err == nil {
		var parsed pricing.Rules
		parsed, err = pricing.Parse(int(row.Version), row.Document)
		if err == nil {
			s.rules, s.rulesLoadedAt = parsed, s.now()
			return parsed, nil
		}
	}
	if s.rules.Version != 0 {
		s.logger.Error("billing: price rules reload failed, keeping the previous version", "error", err)
		return s.rules, nil
	}
	return pricing.Rules{}, fmt.Errorf("billing: load price rules: %w: %w", apperror.ErrInternal, err)
}

// subscription is a user's active plan, when they have one.
type subscription struct {
	PlanCode string
	Status   string
	// PeriodStart is the start of the current quota window: the monthly
	// slice of the billing period the clock is in (quotaWindowStart), so a
	// yearly plan includes its meetups every month, not once a year.
	PeriodStart     time.Time
	PeriodEnd       time.Time
	MeetupsIncluded int
	MaxCapacity     int
	MaxAdvanceDays  int
}

func (s *Service) activeSubscription(ctx context.Context, q *sqlcgen.Queries, userID uuid.UUID, now time.Time) (*subscription, error) {
	row, err := q.GetActiveSubscription(ctx, sqlcgen.GetActiveSubscriptionParams{UserID: userID, Now: ts(now)})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("billing: read subscription: %w", err)
	}
	return &subscription{
		PlanCode:        row.PlanCode,
		Status:          row.Status,
		PeriodStart:     quotaWindowStart(row.CurrentPeriodStart.Time, now),
		PeriodEnd:       row.CurrentPeriodEnd.Time,
		MeetupsIncluded: int(row.MeetupsIncluded),
		MaxCapacity:     int(row.MaxCapacity),
		MaxAdvanceDays:  int(row.MaxAdvanceDays),
	}, nil
}

// quotaWindowStart is the latest start+k months that is not after now.
// Months are counted from start each time (never by adding to the previous
// window), so the window never drifts across short months.
func quotaWindowStart(start, now time.Time) time.Time {
	w := start
	for k := 1; ; k++ {
		next := start.AddDate(0, k, 0)
		if next.After(now) {
			return w
		}
		w = next
	}
}

func parseUser(userID string) (uuid.UUID, error) {
	id, err := uuid.Parse(userID)
	if err != nil {
		return uuid.Nil, fmt.Errorf("billing: invalid user id: %w", apperror.ErrUnauthorized)
	}
	return id, nil
}
