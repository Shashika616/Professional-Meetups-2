// Command backfill-user-display-cache rebuilds meetup.user_display_cache
// from the authoritative rows in auth.users. Ported from the sibling repo's
// services/meetup/cmd/backfill-user-display-cache (docs/plans/
// 03-hardening-pass.md §C3).
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
// This is exactly the kind of tool that is cheap to write calmly now and
// miserable to write for the first time during an incident.
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
//	  go run ./cmd/backfill-user-display-cache
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
		log.Fatalf("backfill-user-display-cache: %v", err)
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

	rows, err := pool.Query(ctx, `
		SELECT id, full_name, COALESCE(profile_photo_url, ''), trust_level, updated_at
		FROM auth.users
		ORDER BY id`)
	if err != nil {
		return fmt.Errorf("read auth.users: %w", err)
	}
	defer rows.Close()

	type user struct {
		id        string
		fullName  string
		photoURL  string
		trust     int16
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
			// THE ORDERING GUARD IS THE POINT, and this is where this port
			// differs from the source in substance rather than plumbing.
			//
			// The source's display-cache backfill wrote `updated_at = now()`
			// with an UNCONDITIONAL DO UPDATE, so a backfill running
			// concurrently with live traffic could overwrite a cache row
			// that a newer user-profile-updated event had already applied —
			// silently reverting a user's just-changed name. (Its
			// location-cache sibling did carry the guard; only this one
			// lacked it.)
			//
			// Here the row's OWN auth.users.updated_at is written, and the
			// upsert applies only if it is strictly newer than what the
			// cache already holds — the identical guard the live consumer
			// uses. A backfill can therefore fill gaps but never regress a
			// row, and it is safe to run against a live system.
			tag, err := tx.Exec(ctx, `
				INSERT INTO meetup.user_display_cache (user_id, full_name, profile_photo_url, trust_level, updated_at)
				VALUES ($1, $2, $3, $4, $5)
				ON CONFLICT (user_id) DO UPDATE
				SET full_name = excluded.full_name,
				    profile_photo_url = excluded.profile_photo_url,
				    trust_level = excluded.trust_level,
				    updated_at = excluded.updated_at
				WHERE excluded.updated_at > meetup.user_display_cache.updated_at`,
				u.id, u.fullName, u.photoURL, u.trust, u.updatedAt)
			if err != nil {
				return fmt.Errorf("upsert display cache for %s: %w", u.id, err)
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
		if err := rows.Scan(&u.id, &u.fullName, &u.photoURL, &u.trust, &u.updatedAt); err != nil {
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
		log.Printf("backfill-user-display-cache: DRY RUN — would have considered %d users (no writes performed)", total)
		return nil
	}
	log.Printf("backfill-user-display-cache: read %d users, applied %d, skipped %d already-newer rows",
		total, applied, skipped)
	return nil
}
