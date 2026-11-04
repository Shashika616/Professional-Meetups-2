// Command backfill-photos downloads each LinkedIn picture still stored as an
// external address into auth.user_photos, once (plan 2.1).
//
// NOT A SERVICE. An operator runs it once after plan 30D is deployed, then
// runs backfill-user-display-cache so meetup cards pick up the new paths
// (runbook §3a). A picture that cannot be fetched leaves no photo: the
// address is cleared, and after this no external address is stored.
//
// Safe to re-run: it selects only rows still holding an external address, so
// a finished account is never touched. The same fetch rules apply as for a
// new account: https, licdn.com only, 5 seconds, 2 MB.
//
// Usage:
//
//	DATABASE_URL=... go run ./cmd/backfill-photos --dry-run
//	DATABASE_URL=... go run ./cmd/backfill-photos
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/auth/photo"
)

func main() {
	dryRun := flag.Bool("dry-run", false, "report what would change without changing anything")
	flag.Parse()
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("backfill-photos: DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		log.Fatalf("backfill-photos: connect: %v", err)
	}
	defer pool.Close()
	got, failed, err := run(ctx, pool, photo.NewFetcher(), *dryRun, os.Stdout)
	if err != nil {
		log.Fatalf("backfill-photos: %v", err)
	}
	fmt.Printf("stored %d, cleared %d\n", got, failed)
}

type row struct{ ID, Address string }

func run(ctx context.Context, pool *pgxpool.Pool, fetcher auth.PhotoFetcher, dryRun bool, out *os.File) (stored, cleared int, err error) {
	rows, err := pool.Query(ctx, `SELECT id::text, profile_photo_url FROM auth.users WHERE profile_photo_url LIKE 'http%'`)
	if err != nil {
		return 0, 0, fmt.Errorf("list users: %w", err)
	}
	pending, err := pgx.CollectRows(rows, pgx.RowToStructByPos[row])
	if err != nil {
		return 0, 0, fmt.Errorf("list users: %w", err)
	}
	for _, r := range pending {
		jpeg, w, h, fetchErr := fetcher.Fetch(ctx, r.Address)
		if dryRun {
			if fetchErr == nil {
				stored++
			} else {
				cleared++
			}
			continue
		}
		if fetchErr != nil {
			if _, err := pool.Exec(ctx, `UPDATE auth.users SET profile_photo_url = NULL WHERE id = $1`, r.ID); err != nil {
				return stored, cleared, fmt.Errorf("clear %s: %w", r.ID, err)
			}
			cleared++
			continue
		}
		if err := store(ctx, pool, r.ID, jpeg, w, h); err != nil {
			return stored, cleared, err
		}
		stored++
	}
	if dryRun {
		_, _ = fmt.Fprintln(out, "dry run: nothing changed")
	}
	return stored, cleared, nil
}

func store(ctx context.Context, pool *pgxpool.Pool, userID string, jpeg []byte, w, h int) error {
	etag := photo.Etag(jpeg)
	return pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			INSERT INTO auth.user_photos (user_id, jpeg, etag, width, height, bytes)
			VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (user_id) DO NOTHING`, userID, jpeg, etag, w, h, len(jpeg)); err != nil {
			return fmt.Errorf("store %s: %w", userID, err)
		}
		_, err := tx.Exec(ctx, `UPDATE auth.users SET profile_photo_url = $2 WHERE id = $1`, userID, photo.Path(userID, etag))
		if err != nil {
			return errors.Join(fmt.Errorf("update %s", userID), err)
		}
		return nil
	})
}
