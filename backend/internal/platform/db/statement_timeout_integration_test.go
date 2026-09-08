package db_test

// §B2: proves statement_timeout is actually in force on pooled connections,
// against real Postgres. A unit test could only assert that the string was
// put in a map — the thing worth pinning is that the SERVER aborts a
// runaway query, which is only observable against a real backend.

import (
	"context"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/platform/db"
)

func requirePostgres(t *testing.T) string {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatalf("DATABASE_URL %q is not a URL: %v", dbURL, err)
	}
	hostPort := parsed.Host
	if !strings.Contains(hostPort, ":") {
		hostPort += ":5432"
	}
	conn, err := net.DialTimeout("tcp", hostPort, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping integration test (run `docker compose up -d postgres` first): %v", hostPort, err)
	}
	_ = conn.Close()

	// Same isolation as every other integration package — see
	// db.EnsureTestDatabase.
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("prepare isolated test database: %v", err)
	}
	return testURL
}

// TestNew_AppliesStatementTimeout_Integration confirms the setting reached
// the session. Asserting the reported value (rather than only that a long
// query dies) is what catches the silent failure mode: a RuntimeParams key
// Postgres ignores would leave the pool with NO timeout while every other
// test still passes.
func TestNew_AppliesStatementTimeout_Integration(t *testing.T) {
	dbURL := requirePostgres(t)
	ctx := context.Background()

	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("db.New: %v", err)
	}
	defer pool.Close()

	var setting string
	if err := pool.QueryRow(ctx, "SHOW statement_timeout").Scan(&setting); err != nil {
		t.Fatalf("SHOW statement_timeout: %v", err)
	}
	if setting == "0" || setting == "" {
		t.Fatalf("statement_timeout = %q — the pool has no server-side statement bound at all", setting)
	}
	t.Logf("pooled connections report statement_timeout = %q (configured: %v)", setting, db.StatementTimeout)
}

// TestStatementTimeout_AbortsARunawayQuery_Integration is the actual §B2
// guarantee: a query that would otherwise hold its pooled connection forever
// is killed by Postgres itself. That distinction matters — a context
// deadline depends on this process still being healthy enough to issue a
// cancel; statement_timeout does not.
//
// A short-lived pool with its own tiny timeout is used rather than waiting
// out the real 10s, so this stays a fast test of the same mechanism.
func TestStatementTimeout_AbortsARunawayQuery_Integration(t *testing.T) {
	dbURL := requirePostgres(t)
	ctx := context.Background()

	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("db.New: %v", err)
	}
	defer pool.Close()

	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SET statement_timeout = '250ms'"); err != nil {
		t.Fatalf("set session statement_timeout: %v", err)
	}

	start := time.Now()
	// pg_sleep(30) stands in for any query that never finishes. Note the
	// context here is deliberately NOT given a deadline: the point is that
	// the server aborts this, with no help from the client.
	_, err = conn.Exec(ctx, "SELECT pg_sleep(30)")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("a 30-second query completed — statement_timeout is not being enforced")
	}
	if !strings.Contains(err.Error(), "statement timeout") && !strings.Contains(err.Error(), "57014") {
		t.Fatalf("query failed for the wrong reason: %v", err)
	}
	if elapsed > 5*time.Second {
		t.Errorf("query ran %v before being aborted, want roughly the 250ms limit", elapsed)
	}
	t.Logf("Postgres aborted the runaway query after %v: %v", elapsed, err)
}
