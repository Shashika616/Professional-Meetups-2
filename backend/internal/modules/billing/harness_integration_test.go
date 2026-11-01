package billing_test

// Integration tests: the billing module against real Postgres and the real
// migrations. Money paths are tested here, with real concurrent goroutines
// (run under -race), because the guarantees that matter — one charge, no
// negative balance, a ledger that replays to the wallet — are properties of
// the SQL and its locking, which no fake can stand in for.

import (
	"context"
	"errors"
	"net"
	"net/url"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/billing"
	"professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple/appletest"
	"professional-meetups-monolith/backend/internal/modules/billing/store/fake"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/flags"
)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// fingerprints maps user id to a fingerprint; a user not in the map has
// none.
type fingerprints struct {
	mu sync.Mutex
	m  map[string]string
}

func (f *fingerprints) Fingerprint(_ context.Context, userID string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.m[userID], nil
}

func (f *fingerprints) set(userID, fp string) {
	f.mu.Lock()
	f.m[userID] = fp
	f.mu.Unlock()
}

// switchStore lets a test swap the store mid-test (an outage, a
// rejection) while the default is the fake store, which believes the
// tokens tests make with fake.Encode.
type switchStore struct {
	mu sync.Mutex
	billing.Store
}

func (s *switchStore) set(st billing.Store) {
	s.mu.Lock()
	s.Store = st
	s.mu.Unlock()
}

func (s *switchStore) Verify(ctx context.Context, req store.Request) (store.Transaction, error) {
	s.mu.Lock()
	st := s.Store
	s.mu.Unlock()
	return st.Verify(ctx, req)
}

func (s *switchStore) Finish(ctx context.Context, p store.Platform, k store.Kind, productID, token string) error {
	s.mu.Lock()
	st := s.Store
	s.mu.Unlock()
	return st.Finish(ctx, p, k, productID, token)
}

// pushVerifier accepts exactly "Bearer good-token".
type pushVerifier struct{}

func (pushVerifier) Verify(_ context.Context, authorization string) (jwt.MapClaims, error) {
	if authorization != "Bearer good-token" {
		return nil, errors.New("bad push token")
	}
	return jwt.MapClaims{}, nil
}

type harness struct {
	svc   *billing.Service
	pool  *pgxpool.Pool
	clock *clock
	fps   *fingerprints
	// 29B: the stores, the flags (the real service over the real seeded
	// table), the Apple test root, and the settings.
	store *switchStore
	fake  *fake.Store
	flags *flags.Service
	apple appletest.Chain
	cfg   config.Config
}

func requirePostgres(t *testing.T) string {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp", parsed.Host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping (run `docker compose up -d postgres`): %v", parsed.Host, err)
	}
	_ = conn.Close()
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatal(err)
	}
	return testURL
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dbURL := requirePostgres(t)
	if err := db.Migrate(dbURL, "file://../../../migrations"); err != nil {
		t.Fatalf("migrate: %v", err)
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

	// Every table but the ledger, which refuses TRUNCATE, DELETE and UPDATE
	// by design (migrations 0026, 0028). It is never cleared: every test
	// uses fresh user ids and scopes its ledger assertions to them, and
	// reconciliation reads from wallets, so old users' rows are inert.
	if _, err := pool.Exec(ctx, `
		TRUNCATE billing.wallets, billing.credit_lots, billing.holds, billing.hold_allocations,
		         billing.subscriptions, billing.plan_usage,
		         billing.welcome_grants, billing.billing_outbox, billing.refund_log,
		         billing.admin_audit, billing.reconciliation_runs,
		         billing.store_purchases, billing.processed_store_notifications
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	fakeStore := &fake.Store{}
	h := &harness{
		pool:  pool,
		clock: &clock{t: time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)},
		fps:   &fingerprints{m: map[string]string{}},
		store: &switchStore{Store: fakeStore},
		fake:  fakeStore,
		// No cache: a test flips a flag and reads it back at once.
		flags: flags.NewService(flags.NewPostgresStore(pool), flags.WithTTL(0)),
		apple: appletest.New(t),
		cfg: config.Config{
			MinCreditsAppVersion: "1.1.0", CatalogVersion: 1, Production: true,
			AppleBundleID: config.DefaultAppleBundleID, GooglePackageName: config.DefaultGooglePackageName,
			TermsURL: "https://example.com/terms", PrivacyURL: "https://example.com/privacy",
		},
	}
	h.build()
	return h
}

// build (re)constructs the service from the harness's parts, after a test
// changes h.cfg.
func (h *harness) build() {
	h.svc = billing.New(billing.Deps{
		Pool: h.pool, Fingerprints: h.fps, Config: h.cfg, Now: h.clock.Now,
		Flags: h.flags, Store: h.store, AppleRoots: h.apple.Roots, GooglePush: pushVerifier{},
	})
}

// newHost is a hosting-level user with a verified phone, so their first
// billing call earns the welcome grant.
func (h *harness) newHost() billing.Caller {
	id := uuid.NewString()
	h.fps.set(id, "fp-"+id)
	return billing.Caller{UserID: id, TrustLevel: 3}
}

// newUser is a user with no welcome grant coming (no fingerprint).
func (h *harness) newUser() billing.Caller {
	return billing.Caller{UserID: uuid.NewString(), TrustLevel: 3}
}

func (h *harness) wallet(t *testing.T, c billing.Caller) billing.WalletView {
	t.Helper()
	v, err := h.svc.Wallet(context.Background(), c)
	if err != nil {
		t.Fatalf("wallet: %v", err)
	}
	return v
}

// assertReconciled fails if any wallet's figures disagree with its lots,
// holds or ledger replay.
func (h *harness) assertReconciled(t *testing.T) {
	t.Helper()
	m, err := h.svc.FindMismatches(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(m) > 0 {
		t.Fatalf("reconciliation mismatches: %+v", m)
	}
}

func (h *harness) count(t *testing.T, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// reserveCapture reserves and captures one creation's worth for c at the
// given cost, returning the hold id.
func (h *harness) reserveCapture(t *testing.T, c billing.Caller, cost int64) string {
	t.Helper()
	ctx := context.Background()
	rules, err := h.svc.Rules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{
		Cost: cost, PriceVersion: rules.Version,
	}, "k-"+uuid.NewString())
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
		t.Fatalf("capture: %v", err)
	}
	return hold
}
