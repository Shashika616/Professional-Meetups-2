package auth_test

// §B3: the auth.refresh_tokens retention sweep, against real Postgres and
// the real DELETE — a fake repository would only re-assert the eligibility
// rules this test exists to pin against the actual SQL.

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth"
)

// TestRefreshTokenSweep_DeletesOnlyIneligibleRows is the §B3 proof. The
// dangerous failure mode is not "it didn't delete enough" — it is deleting a
// row that still authenticates someone, which signs a user out for no
// reason. So the assertion that matters most is the last one: the live token
// survives, and still works end to end after the sweep.
func TestRefreshTokenSweep_DeletesOnlyIneligibleRows_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "sweep-eligibility@example.com")
	userID := session.UserID

	// The one row that must survive: issued just now by the real signup.
	liveToken := session.RefreshToken

	// Seed the three ineligible shapes directly. Going through SQL rather
	// than the service is deliberate — there is no API that produces a
	// long-expired row, and the point is to test the DELETE's own WHERE
	// clause against rows in exactly those states.
	seed := func(label string, expiresAt time.Time, revoked bool) {
		t.Helper()
		var revokedAt any
		if revoked {
			revokedAt = time.Now().Add(-time.Minute)
		}
		_, err := h.pool.Exec(ctx, `
			INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at, revoked_at)
			VALUES ($1, $2, $3, $4)`,
			userID, "hash-"+label, expiresAt, revokedAt)
		if err != nil {
			t.Fatalf("seed %s: %v", label, err)
		}
	}

	now := time.Now()
	// Revoked but not expired — eligible immediately, because a revoked row
	// is already dead regardless of its expiry.
	seed("revoked-but-unexpired", now.Add(24*time.Hour), true)
	// Expired longer ago than the retention window — eligible.
	seed("long-expired", now.Add(-auth.RefreshTokenRetention-time.Hour), false)
	// Expired, but INSIDE the retention grace window — must survive, so a
	// recent expiry is still inspectable while debugging.
	seed("recently-expired", now.Add(-time.Hour), false)
	// Not expired, not revoked — must survive.
	seed("live-unused", now.Add(24*time.Hour), false)

	before := countRefreshTokens(t, h.pool, userID)
	if before != 5 { // 4 seeded + the real one from signup
		t.Fatalf("seeded row count = %d, want 5", before)
	}

	deleted, err := h.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v", err)
	}
	if deleted != 2 {
		t.Errorf("sweep deleted %d rows, want exactly 2 (the revoked one and the long-expired one)", deleted)
	}

	remaining := remainingHashes(t, h.pool, userID)
	for _, gone := range []string{"hash-revoked-but-unexpired", "hash-long-expired"} {
		if _, present := remaining[gone]; present {
			t.Errorf("%s survived the sweep — it can never authenticate anything again and should have been deleted", gone)
		}
	}
	for _, kept := range []string{"hash-recently-expired", "hash-live-unused"} {
		if _, present := remaining[kept]; !present {
			t.Errorf("%s was deleted by the sweep — only rows that can never authenticate again are eligible", kept)
		}
	}

	// The assertion that actually protects users: the live session still
	// works after the sweep ran.
	if _, err := h.svc.RefreshSession(ctx, liveToken); err != nil {
		t.Fatalf("the sweep broke a live session — refreshing with a token issued moments ago failed: %v", err)
	}
}

// TestRefreshTokenSweep_IsIdempotentAndBatches covers the loop: a second
// sweep with nothing eligible must delete nothing (and not error), and a
// backlog larger than one batch must still be fully drained in one tick
// rather than leaving rows behind until the next hour.
func TestRefreshTokenSweep_IsIdempotentAndBatches_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "sweep-batching@example.com")

	// More rows than one DELETE batch (1000), so the loop has to run at
	// least twice to clear them.
	const backlog = 1200
	_, err := h.pool.Exec(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at, revoked_at)
		SELECT $1, 'backlog-' || g, now() + interval '1 day', now()
		FROM generate_series(1, $2) AS g`,
		session.UserID, backlog)
	if err != nil {
		t.Fatalf("seed backlog: %v", err)
	}

	deleted, err := h.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v", err)
	}
	if deleted != backlog {
		t.Errorf("sweep deleted %d rows, want %d — a backlog larger than one batch must still be fully drained by looping, not truncated at the batch size", deleted, backlog)
	}

	// Second run: nothing left to do.
	again, err := h.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		t.Fatalf("second SweepExpiredRefreshTokens: %v", err)
	}
	if again != 0 {
		t.Errorf("second sweep deleted %d rows, want 0 — the sweep must be idempotent", again)
	}

	// The signup's own token is untouched by any of this.
	if _, err := h.svc.RefreshSession(ctx, session.RefreshToken); err != nil {
		t.Errorf("the live session did not survive a large sweep: %v", err)
	}
}

// TestRefreshTokenSweeper_TickStopsOnCancelledContext pins the shutdown
// posture shared by every background loop in this process: a cancelled
// context ends the work promptly instead of holding SIGTERM open for a
// full backlog drain.
func TestRefreshTokenSweeper_TickStopsOnCancelledContext_Integration(t *testing.T) {
	h := newHarness(t)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	deleted, err := h.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		t.Fatalf("a cancelled sweep should return cleanly, got: %v", err)
	}
	if deleted != 0 {
		t.Errorf("a sweep on an already-cancelled context deleted %d rows, want 0", deleted)
	}
}

func countRefreshTokens(t *testing.T, pool *pgxpool.Pool, userID string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM auth.refresh_tokens WHERE user_id = $1`, userID).Scan(&n); err != nil {
		t.Fatalf("count refresh tokens: %v", err)
	}
	return n
}

func remainingHashes(t *testing.T, pool *pgxpool.Pool, userID string) map[string]struct{} {
	t.Helper()
	rows, err := pool.Query(context.Background(),
		`SELECT token_hash FROM auth.refresh_tokens WHERE user_id = $1`, userID)
	if err != nil {
		t.Fatalf("list refresh tokens: %v", err)
	}
	defer rows.Close()

	out := map[string]struct{}{}
	for rows.Next() {
		var hash string
		if err := rows.Scan(&hash); err != nil {
			t.Fatalf("scan token hash: %v", err)
		}
		out[hash] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate token hashes: %v", err)
	}
	return out
}
