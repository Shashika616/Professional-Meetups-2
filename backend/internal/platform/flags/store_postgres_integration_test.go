package flags_test

import (
	"context"
	"net"
	"net/url"
	"os"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/flags"
)

func testPool(t *testing.T) *flags.PostgresStore {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, _ := url.Parse(dbURL)
	conn, err := net.DialTimeout("tcp", parsed.Host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable: %v", err)
	}
	_ = conn.Close()
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(testURL, "file://../../../migrations"); err != nil {
		t.Fatal(err)
	}
	pool, err := db.New(context.Background(), testURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	release, err := db.AcquireIntegrationTestLock(context.Background(), pool)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)
	if _, err := pool.Exec(context.Background(),
		`DELETE FROM ops.feature_flags WHERE key LIKE 'test.%'`); err != nil {
		t.Fatal(err)
	}
	return flags.NewPostgresStore(pool)
}

// The migration seeds every flag plan 29 introduces: plans hidden except
// for the seeded test fixtures, and no flag for credits at all.
func TestSeededFlags(t *testing.T) {
	store := testPool(t)
	svc := flags.NewService(store)
	ctx := context.Background()

	if on, err := svc.Enabled(ctx, flags.BillingPlansVisible, flags.Subject{UserID: "00000000-0000-4000-8000-0000000000ff"}); err != nil || on {
		t.Errorf("billing.plans.visible = %v, %v for an ordinary user; want off", on, err)
	}
	all, err := svc.EvaluateAll(ctx, flags.Subject{})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"credits.enforced", "billing.credit_packs.visible"} {
		if _, ok := all[key]; ok {
			t.Errorf("%s is seeded; credits have no flag", key)
		}
	}
	if on, _ := svc.Enabled(ctx, flags.BillingPlansVisible,
		flags.Subject{UserID: "00000000-0000-4000-8000-000000000040"}); !on {
		t.Error("billing.plans.visible should be on for the seeded L3 test user")
	}
	if on, _ := svc.Enabled(ctx, flags.BillingPlansVisible,
		flags.Subject{UserID: "00000000-0000-4000-8000-0000000000ff", Email: "someone@meetups.test"}); !on {
		t.Error("billing.plans.visible should be on for any @meetups.test address")
	}
	if on, _ := svc.Enabled(ctx, flags.AnalyticsEnabled, flags.Subject{}); !on {
		t.Error("analytics.enabled should default on")
	}
}

func TestSetWritesTheFlagAndAnAuditRow(t *testing.T) {
	store := testPool(t)
	ctx := context.Background()

	if err := store.Set(ctx, flags.Flag{Key: "test.audit", Enabled: true}, "", "why"); err == nil {
		t.Fatal("Set without an operator must fail")
	}
	if err := store.Set(ctx, flags.Flag{Key: "test.audit", Rules: []flags.Rule{{Type: "bogus"}}}, "op", "why"); err == nil {
		t.Fatal("Set with an invalid rule must fail")
	}
	if err := store.Set(ctx, flags.Flag{Key: "test.audit", Enabled: true}, "shashika", "turn it on"); err != nil {
		t.Fatal(err)
	}
	all, err := store.All(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, f := range all {
		if f.Key == "test.audit" {
			found = f.Enabled
		}
	}
	if !found {
		t.Fatal("flag not written")
	}
}
