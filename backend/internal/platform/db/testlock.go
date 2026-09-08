package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// IntegrationTestLockKey is the advisory-lock key every integration-test
// harness in this repo takes before touching the database.
//
// # THE PROBLEM THIS SOLVES
//
// `go test ./...` runs PACKAGES in parallel (up to GOMAXPROCS of them), and
// this backend has integration tests in several packages that all share ONE
// database — because the whole point of ADR-001 §3 is that there is one
// database with a schema per module. Each harness truncates the tables it
// owns to get a clean slate, and those sets overlap: the meetup module's
// harness truncates auth.users (its display-cache and backfill tests need
// real rows there), which is exactly what the auth module's harness is
// populating at the same moment.
//
// The result was a suite that passed almost always and failed occasionally
// for reasons that looked like product bugs. It surfaced when a slower run
// (`-coverpkg`, which instruments everything) widened the window enough to
// make the collision reliable — five tests across two packages failing at
// once, none of them actually broken.
//
// # WHY AN ADVISORY LOCK RATHER THAN `-p 1`
//
// `go test -p 1` would fix it by serialising every package, including the
// many that never touch Postgres — paying for the fix everywhere to solve it
// in two places. It also has to be remembered: a developer running
// `go test ./...` by hand, or a future CI edit, silently loses the
// protection and gets the flakiness back.
//
// A Postgres advisory lock serialises exactly what needs serialising, is
// enforced by the code rather than by a flag, and is released automatically
// when the connection closes — including when a test panics or the process is
// killed, which a lock table or a marker row would not be.
const IntegrationTestLockKey int64 = 0x504D4F4E // "PMON"

// AcquireIntegrationTestLock blocks until this process holds the shared
// integration-test lock, and returns a release function.
//
// Session-scoped (pg_advisory_lock, not pg_advisory_xact_lock) and held on a
// dedicated connection, so it spans the whole test rather than one
// transaction.
func AcquireIntegrationTestLock(ctx context.Context, pool *pgxpool.Pool) (release func(), err error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("db: acquire connection for integration test lock: %w", err)
	}

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", IntegrationTestLockKey); err != nil {
		conn.Release()
		return nil, fmt.Errorf("db: take integration test lock: %w", err)
	}

	return func() {
		// Unlock explicitly, then release the connection. Releasing alone
		// would be enough (the lock dies with the session) — but a pooled
		// connection is REUSED rather than closed, so the session outlives
		// the test and the lock would be held until the pool happened to
		// discard it. That distinction is the whole reason this is easy to
		// get wrong.
		_, _ = conn.Exec(context.WithoutCancel(ctx), "SELECT pg_advisory_unlock($1)", IntegrationTestLockKey)
		conn.Release()
	}, nil
}
