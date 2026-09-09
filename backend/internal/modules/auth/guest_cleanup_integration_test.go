package auth_test

// Plan 14 Part B: abandoned-guest cleanup, against real Postgres and the
// real DELETE. A fake would only re-assert the eligibility rules in Go;
// these tests exist to pin the actual SQL's WHERE clause.

import (
	"context"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth"
)

// seedUserRow inserts a user directly. Direct SQL rather than the service
// because there is no API that produces a row already older than the
// retention window, and the age is the whole point.
func seedUserRow(t *testing.T, h *harness, isGuest bool, updatedAt time.Time) string {
	t.Helper()
	var id string
	if err := h.pool.QueryRow(context.Background(), `
		INSERT INTO auth.users (full_name, trust_level, is_guest, age_confirmed_over_18, created_at, updated_at)
		VALUES ($1, 0, $2, true, $3, $3)
		RETURNING id::text`,
		"Cleanup Subject", isGuest, updatedAt,
	).Scan(&id); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return id
}

func seedRefreshTokenRow(t *testing.T, h *harness, userID string, expiresAt time.Time) {
	t.Helper()
	if _, err := h.pool.Exec(context.Background(), `
		INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
		VALUES ($1, $2, $3)`,
		userID, "hash-"+userID, expiresAt,
	); err != nil {
		t.Fatalf("seed refresh token: %v", err)
	}
}

func userExists(t *testing.T, h *harness, userID string) bool {
	t.Helper()
	var exists bool
	if err := h.pool.QueryRow(context.Background(),
		`SELECT EXISTS(SELECT 1 FROM auth.users WHERE id = $1)`, userID,
	).Scan(&exists); err != nil {
		t.Fatalf("check user exists: %v", err)
	}
	return exists
}

func TestGuestCleanup_EligibilityRules_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	pastRetention := time.Now().UTC().Add(-auth.RefreshTokenRetention - time.Hour)
	insideRetention := time.Now().UTC().Add(-time.Hour)

	// Eligible: a guest, no refresh-token row at all, past the window.
	abandoned := seedUserRow(t, h, true, pastRetention)

	// Survives — still has a token row, so the account is still reachable.
	withLiveToken := seedUserRow(t, h, true, pastRetention)
	seedRefreshTokenRow(t, h, withLiveToken, time.Now().UTC().Add(24*time.Hour))

	// Survives — a DEAD token row still blocks deletion. The token sweep in
	// the same tick removes it first, so this account becomes eligible on a
	// later tick, never in the same one.
	withDeadToken := seedUserRow(t, h, true, pastRetention)
	seedRefreshTokenRow(t, h, withDeadToken, time.Now().UTC().Add(-90*24*time.Hour))

	// Survives — NOT a guest. The assertion that most needs to never
	// regress: is_guest is a hard exclusion, and a real account with no
	// live session is an ordinary signed-out user, not litter.
	upgraded := seedUserRow(t, h, false, pastRetention)

	// Survives — a guest, tokenless, but inside the grace window.
	recent := seedUserRow(t, h, true, insideRetention)

	deleted, err := h.svc.SweepAbandonedGuests(ctx)
	if err != nil {
		t.Fatalf("SweepAbandonedGuests: %v", err)
	}
	if deleted < 1 {
		t.Fatalf("deleted = %d, want at least the one abandoned guest", deleted)
	}

	if userExists(t, h, abandoned) {
		t.Error("an abandoned guest past retention survived the sweep")
	}
	for _, tc := range []struct {
		id, why string
	}{
		{withLiveToken, "a guest with a live refresh token"},
		{withDeadToken, "a guest whose token row still exists (dead or not)"},
		{upgraded, "a NON-GUEST account with no tokens — is_guest must be a hard exclusion"},
		{recent, "a guest still inside the retention grace window"},
	} {
		if !userExists(t, h, tc.id) {
			t.Errorf("%s was deleted, want it kept", tc.why)
		}
	}
}

// The two sweeps compose: the token sweep clears the last dead row, and the
// guest cleanup then finds the account tokenless. This is why Tick runs them
// in that order.
func TestGuestCleanup_RunsAfterTheTokenSweepClearsTheLastRow_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	pastRetention := time.Now().UTC().Add(-auth.RefreshTokenRetention - time.Hour)
	guest := seedUserRow(t, h, true, pastRetention)
	// Long expired, so the token sweep is eligible to remove it.
	seedRefreshTokenRow(t, h, guest, time.Now().UTC().Add(-90*24*time.Hour))

	// Guest cleanup alone cannot touch it — the token row is still there.
	if _, err := h.svc.SweepAbandonedGuests(ctx); err != nil {
		t.Fatalf("SweepAbandonedGuests (before token sweep): %v", err)
	}
	if !userExists(t, h, guest) {
		t.Fatal("the guest was deleted while a refresh-token row still existed")
	}

	if _, err := h.svc.SweepExpiredRefreshTokens(ctx); err != nil {
		t.Fatalf("SweepExpiredRefreshTokens: %v", err)
	}
	if _, err := h.svc.SweepAbandonedGuests(ctx); err != nil {
		t.Fatalf("SweepAbandonedGuests (after token sweep): %v", err)
	}
	if userExists(t, h, guest) {
		t.Error("the guest survived after its last token row was swept")
	}
}

// ADR-003's Consequences claim the cleanup needs only two conditions
// because a guest can never write to trusted_contacts/sos_events. This pins
// the deletion side of that: the cascading FKs actually fire, so a deleted
// guest leaves nothing behind in the auth schema.
func TestGuestCleanup_CascadesAuthSchemaRows_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	pastRetention := time.Now().UTC().Add(-auth.RefreshTokenRetention - time.Hour)
	guest := seedUserRow(t, h, true, pastRetention)

	if _, err := h.pool.Exec(ctx, `
		INSERT INTO auth.verification_codes (user_id, purpose, target, code_hash, expires_at)
		VALUES ($1, 'phone', '+94771234567', 'hash', now() + interval '1 hour')`,
		guest,
	); err != nil {
		t.Fatalf("seed verification code: %v", err)
	}

	if _, err := h.svc.SweepAbandonedGuests(ctx); err != nil {
		t.Fatalf("SweepAbandonedGuests: %v", err)
	}
	if userExists(t, h, guest) {
		t.Fatal("the guest was not deleted")
	}

	var orphans int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.verification_codes WHERE user_id = $1`, guest,
	).Scan(&orphans); err != nil {
		t.Fatalf("count orphans: %v", err)
	}
	if orphans != 0 {
		t.Errorf("%d verification_codes row(s) survived the user, want 0 — the FK cascade did not fire", orphans)
	}
}
