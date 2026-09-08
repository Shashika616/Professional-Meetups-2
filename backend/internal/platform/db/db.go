// Package db is the monolith's Postgres plumbing: a thin pgxpool wrapper and
// a migration runner. One pool, shared by every module (ADR-001 §3 — one
// database, one schema per module), constructed once in cmd/monolith's main
// and handed to each module's repositories.
package db

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"time"

	"github.com/golang-migrate/migrate/v4"
	migratepostgres "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file" // file:// migration source
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib" // database/sql driver, needed only to drive migrate
)

// MaxConns caps the monolith's Postgres connection pool. The sibling repo
// set this per service (10 each, deliberately documented rather than left at
// the pgxpool default); here one process serves every module, so it gets one
// pool — sized higher than any single service's share was, since it now
// carries auth's, meetup's and billing's traffic together, but still an
// explicit, reviewable number rather than a library default.
const MaxConns = 20

// StatementTimeout is the hard backstop on any single SQL statement (§B2).
//
// THE FAILURE THIS PREVENTS is specific to the monolith and did not exist in
// the microservices system it replaces: one pool is shared by every module.
// A single query that never finishes — lock contention, a missing index
// after a data-shape change, a migration running concurrently — holds its
// pooled connection indefinitely. Enough of those and the pool is exhausted,
// at which point AUTH stops working because of a bug in MEETUP. Each service
// used to have its own pool, so a stuck query could only starve its own
// service.
//
// Set on the server side via the connection string rather than relying on
// context deadlines alone, deliberately: a context cancellation asks pgx to
// abandon the query and issue a cancel request, while statement_timeout
// makes POSTGRES itself abort the backend. The first depends on this process
// still being healthy enough to act; the second does not. Both are wired —
// this one as the backstop, the per-RPC deadline in cmd/monolith as the
// primary, more granular control.
//
// 10 seconds is comfortably above any legitimate query here (the slowest are
// the PostGIS radius scans, which are indexed and bounded at 500 rows) and
// far below anything a user would wait through.
const StatementTimeout = 10 * time.Second

// New opens a connection pool against databaseURL and verifies it is
// actually reachable before returning — a process that can't reach its
// database should fail at startup, not on its first request.
func New(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("db: parse database url: %w", err)
	}
	cfg.MaxConns = MaxConns

	// Applied through RuntimeParams rather than appended to the URL string:
	// the caller's DATABASE_URL may already carry its own query parameters
	// (sslmode, application_name), and string-concatenating another one is
	// how a "?" vs "&" bug gets introduced. This also means an operator
	// CANNOT accidentally remove the timeout by editing the URL — the value
	// is owned by this package.
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = strconv.Itoa(int(StatementTimeout.Milliseconds()))

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: connect to postgres: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db: ping postgres: %w", err)
	}

	return pool, nil
}

// Migrate applies every pending migration under migrationsURL (a
// golang-migrate source URL, e.g. "file://../../migrations") to the database
// at databaseURL, and is a no-op when there is nothing to apply.
//
// golang-migrate, not a different tool: it is what the sibling repo already
// uses, both as the migrate/migrate container in its docker-compose.yml and
// as a library in its own integration tests, and this repo's
// docker-compose.yml already pins migrate/migrate:v4.17.1 for the same job.
// In normal operation the container is what runs migrations; this function
// exists so integration tests can bring a schema up themselves without
// shelling out to Docker.
func Migrate(databaseURL, migrationsURL string) error {
	sqlDB, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return fmt.Errorf("db: open sql connection for migrate: %w", err)
	}
	defer func() { _ = sqlDB.Close() }()

	driver, err := migratepostgres.WithInstance(sqlDB, &migratepostgres.Config{})
	if err != nil {
		return fmt.Errorf("db: create migrate driver: %w", err)
	}

	m, err := migrate.NewWithDatabaseInstance(migrationsURL, "postgres", driver)
	if err != nil {
		return fmt.Errorf("db: create migrate instance: %w", err)
	}

	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return fmt.Errorf("db: run migrations: %w", err)
	}
	return nil
}
