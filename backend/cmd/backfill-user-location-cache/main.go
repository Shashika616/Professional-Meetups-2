// Command backfill-user-location-cache rebuilds meetup.user_location_cache
// from the authoritative last-known-location columns on auth.users. Ported
// from the sibling repo's services/meetup/cmd/backfill-user-location-cache
// (docs/plans/03-hardening-pass.md §C3), sibling to
// cmd/backfill-user-location-cache and identical in shape.
//
// NOT A SERVICE. It is never wired into docker-compose.yml, never deployed,
// and runs to completion and exits. It exists for one reason: the display
// cache is fed by events on an in-process bus with NO durability
// (internal/eventbus's package doc is explicit about the accepted
// commit-then-crash loss window), so there has to be a way to rebuild it from
// the authoritative data. Without this tool, a lost user-onboarded event
// means a user's name is blank on every meetup card until the next time they
// happen to edit their profile — which for someone who never edits it is
// forever.
//
// The cache it rebuilds backs the meetup-created nearby-notify fan-out. A
// user missing from it is simply never told about meetups near them, with
// nothing anywhere to indicate why — a silent absence rather than a visible
// error, which is what makes having this tool matter.
//
// Only users with a recorded location are backfilled: someone whose location
// has never been read has nothing to seed.
//
// # ONE DATABASE, NOT TWO — the deliberate deviation from the source
//
// The source took SOURCE_DATABASE_URL (auth_db) and DEST_DATABASE_URL
// (meetup_db) because those were genuinely separate databases, and its own
// comments flagged a "closing window" where both had to remain mutually
// reachable. Here there is one database with a schema per module (ADR-001
// §3), so both halves are a single DATABASE_URL and that entire caveat is
// gone. The cross-schema read is confined to this operator tool and does not
// exist in the running system — the meetup module still never reads
// auth.users at request time.
//
// Safe to re-run. Every row is an order-guarded upsert.
//
// Usage:
//
//	DATABASE_URL=postgres://app:app@localhost:5432/monolith_db?sslmode=disable \
//	  go run ./cmd/backfill-user-location-cache
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	dryRun := flag.Bool("dry-run", false, "report what would be written without writing anything")
	batchSize := flag.Int("batch-size", 500, "rows per transaction")
	flag.Parse()

	if err := run(*dryRun, *batchSize); err != nil {
		log.Fatalf("backfill-user-location-cache: %v", err)
	}
}

func run(dryRun bool, batchSize int) error {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	if batchSize <= 0 {
		return errors.New("--batch-size must be positive")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer pool.Close()

	// Only rows that actually have a location. last_location_updated_at is
	// COALESCEd to the row's own updated_at rather than to now(): a NULL
	// there alongside non-null coordinates should not happen
	// (UpdateLastKnownLocation always writes all three together), but if it
	// ever did, falling back to now() would stamp stale coordinates as
	// brand-new and let this backfill beat a genuinely newer live event
	// through the ordering guard — the exact regression the guard exists to
	// prevent.
	rows, err := pool.Query(ctx, `
		SELECT id, last_location_lat, last_location_lng,
		       COALESCE(last_location_updated_at, updated_at)
		FROM auth.users
		WHERE last_location_lat IS NOT NULL AND last_location_lng IS NOT NULL
		ORDER BY id`)
	if err != nil {
		return fmt.Errorf("read auth.users locations: %w", err)
	}
	defer rows.Close()

	type user struct {
		id        string
		lat       float64
		lng       float64
		updatedAt time.Time
	}

	var pending []user
	total, applied, skipped := 0, 0, 0

	// flush writes one batch. Batched rather than one big transaction so a
	// large user table does not hold a single long-running transaction (and
	// its locks) for the whole run.
	flush := func() error {
		if len(pending) == 0 {
			return nil
		}
		if dryRun {
			pending = pending[:0]
			return nil
		}

		tx, err := pool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin batch: %w", err)
		}
		defer func() { _ = tx.Rollback(ctx) }()

		for _, u := range pending {
			// The same ordering guard the live consumer uses: apply only
			// if this row is strictly newer than what the cache already
			// holds. Carried over from the source, which got this one right
			// (its display-cache sibling did not — see that command's own
			// comment). A backfill can fill gaps but never regress a row,
			// which is what makes it safe to run against a live system.
			tag, err := tx.Exec(ctx, `
				INSERT INTO meetup.user_location_cache (user_id, lat, lng, updated_at)
				VALUES ($1, $2, $3, $4)
				ON CONFLICT (user_id) DO UPDATE
				SET lat = excluded.lat,
				    lng = excluded.lng,
				    updated_at = excluded.updated_at
				WHERE excluded.updated_at > meetup.user_location_cache.updated_at`,
				u.id, u.lat, u.lng, u.updatedAt)
			if err != nil {
				return fmt.Errorf("upsert location cache for %s: %w", u.id, err)
			}
			if tag.RowsAffected() > 0 {
				applied++
			} else {
				skipped++
			}
		}

		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("commit batch: %w", err)
		}
		pending = pending[:0]
		return nil
	}

	for rows.Next() {
		var u user
		if err := rows.Scan(&u.id, &u.lat, &u.lng, &u.updatedAt); err != nil {
			return fmt.Errorf("scan auth.users row: %w", err)
		}
		pending = append(pending, u)
		total++

		if len(pending) >= batchSize {
			if err := flush(); err != nil {
				return err
			}
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate auth.users: %w", err)
	}
	if err := flush(); err != nil {
		return err
	}

	if dryRun {
		log.Printf("backfill-user-location-cache: DRY RUN — would have considered %d users with a recorded location (no writes performed)", total)
		return nil
	}
	log.Printf("backfill-user-location-cache: read %d users with a recorded location, applied %d, skipped %d already-newer rows",
		total, applied, skipped)
	return nil
}
