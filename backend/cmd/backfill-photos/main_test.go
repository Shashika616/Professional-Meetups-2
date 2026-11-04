package main

import (
	"context"
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/platform/db"
)

type fakeFetcher struct{ failFor string }

func (f fakeFetcher) Fetch(_ context.Context, u string) ([]byte, int, int, error) {
	if u == f.failFor {
		return nil, 0, 0, errors.New("gone")
	}
	return []byte{0xff, 0xd8}, 320, 320, nil
}

func TestBackfill_Integration(t *testing.T) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp", parsed.Host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable: %v", err)
	}
	_ = conn.Close()
	ctx := context.Background()
	testURL, err := db.EnsureTestDatabase(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(testURL, "file://../../migrations"); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, testURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	release, err := db.AcquireIntegrationTestLock(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if _, err := pool.Exec(ctx, `TRUNCATE auth.users CASCADE`); err != nil {
		t.Fatal(err)
	}
	seed := func(photo string) string {
		var id string
		if err := pool.QueryRow(ctx, `INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18, profile_photo_url)
			VALUES ('A', 1, true, NULLIF($1, '')) RETURNING id::text`, photo).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	good := seed("https://media.licdn.com/good.jpg")
	bad := seed("https://media.licdn.com/gone.jpg")
	done := seed("/v1/users/x/photo?v=e")
	none := seed("")

	devNull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = devNull.Close() }()
	fetcher := fakeFetcher{failFor: "https://media.licdn.com/gone.jpg"}

	stored, cleared, err := run(ctx, pool, fetcher, true, devNull)
	if err != nil || stored != 1 || cleared != 1 {
		t.Fatalf("dry run: %d, %d, %v", stored, cleared, err)
	}
	var photos int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM auth.user_photos`).Scan(&photos)
	if photos != 0 {
		t.Fatal("a dry run wrote")
	}

	if stored, cleared, err = run(ctx, pool, fetcher, false, devNull); err != nil || stored != 1 || cleared != 1 {
		t.Fatalf("run: %d, %d, %v", stored, cleared, err)
	}
	read := func(id string) string {
		var v *string
		if err := pool.QueryRow(ctx, `SELECT profile_photo_url FROM auth.users WHERE id = $1`, id).Scan(&v); err != nil {
			t.Fatal(err)
		}
		if v == nil {
			return ""
		}
		return *v
	}
	if got := read(good); !strings.HasPrefix(got, "/v1/users/"+good+"/photo?v=") {
		t.Errorf("good: %q", got)
	}
	if got := read(bad); got != "" {
		t.Errorf("a failed fetch left %q", got)
	}
	if got := read(done); got != "/v1/users/x/photo?v=e" {
		t.Errorf("a finished account changed: %q", got)
	}
	if got := read(none); got != "" {
		t.Errorf("an account with no photo got %q", got)
	}
	// Re-running finds nothing to do.
	if stored, cleared, err = run(ctx, pool, fetcher, false, devNull); err != nil || stored+cleared != 0 {
		t.Errorf("a second run: %d, %d, %v", stored, cleared, err)
	}
}
