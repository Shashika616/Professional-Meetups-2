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

// A rotation chain must be deletable. This is the bug the Cloud Scheduler
// tick surfaced on 2026-10-22, the first time anything reported the sweep's
// return value instead of logging it:
//
//	repository: delete expired refresh tokens: ERROR: update or delete on
//	table "refresh_tokens" violates foreign key constraint
//	"refresh_tokens_replaced_by_fkey"
//
// `replaced_by` is a self-reference with no ON DELETE action, and rotation
// points the OLD row at the NEW one. Deleting an arbitrary batch therefore
// failed whenever it contained a referenced row without its referrer — in
// production, on every single run, so the table had never been swept at all.
//
// Nothing in the old test caught it because every row it seeds is
// unreferenced: a chain is the one shape that triggers the constraint.
func TestRefreshTokenSweep_DeletesAWholeRotationChain_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "sweep-chain@example.com")
	userID := session.UserID

	// Three dead rows linked oldest -> newest, the shape rotation leaves
	// behind: oldest.replaced_by = middle, middle.replaced_by = newest.
	// All three are long expired, so all three are eligible.
	expired := time.Now().Add(-auth.RefreshTokenRetention - time.Hour)
	insert := func(label string) string {
		t.Helper()
		var id string
		err := h.pool.QueryRow(ctx, `
			INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
			VALUES ($1, $2, $3) RETURNING id`,
			userID, "chain-"+label, expired).Scan(&id)
		if err != nil {
			t.Fatalf("insert %s: %v", label, err)
		}
		return id
	}
	link := func(from, to string) {
		t.Helper()
		if _, err := h.pool.Exec(ctx,
			`UPDATE auth.refresh_tokens SET replaced_by = $2 WHERE id = $1`,
			from, to); err != nil {
			t.Fatalf("link: %v", err)
		}
	}

	newest := insert("newest")
	middle := insert("middle")
	oldest := insert("oldest")
	link(middle, newest)
	link(oldest, middle)

	// Before the fix this returns the FK error and deletes nothing.
	deleted, err := h.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v\n"+
			"A rotation chain must be deletable. The DELETE has to take "+
			"each chain from its oldest end, because the FK forbids "+
			"removing a row another row still points at.", err)
	}
	if deleted < 3 {
		t.Errorf("deleted %d rows, want at least the 3 chained ones.\n"+
			"One pass peels one layer, so the caller must loop until a "+
			"pass deletes nothing rather than stopping on a short batch.",
			deleted)
	}

	for _, tc := range []struct{ label, id string }{
		{"oldest", oldest}, {"middle", middle}, {"newest", newest},
	} {
		var n int
		if err := h.pool.QueryRow(ctx,
			`SELECT count(*) FROM auth.refresh_tokens WHERE id = $1`,
			tc.id).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", tc.label, err)
		}
		if n != 0 {
			t.Errorf("%s row survived the sweep", tc.label)
		}
	}

	// The live token from signup must be untouched: it is not expired, so
	// no amount of chain-unwinding may reach it.
	var live int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.refresh_tokens
		 WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()`,
		userID).Scan(&live); err != nil {
		t.Fatalf("count live: %v", err)
	}
	if live != 1 {
		t.Errorf("%d live tokens after the sweep, want 1", live)
	}
}

// The actual production failure, 2026-10-22: a LIVE row pointing at a DEAD
// one.
//
// Rotation sets old.replaced_by = new but does NOT revoke the old row, so a
// referrer can outlive what it points at: the replacement expires while the
// referrer is still unexpired and unrevoked. Deleting the referenced row
// then leaves a dangling pointer, and Postgres refuses:
//
//	ERROR: update or delete on table "refresh_tokens" violates foreign key
//	constraint "refresh_tokens_replaced_by_fkey"
//
// 17 rows in production were in exactly this state, which is why the sweep
// failed on every run and the table had never been swept at all.
//
// Note what does NOT reproduce it: a chain where every row is eligible.
// Postgres checks the FK at end of statement, so a single DELETE that
// removes the whole chain is accepted. The violation needs a SURVIVOR
// holding the pointer.
func TestRefreshTokenSweep_SkipsADeadRowALiveTokenStillPointsAt_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "sweep-live-referrer@example.com")
	userID := session.UserID

	// The dead replacement: expired well past the retention window, so the
	// sweep considers it eligible.
	var deadID string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
		VALUES ($1, 'live-referrer-dead', $2) RETURNING id`,
		userID, time.Now().Add(-auth.RefreshTokenRetention-time.Hour),
	).Scan(&deadID); err != nil {
		t.Fatalf("insert dead replacement: %v", err)
	}

	// The live referrer: not revoked, not expired, pointing at the dead row.
	var liveID string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at, replaced_by)
		VALUES ($1, 'live-referrer', $2, $3) RETURNING id`,
		userID, time.Now().Add(30*24*time.Hour), deadID,
	).Scan(&liveID); err != nil {
		t.Fatalf("insert live referrer: %v", err)
	}

	// Before the fix this returns the foreign-key error and deletes nothing
	// — including every unrelated eligible row in the same batch.
	if _, err := h.svc.SweepExpiredRefreshTokens(ctx); err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v\n"+
			"A dead row that a surviving row still points at must be "+
			"SKIPPED, not deleted. One such row must not fail the whole "+
			"sweep.", err)
	}

	// The dead row has to stay: the FK requires it while the pointer lives.
	// It becomes deletable on a later sweep, once the referrer is eligible.
	var deadLeft, liveLeft int
	if err := h.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE id = $1), count(*) FILTER (WHERE id = $2)
		FROM auth.refresh_tokens WHERE id IN ($1, $2)`,
		deadID, liveID).Scan(&deadLeft, &liveLeft); err != nil {
		t.Fatalf("count: %v", err)
	}
	if deadLeft != 1 {
		t.Error("the referenced row was deleted; the pointer is now dangling")
	}
	if liveLeft != 1 {
		t.Error("the LIVE token was deleted — this signs a user out for no reason")
	}
}

// One unreachable row must not block the rest of the sweep. Before the fix
// the FK error aborted the whole DELETE, so a single stuck pair kept every
// other eligible row in the table forever.
func TestRefreshTokenSweep_StillClearsOtherRowsAroundAStuckPair_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	session := h.signUpByEmail(t, "sweep-around-stuck@example.com")
	userID := session.UserID
	expired := time.Now().Add(-auth.RefreshTokenRetention - time.Hour)

	var deadID string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
		VALUES ($1, 'stuck-dead', $2) RETURNING id`,
		userID, expired).Scan(&deadID); err != nil {
		t.Fatalf("insert stuck row: %v", err)
	}
	if _, err := h.pool.Exec(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at, replaced_by)
		VALUES ($1, 'stuck-live-referrer', $2, $3)`,
		userID, time.Now().Add(30*24*time.Hour), deadID); err != nil {
		t.Fatalf("insert referrer: %v", err)
	}

	// An ordinary eligible row, unrelated to the stuck pair.
	var ordinaryID string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
		VALUES ($1, 'stuck-ordinary', $2) RETURNING id`,
		userID, expired).Scan(&ordinaryID); err != nil {
		t.Fatalf("insert ordinary row: %v", err)
	}

	if _, err := h.svc.SweepExpiredRefreshTokens(ctx); err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v", err)
	}

	var n int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.refresh_tokens WHERE id = $1`,
		ordinaryID).Scan(&n); err != nil {
		t.Fatalf("count ordinary: %v", err)
	}
	if n != 0 {
		t.Error("an ordinary expired row survived because another row was stuck")
	}
}
