package db

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// TestDatabaseSuffix is appended to the configured database's name to get the
// one integration tests run against.
const TestDatabaseSuffix = "_test"

// EnsureTestDatabase derives an isolated test-database URL from databaseURL,
// creating that database if it does not exist, and returns the URL to use.
//
// # WHY INTEGRATION TESTS MUST NOT SHARE THE APPLICATION'S DATABASE
//
// This is not tidiness. Running the integration tests against the same
// database a live monolith is attached to produced real, intermittent
// failures, and the mechanism is worth understanding because it is entirely
// correct behaviour on both sides:
//
//   - The running monolith polls meetup.notification_outbox every two
//     seconds. It claims rows the tests just queued — which is exactly what
//     ClaimBatch's concurrency guarantees say should happen, and means a test
//     asserting "I claimed this row" fails through no fault of the code.
//   - Worse, with a real FIREBASE_SERVICE_ACCOUNT_JSON configured, it
//     actually SENDS them. Real FCM rejects the tests' fake device tokens as
//     permanently invalid, and §E2c's dead-token cleanup then deletes those
//     rows — so the application garbage-collects the tests' own fixtures out
//     from under them, mid-test. Measured on a live stack: 61 fixture
//     deletions in five minutes.
//   - Separately, integration packages sharing one database overlap in what
//     they truncate (see IntegrationTestLockKey).
//
// None of that is a defect to fix in the product; the product is behaving
// exactly as designed. The fix is isolation, which also removes the whole
// class of "did a test fail, or was something else touching the database"
// question — the least productive kind of debugging there is.
//
// The database is created once and reused; each test still truncates for its
// own clean slate, and the advisory lock still serialises packages.
func EnsureTestDatabase(ctx context.Context, databaseURL string) (string, error) {
	parsed, err := url.Parse(databaseURL)
	if err != nil {
		return "", fmt.Errorf("db: parse database url: %w", err)
	}

	base := strings.TrimPrefix(parsed.Path, "/")
	if base == "" {
		return "", fmt.Errorf("db: database url has no database name")
	}
	// Already pointing at a test database (a caller that set DATABASE_URL to
	// one explicitly, or a second call) — nothing to do.
	if strings.HasSuffix(base, TestDatabaseSuffix) {
		return databaseURL, nil
	}
	testName := base + TestDatabaseSuffix

	// CREATE DATABASE cannot run inside a transaction and cannot be
	// parameterized, so the name is quoted rather than bound. It is derived
	// from the operator's own DATABASE_URL plus a constant suffix — not from
	// anything a request could reach — and pgx.Identifier does the quoting
	// rather than string concatenation.
	admin, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return "", fmt.Errorf("db: connect to create test database: %w", err)
	}
	defer func() { _ = admin.Close(ctx) }()

	quoted := pgx.Identifier{testName}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quoted); err != nil {
		// 42P04 duplicate_database: another package's harness won the race,
		// which is the normal case after the first ever run. 23505 can
		// surface from the same race against pg_database's own unique index.
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || (pgErr.Code != "42P04" && pgErr.Code != "23505") {
			return "", fmt.Errorf("db: create test database %q: %w", testName, err)
		}
	}

	parsed.Path = "/" + testName
	return parsed.String(), nil
}
