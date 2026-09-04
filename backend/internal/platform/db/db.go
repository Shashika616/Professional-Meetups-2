// Package db is the monolith's Postgres plumbing: a thin pgxpool wrapper and
// a migration runner. One pool, shared by every module (ADR-001 §3 — one
// database, one schema per module), constructed once in cmd/monolith's main
// and handed to each module's repositories.
package db

import (
	"context"
	"database/sql"
	"fmt"

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

// New opens a connection pool against databaseURL and verifies it is
// actually reachable before returning — a process that can't reach its
// database should fail at startup, not on its first request.
func New(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("db: parse database url: %w", err)
	}
	cfg.MaxConns = MaxConns

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
