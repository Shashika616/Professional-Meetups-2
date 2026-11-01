package billing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/pricing"
	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/flags"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// Limits is how big and how far ahead this user may schedule right now.
type Limits struct {
	MaxCapacity    int
	MaxAdvanceDays int
}

// Quote is what creating one meetup would cost this user now (plan 3.3).
type Quote struct {
	// Cost is what will be charged: 0 inside a plan's quota.
	Cost int64
	// WouldCost is the price list's answer regardless of plans, so the app
	// can show what a plan saves.
	WouldCost        int64
	Breakdown        pricing.Breakdown
	PriceVersion     int
	CoveredByPlan    bool
	BalanceAvailable int64
	Limits           Limits
}

// Entitlements is what the user's plan, or the lack of one, allows (plan
// 3.4). The app reads its limits from here instead of hard-coding them.
type Entitlements struct {
	PlanCode        string
	PlanStatus      string
	PeriodEnd       time.Time
	Limits          Limits
	MeetupsIncluded int
	MeetupsUsed     int
}

// limitsFor is the single place the limits are decided: the plan's, or the
// price list's free limits without one.
func limitsFor(rules pricing.Rules, sub *subscription) Limits {
	if sub != nil {
		return Limits{MaxCapacity: sub.MaxCapacity, MaxAdvanceDays: sub.MaxAdvanceDays}
	}
	return Limits{MaxCapacity: rules.Doc.Free.MaxCapacity, MaxAdvanceDays: rules.Doc.Free.MaxAdvanceDays}
}

// Entitlements reports the caller's plan and limits.
func (s *Service) Entitlements(ctx context.Context, caller Caller) (Entitlements, error) {
	uid, err := parseUser(caller.UserID)
	if err != nil {
		return Entitlements{}, err
	}
	s.ensureWelcome(ctx, caller)
	rules, err := s.Rules(ctx)
	if err != nil {
		return Entitlements{}, err
	}
	sub, err := s.activeSubscription(ctx, s.q, uid, s.now())
	if err != nil {
		return Entitlements{}, err
	}
	out := Entitlements{Limits: limitsFor(rules, sub)}
	if sub != nil {
		out.PlanCode, out.PlanStatus, out.PeriodEnd = sub.PlanCode, sub.Status, sub.PeriodEnd
		out.MeetupsIncluded = sub.MeetupsIncluded
		used, err := s.planUsed(ctx, s.q, uid, sub.PeriodStart)
		if err != nil {
			return Entitlements{}, err
		}
		out.MeetupsUsed = used
	}
	return out, nil
}

// planUsed counts captured and held quota units in a period.
func (s *Service) planUsed(ctx context.Context, q *sqlcgen.Queries, uid uuid.UUID, periodStart time.Time) (int, error) {
	u, err := q.GetPlanUsage(ctx, sqlcgen.GetPlanUsageParams{UserID: uid, PeriodStart: ts(periodStart)})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("billing: read plan usage: %w", err)
	}
	return int(u.Used + u.Held), nil
}

// Quote prices one meetup for the caller. It never writes a hold.
//
// It grants the welcome credits the first time a hosting-level user asks
// and applies any due decay under the wallet lock, so the available balance
// it reports is the one a reservation would see.
func (s *Service) Quote(ctx context.Context, caller Caller, capacity int, windowStart time.Time) (Quote, error) {
	uid, err := parseUser(caller.UserID)
	if err != nil {
		return Quote{}, err
	}
	rules, err := s.Rules(ctx)
	if err != nil {
		return Quote{}, err
	}
	s.ensureWelcome(ctx, caller)
	var q Quote
	err = s.ledger.Do(ctx, caller.UserID, func(t *wallet.Tx) error {
		var err error
		q, err = s.price(ctx, t.Queries(), uid, rules, capacity, windowStart, t.Now(), t.Available())
		return err
	})
	return q, err
}

// price is the quote itself, run under the wallet lock.
func (s *Service) price(ctx context.Context, q *sqlcgen.Queries, uid uuid.UUID, rules pricing.Rules,
	capacity int, windowStart, now time.Time, available int64) (Quote, error) {
	sub, err := s.activeSubscription(ctx, q, uid, now)
	if err != nil {
		return Quote{}, err
	}
	limits := limitsFor(rules, sub)
	if capacity < 1 || capacity > limits.MaxCapacity {
		return Quote{}, fmt.Errorf("billing: capacity must be between 1 and %d: %w", limits.MaxCapacity, apperror.ErrInvalidInput)
	}
	lead := windowStart.Sub(now)
	if lead > time.Duration(limits.MaxAdvanceDays)*24*time.Hour {
		return Quote{}, fmt.Errorf("billing: meetups can be scheduled at most %d days ahead: %w", limits.MaxAdvanceDays, apperror.ErrInvalidInput)
	}
	breakdown, priceErr := pricing.Price(rules, pricing.Input{Capacity: capacity, Lead: lead})
	if priceErr != nil {
		// The limits sit inside the priced range by construction (30 days,
		// 30 people), so this is a rules document that does not cover its
		// own limits: refuse rather than charge 0.
		return Quote{}, fmt.Errorf("billing: %w: %w", priceErr, apperror.ErrInvalidInput)
	}
	out := Quote{
		WouldCost: breakdown.Total(), Breakdown: breakdown, PriceVersion: rules.Version,
		BalanceAvailable: available, Limits: limits,
	}
	if sub != nil {
		used, err := s.planUsed(ctx, q, uid, sub.PeriodStart)
		if err != nil {
			return Quote{}, err
		}
		out.CoveredByPlan = used < sub.MeetupsIncluded
	}
	if !out.CoveredByPlan {
		out.Cost = breakdown.Total()
	}
	return out, nil
}

// QuoteForCreation is Quote on the create path, with one more rule: an app
// build older than the first one with the credits UI is told to update
// instead of being charged a price it never showed (plan 29 §2, D11).
func (s *Service) QuoteForCreation(ctx context.Context, caller Caller, capacity int, windowStart time.Time) (Quote, error) {
	q, err := s.Quote(ctx, caller, capacity, windowStart)
	if err != nil {
		return Quote{}, err
	}
	if !flags.AtLeast(clientinfo.From(ctx).AppVersion, s.cfg.MinCreditsAppVersion) {
		return Quote{}, &apperror.CodedError{
			Sentinel: apperror.ErrUpgradeRequired, Code: apperror.CodeUpdateRequired,
			Message: "Update TieHere to host a meetup.",
		}
	}
	return q, nil
}

// ReserveRequest is what a caller hands back from a quote to reserve it.
type ReserveRequest struct {
	Cost          int64
	PriceVersion  int
	CoveredByPlan bool
}

func priceChanged(rules pricing.Rules, cost int64) error {
	return &apperror.CodedError{
		Sentinel: apperror.ErrConflict, Code: apperror.CodePriceChanged,
		Message: "billing: the price changed; check the new price and try again",
		Fields:  map[string]int64{"cost": cost, "price_version": int64(rules.Version)},
	}
}

// Reserve holds the credits (or the plan quota unit) for one creation.
// Nothing is held for a free creation. key makes it idempotent:
// a retry with the same key gets the same hold.
func (s *Service) Reserve(ctx context.Context, userID string, req ReserveRequest, key string) (string, error) {
	if req.Cost == 0 && !req.CoveredByPlan {
		return "", nil
	}
	if key == "" {
		return "", fmt.Errorf("billing: a reservation needs a key: %w", apperror.ErrInvalidInput)
	}
	uid, err := parseUser(userID)
	if err != nil {
		return "", err
	}
	rules, err := s.Rules(ctx)
	if err != nil {
		return "", err
	}
	if rules.Version != req.PriceVersion {
		return "", priceChanged(rules, req.Cost)
	}

	var holdID string
	err = s.ledger.Do(ctx, userID, func(t *wallet.Tx) error {
		in := wallet.ReserveInput{Kind: wallet.HoldCredits, Amount: req.Cost, PriceVersion: rules.Version,
			TTL: rules.HoldTTL(), Key: key}
		if req.CoveredByPlan {
			sub, err := s.activeSubscription(ctx, t.Queries(), uid, t.Now())
			if err != nil {
				return err
			}
			if sub == nil {
				return priceChanged(rules, req.Cost)
			}
			in.Kind, in.PeriodStart, in.QuotaIncluded = wallet.HoldPlanQuota, sub.PeriodStart, sub.MeetupsIncluded
		}
		h, err := t.Reserve(in)
		if errors.Is(err, wallet.ErrQuotaExhausted) {
			return priceChanged(rules, req.Cost)
		}
		if err != nil {
			return err
		}
		holdID = h.ID.String()
		return nil
	})
	return holdID, err
}

// holdOwner reads which user a hold belongs to, to lock their wallet.
func (s *Service) holdOwner(ctx context.Context, holdID string) (uuid.UUID, string, error) {
	id, err := uuid.Parse(holdID)
	if err != nil {
		return uuid.Nil, "", fmt.Errorf("billing: invalid hold id: %w", apperror.ErrInvalidInput)
	}
	h, err := s.q.GetHold(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, "", fmt.Errorf("billing: hold %s: %w", holdID, apperror.ErrNotFound)
	}
	if err != nil {
		return uuid.Nil, "", fmt.Errorf("billing: read hold: %w", err)
	}
	return id, h.UserID.String(), nil
}

// Release returns a reservation that will not be used. Releasing a hold
// that was captured or already released does nothing.
func (s *Service) Release(ctx context.Context, holdID string) error {
	id, owner, err := s.holdOwner(ctx, holdID)
	if err != nil {
		return err
	}
	return s.ledger.Do(ctx, owner, func(t *wallet.Tx) error {
		_, err := t.Release(id, "released")
		return err
	})
}

// Capture spends a reservation for the meetup it paid for. Idempotent.
func (s *Service) Capture(ctx context.Context, holdID, meetupID string) error {
	id, owner, err := s.holdOwner(ctx, holdID)
	if err != nil {
		return err
	}
	var res wallet.CaptureResult
	if err := s.ledger.Do(ctx, owner, func(t *wallet.Tx) error {
		var err error
		res, err = t.Capture(id, meetupID)
		return err
	}); err != nil {
		return err
	}
	// After the commit: a rolled-back capture spent nothing.
	if !res.AlreadyCaptured && res.Spent > 0 {
		metrics.Default.CreditsSpent.Add(float64(res.Spent))
	}
	return nil
}
