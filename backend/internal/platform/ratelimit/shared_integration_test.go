package ratelimit_test

import (
	"context"
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

func sharedPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	host := parsed.Host
	if !strings.Contains(host, ":") {
		host += ":5432"
	}
	conn, err := net.DialTimeout("tcp", host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s: %v", host, err)
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
	if _, err := pool.Exec(context.Background(), `TRUNCATE ops.rate_counters`); err != nil {
		t.Fatal(err)
	}
	return pool
}

func TestSharedLimitCountsAcrossCallsAndSubjects_Integration(t *testing.T) {
	pool := sharedPool(t)
	ctx := context.Background()
	shared := ratelimit.NewShared(pool, nil)
	rule := ratelimit.Rule{Name: "test:sends", Limit: 3, Window: time.Hour}

	for i := 0; i < 3; i++ {
		if err := shared.Check(ctx, rule, "victim@example.com"); err != nil {
			t.Fatalf("use %d refused: %v", i+1, err)
		}
	}
	if err := shared.Check(ctx, rule, "victim@example.com"); !errors.Is(err, apperror.ErrRateLimited) {
		t.Fatalf("the 4th use: %v, want rate limited", err)
	}
	if err := shared.Check(ctx, rule, "someone-else@example.com"); err != nil {
		t.Errorf("another subject was limited: %v", err)
	}
	other := ratelimit.Rule{Name: "test:other", Limit: 3, Window: time.Hour}
	if err := shared.Check(ctx, other, "victim@example.com"); err != nil {
		t.Errorf("another rule shared the subject's window: %v", err)
	}

	// Only hashes are stored: no subject text anywhere in the table.
	var leaked int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM ops.rate_counters WHERE position('victim'::bytea IN key_hash) > 0`,
	).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	if leaked != 0 {
		t.Error("a subject is stored in clear")
	}
}

// Two instances racing for the last use cannot both get it.
func TestSharedLimitHoldsUnderConcurrency_Integration(t *testing.T) {
	pool := sharedPool(t)
	shared := ratelimit.NewShared(pool, nil)
	rule := ratelimit.Rule{Name: "test:race", Limit: 5, Window: time.Hour}
	var allowed atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if shared.Check(context.Background(), rule, "+94771234567") == nil {
				allowed.Add(1)
			}
		}()
	}
	wg.Wait()
	if got := allowed.Load(); got != 5 {
		t.Errorf("%d uses allowed under concurrency, want 5", got)
	}
}

func TestSharedSweepDeletesFinishedWindows_Integration(t *testing.T) {
	pool := sharedPool(t)
	ctx := context.Background()
	shared := ratelimit.NewShared(pool, nil)
	if err := shared.Check(ctx, ratelimit.Rule{Name: "test:live", Limit: 1, Window: time.Hour}, "x"); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO ops.rate_counters (key_hash, window_start, count, expires_at)
		VALUES ('\x01', now() - interval '2 hours', 3, now() - interval '1 hour')`); err != nil {
		t.Fatal(err)
	}
	n, err := shared.Sweep(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("swept %d rows, want 1 (the live window stays)", n)
	}
}

type brokenDB struct{}

func (brokenDB) QueryRow(context.Context, string, ...any) pgx.Row { return brokenRow{} }
func (brokenDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, errors.New("connection refused")
}

type brokenRow struct{}

func (brokenRow) Scan(...any) error { return errors.New("connection refused") }

// OTP, SOS and contacts refuse when the counter cannot be asked; the rest
// carry on.
func TestSharedLimitFailsClosedOnlyWhereTheRuleSays(t *testing.T) {
	shared := ratelimit.NewShared(brokenDB{}, nil)
	ctx := context.Background()
	closed := ratelimit.Rule{Name: "otp", Limit: 5, Window: time.Hour, FailClosed: true}
	if err := shared.Check(ctx, closed, "x"); !errors.Is(err, apperror.ErrUnavailable) {
		t.Errorf("a fail-closed rule with no database: %v, want unavailable", err)
	}
	open := ratelimit.Rule{Name: "share", Limit: 3, Window: 24 * time.Hour}
	if err := shared.Check(ctx, open, "x"); err != nil {
		t.Errorf("a fail-open rule with no database: %v, want allowed", err)
	}
	var none *ratelimit.Shared
	if err := none.Check(ctx, closed, "x"); err != nil {
		t.Errorf("a nil limiter: %v", err)
	}
}
