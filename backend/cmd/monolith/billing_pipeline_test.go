package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/billing"
	billingconfig "professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// Meetup creation charging, end to end: the real meetup service, the real
// billing service, and the adapter and outbox delivery from main.go between
// them, against real Postgres with real concurrent goroutines (plan 29
// §3.5). These are the tests the phase is "done when" on: creating a meetup
// charges exactly once under retries and races, and a
// refund returns credits to the lots they came from.

// verifiedProfiles stands in for the auth module behind the real
// identityFingerprint adapter. Users a test marks have a verified phone and
// are eligible for the welcome grant; everyone else has none, so the money
// tests see only the credits they fund.
type verifiedProfiles struct{ ids sync.Map }

func (p *verifiedProfiles) GetProfile(_ context.Context, userID string) (auth.Profile, error) {
	if _, ok := p.ids.Load(userID); !ok {
		return auth.Profile{UserID: userID}, nil
	}
	return auth.Profile{UserID: userID, PhoneVerified: true, PhoneNumber: "+9477" + userID[:7]}, nil
}

type chargingHarness struct {
	pool    *pgxpool.Pool
	meetups meetup.Service
	billing *billing.Service
	poller  *outbox.Poller
	// profiles decides who has a verified phone (and so a welcome grant).
	profiles *verifiedProfiles
}

func newChargingHarness(t *testing.T) *chargingHarness {
	t.Helper()
	dbURL := requirePipelinePostgres(t)
	if err := db.Migrate(dbURL, pipelineMigrationsURL); err != nil {
		t.Fatalf("run migrations: %v", err)
	}
	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	release, err := db.AcquireIntegrationTestLock(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)
	if _, err := pool.Exec(ctx, `
		TRUNCATE meetup.meetups, meetup.meetup_requests, meetup.safety_state,
		         meetup.notification_outbox, meetup.meetups_completed_outbox, meetup.billing_outbox,
		         billing.wallets, billing.credit_lots, billing.holds, billing.hold_allocations,
		         billing.subscriptions, billing.plan_usage,
		         billing.welcome_grants, billing.billing_outbox, billing.refund_log,
		         billing.admin_audit, billing.reconciliation_runs
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	logger := slog.New(slog.DiscardHandler)
	bus := eventbus.New(logger)
	profiles := &verifiedProfiles{}
	billingService := billing.New(billing.Deps{
		Pool:         pool,
		Fingerprints: identityFingerprint{auth: profiles, key: []byte("test-key")},
		Config:       billingconfig.Config{MinCreditsAppVersion: "1.1.0", CatalogVersion: 1},
		Logger:       logger,
	})
	meetupService := meetup.New(meetup.Deps{
		Meetups:       meetuprepo.NewMeetupRepository(pool, bus, logger, func() {}),
		Requests:      meetuprepo.NewMeetupRequestRepository(pool, bus, logger),
		SafetyState:   meetuprepo.NewSafetyStateRepository(pool),
		Feedback:      meetuprepo.NewFeedbackRepository(pool),
		Ratings:       meetuprepo.NewRatingRepository(pool, bus, logger),
		DeviceTokens:  meetuprepo.NewDeviceTokenRepository(pool),
		UserLocations: meetuprepo.NewUserLocationCacheRepository(pool),
		Outbox:        meetuprepo.NewNotificationOutboxRepository(pool),
		Geocoder:      stubLabel{},
		Charger:       creationCharger{billing: billingService},
		Logger:        logger,
	})
	// The production delivery step, not a copy of it.
	poller := outbox.New(meetuprepo.NewBillingOutboxRepository(pool), meetupBillingProcess(billingService),
		outbox.WithLogger(logger))
	return &chargingHarness{pool: pool, meetups: meetupService, billing: billingService, poller: poller, profiles: profiles}
}

type stubLabel struct{}

func (stubLabel) ReverseGeocode(context.Context, float64, float64) (string, error) {
	return "Somewhere", nil
}

// newAppCtx is a request from an app build with the credits UI.
func newAppCtx() context.Context {
	return clientinfo.With(context.Background(), clientinfo.Info{AppVersion: "1.1.0", Platform: "android"})
}

func (h *chargingHarness) fund(t *testing.T, userID string, credits int64) {
	t.Helper()
	if _, err := h.billing.AdminGrant(context.Background(), userID, credits, 0,
		billing.AdminAction{Operator: "test", Reason: "fund", Key: uuid.NewString()}); err != nil {
		t.Fatal(err)
	}
}

func (h *chargingHarness) drain(t *testing.T) {
	t.Helper()
	if _, err := h.poller.Drain(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func (h *chargingHarness) wallet(t *testing.T, userID string) billing.WalletView {
	t.Helper()
	v, err := h.billing.Wallet(context.Background(), billing.Caller{UserID: userID, TrustLevel: 3})
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func (h *chargingHarness) reconciled(t *testing.T) {
	t.Helper()
	m, err := h.billing.FindMismatches(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(m) > 0 {
		t.Fatalf("ledger does not replay to the wallets: %+v", m)
	}
}

func cost(n int64) *int64 { return &n }

// createReq is a 4-person meetup starting `start` from now, an hour long.
// Cost under the default rules: 10 credits within 48 hours.
func createReq(host string, start time.Duration) meetup.CreateMeetupRequest {
	ws := time.Now().Add(start).Truncate(time.Second)
	return meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 3, Intent: meetup.IntentCoffee,
		WindowStart: ws, WindowEnd: ws.Add(time.Hour),
		LocationLat: 6.9271, LocationLng: 79.8612, LocationLabel: "Cafe",
		Capacity: 4, ExpectedCost: cost(10), PriceVersion: 1,
	}
}

// 20 creations at once for a host with 25 credits at 10 each: exactly two
// succeed, the balance ends at 5, it is never negative, and the ledger
// replays to the wallet.
func TestConcurrentCreatesChargeExactlyTwo(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 25)

	var (
		wg                  sync.WaitGroup
		mu                  sync.Mutex
		ok, paymentRequired int
		unexpected          []error
	)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			// Two hours apart, so the one-meetup-at-a-time rule never
			// decides the outcome; only the money does.
			_, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, time.Duration(2+2*i)*time.Hour))
			mu.Lock()
			defer mu.Unlock()
			var coded *apperror.CodedError
			switch {
			case err == nil:
				ok++
			case errors.As(err, &coded) && coded.Code == apperror.CodeInsufficientCredits:
				paymentRequired++
			default:
				unexpected = append(unexpected, err)
			}
		}(i)
	}
	wg.Wait()
	if len(unexpected) > 0 {
		t.Fatalf("unexpected errors: %v", unexpected)
	}
	if ok != 2 || paymentRequired != 18 {
		t.Fatalf("%d created, %d refused for credits; want 2 and 18", ok, paymentRequired)
	}
	h.drain(t)
	v := h.wallet(t, host)
	if v.Balance != 5 || v.Held != 0 || v.Debt != 0 {
		t.Fatalf("wallet = %+v, want balance 5, nothing held, no debt", v)
	}
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM meetup.meetups WHERE host_user_id = $1`, host); n != 2 {
		t.Fatalf("%d meetups exist, want 2", n)
	}
	h.reconciled(t)
}

// The same Idempotency-Key sent five times at once: one meetup, one charge,
// and every caller gets that meetup back.
func TestSameIdempotencyKeyConcurrentlyChargesOnce(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 100)
	req := createReq(host, 3*time.Hour)
	req.IdempotencyKey = "retry-" + uuid.NewString()

	ids := make(chan string, 5)
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m, err := h.meetups.CreateMeetup(newAppCtx(), req)
			if err != nil {
				t.Errorf("create: %v", err)
				return
			}
			ids <- m.ID
		}()
	}
	wg.Wait()
	close(ids)
	seen := map[string]bool{}
	for id := range ids {
		seen[id] = true
	}
	if len(seen) != 1 {
		t.Fatalf("callers got %d different meetups, want 1", len(seen))
	}
	// And a sixth, sequential retry after the dust settles.
	m, err := h.meetups.CreateMeetup(newAppCtx(), req)
	if err != nil || !seen[m.ID] {
		t.Fatalf("a later retry got %v, %v", m.ID, err)
	}
	h.drain(t)
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM meetup.meetups WHERE host_user_id = $1`, host); n != 1 {
		t.Fatalf("%d meetups, want 1", n)
	}
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM billing.holds WHERE user_id = $1`, host); n != 1 {
		t.Fatalf("%d holds, want 1", n)
	}
	if v := h.wallet(t, host); v.Balance != 90 || v.Held != 0 {
		t.Fatalf("wallet = %+v, want one 10-credit charge", v)
	}
	h.reconciled(t)
}

// A create that fails after its reservation gives the hold straight back.
func TestFailedCreateAfterReserveReleasesTheHold(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 50)

	if _, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	// Same slot: the one-meetup-at-a-time guard refuses it inside the
	// create transaction, after the credits were reserved.
	_, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 3*time.Hour))
	var conflict *meetup.ScheduleConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("second create: %v, want a schedule conflict", err)
	}
	h.drain(t)
	v := h.wallet(t, host)
	if v.Balance != 40 || v.Held != 0 {
		t.Fatalf("wallet = %+v, want only the first charge and nothing held", v)
	}
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM billing.holds WHERE user_id = $1 AND state = 'released'`, host); n != 1 {
		t.Fatalf("released holds = %d, want 1", n)
	}
	h.reconciled(t)
}

func TestCreatePricingErrors(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 50)

	t.Run("an app build without the credits UI is told to update", func(t *testing.T) {
		old := clientinfo.With(context.Background(), clientinfo.Info{AppVersion: "1.0.0"})
		_, err := h.meetups.CreateMeetup(old, createReq(host, 3*time.Hour))
		var coded *apperror.CodedError
		if !errors.As(err, &coded) || coded.Code != apperror.CodeUpdateRequired {
			t.Fatalf("err = %v, want update_required", err)
		}
		// No version header at all is the oldest build of all.
		_, err = h.meetups.CreateMeetup(context.Background(), createReq(host, 3*time.Hour))
		if !errors.As(err, &coded) || coded.Code != apperror.CodeUpdateRequired {
			t.Fatalf("no header: err = %v, want update_required", err)
		}
	})
	t.Run("no expected cost is price_changed", func(t *testing.T) {
		req := createReq(host, 3*time.Hour)
		req.ExpectedCost = nil
		_, err := h.meetups.CreateMeetup(newAppCtx(), req)
		var coded *apperror.CodedError
		if !errors.As(err, &coded) || coded.Code != apperror.CodePriceChanged || coded.Fields["cost"] != 10 {
			t.Fatalf("err = %v, want price_changed with cost 10", err)
		}
	})
	t.Run("a stale expected cost is price_changed", func(t *testing.T) {
		req := createReq(host, 3*time.Hour)
		req.ExpectedCost = cost(8)
		_, err := h.meetups.CreateMeetup(newAppCtx(), req)
		var coded *apperror.CodedError
		if !errors.As(err, &coded) || coded.Code != apperror.CodePriceChanged {
			t.Fatalf("err = %v, want price_changed", err)
		}
	})
	t.Run("advance and capacity limits without a plan", func(t *testing.T) {
		req := createReq(host, 15*24*time.Hour)
		if _, err := h.meetups.CreateMeetup(newAppCtx(), req); !errors.Is(err, apperror.ErrInvalidInput) {
			t.Fatalf("15 days ahead: %v", err)
		}
		req = createReq(host, 3*time.Hour)
		req.Capacity = 21
		if _, err := h.meetups.CreateMeetup(newAppCtx(), req); !errors.Is(err, apperror.ErrInvalidInput) {
			t.Fatalf("capacity 21: %v", err)
		}
	})
	t.Run("the trust gate still runs first", func(t *testing.T) {
		req := createReq(host, 3*time.Hour)
		req.HostTrustLevel = 2
		if _, err := h.meetups.CreateMeetup(newAppCtx(), req); !errors.Is(err, apperror.ErrForbidden) {
			t.Fatalf("level 2 host with credits: %v, want forbidden", err)
		}
	})
	if v := h.wallet(t, host); v.Balance != 50 || v.Held != 0 {
		t.Fatalf("refused creates touched the wallet: %+v", v)
	}
	h.reconciled(t)
}

// Credits are live from day one: a new host with a verified phone gets the
// welcome credits on their first create and pays for it from them, through
// the real fingerprint adapter.
func TestNewHostPaysWithWelcomeCredits(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.profiles.ids.Store(host, true)

	m, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 3*time.Hour))
	if err != nil {
		t.Fatalf("first create by a new host: %v", err)
	}
	if m.ID == "" {
		t.Fatal("no meetup")
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 50 || v.Held != 0 {
		t.Fatalf("after the first create wallet = %+v, want 50 left of the 60 welcome credits", v)
	}
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM billing.welcome_grants WHERE user_id = $1`, host); n != 1 {
		t.Fatalf("%d welcome grants, want 1", n)
	}
	h.reconciled(t)
}

// Cancel 24h or more ahead: the outbox carries the cancellation to billing
// and the credits come back.
func TestCancelRefundsThroughTheOutbox(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 30)

	m, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 40*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 20 {
		t.Fatalf("after capture balance = %d, want 20", v.Balance)
	}
	if err := h.meetups.CancelMeetup(context.Background(), meetup.CancelMeetupRequest{MeetupID: m.ID, HostUserID: host, Reason: "plans changed"}); err != nil {
		t.Fatal(err)
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 30 {
		t.Fatalf("after cancelling 40h ahead balance = %d, want 30", v.Balance)
	}
	h.reconciled(t)
}

// Auto-close with nobody accepted refunds half, through the sweep's
// transaction.
func TestAutoCloseWithNobodyRefundsHalf(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 30)
	m, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	h.drain(t)
	// Move it into the past so the sweep closes it.
	if _, err := h.pool.Exec(context.Background(), `
		UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '2 hours'
		WHERE id = $1`, m.ID); err != nil {
		t.Fatal(err)
	}
	if n, err := h.meetups.AutoCloseSweep(context.Background()); err != nil || n != 1 {
		t.Fatalf("auto-close closed %d, %v", n, err)
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 25 {
		t.Fatalf("balance = %d, want 20 + half of 10", v.Balance)
	}
	h.reconciled(t)
}

var _ = fmt.Sprintf

// Review fix 1: a key whose create failed cannot be reused for a bigger
// meetup at the old price, and reusing it for the same meetup reserves a
// fresh hold instead of capturing the released one.
func TestIdempotencyKeyAfterAFailedCreate(t *testing.T) {
	h := newChargingHarness(t)
	host := uuid.NewString()
	h.fund(t, host, 100)

	blocker, err := h.meetups.CreateMeetup(newAppCtx(), createReq(host, 3*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	key := "k-" + uuid.NewString()
	req := createReq(host, 3*time.Hour)
	req.IdempotencyKey = key
	var conflict *meetup.ScheduleConflictError
	if _, err := h.meetups.CreateMeetup(newAppCtx(), req); !errors.As(err, &conflict) {
		t.Fatalf("first attempt: %v, want a schedule conflict", err)
	}

	// Same key, a 20-person meetup 13 days out, with its correct cost.
	bigger := createReq(host, 13*24*time.Hour)
	bigger.IdempotencyKey, bigger.Capacity, bigger.ExpectedCost = key, 20, cost(48)
	_, err = h.meetups.CreateMeetup(newAppCtx(), bigger)
	var coded *apperror.CodedError
	if !errors.As(err, &coded) || coded.Code != apperror.CodeIdempotencyKeyReused {
		t.Fatalf("bigger body with a used key: %v, want idempotency_key_reused", err)
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 90 || v.Held != 0 {
		t.Fatalf("after the refused reuse: %+v, want only the blocker's 10 charged", v)
	}

	// The slot frees up; the same request with the same key now succeeds
	// and is charged once, from a fresh hold.
	if err := h.meetups.CancelMeetup(context.Background(), meetup.CancelMeetupRequest{
		MeetupID: blocker.ID, HostUserID: host, Reason: "moved"}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.meetups.CreateMeetup(newAppCtx(), req); err != nil {
		t.Fatalf("same body, same key, slot free: %v", err)
	}
	h.drain(t)
	if v := h.wallet(t, host); v.Balance != 80 || v.Held != 0 {
		t.Fatalf("wallet = %+v, want 80 (blocker 10, no refund under 24h; retry 10)", v)
	}
	if n := pipelineCount(t, h.pool, `SELECT count(*) FROM billing.holds WHERE user_id = $1 AND state = 'captured'`, host); n != 2 {
		t.Fatalf("captured holds = %d, want 2 (blocker and the retry)", n)
	}
	h.reconciled(t)
}
