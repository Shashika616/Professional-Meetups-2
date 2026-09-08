package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestRefreshSession_ReuseRevokesTheWholeSessionFamily is the §B1 proof, and
// the assertion that actually matters is the SECOND one: token B — the
// legitimate, correctly-rotated token that the honest client is holding right
// now — must also be revoked.
//
// Rejecting only the replayed token A (the pre-fix behaviour) leaves the
// attacker's stolen chain and the victim's live session running side by side.
// The server cannot tell which party replayed A, so the only safe response is
// to end both. That the honest user is logged out is the intended cost, not
// a side effect to be avoided.
func TestRefreshSession_ReuseRevokesTheWholeSessionFamily(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	user, err := deps.users.Create(ctx, fakeNewUser("li-sub-reuse"))
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	// Token A: the session the client starts with.
	rawA, hashA, err := newRefreshToken()
	if err != nil {
		t.Fatalf("newRefreshToken: %v", err)
	}
	if _, err := deps.tokens.Create(ctx, user.ID, hashA, time.Now().Add(RefreshTokenTTL)); err != nil {
		t.Fatalf("seed refresh token A: %v", err)
	}

	// A legitimate refresh: A is rotated out, B is issued. This is the normal
	// path and must NOT trigger a family revocation.
	rotated, err := svc.RefreshSession(ctx, rawA)
	if err != nil {
		t.Fatalf("legitimate RefreshSession() error: %v", err)
	}
	rawB := rotated.RefreshToken
	if len(deps.tokens.revokeAllCalls) != 0 {
		t.Fatalf("a legitimate rotation triggered a session-family revocation (calls: %v) — reuse detection must not fire on the happy path", deps.tokens.revokeAllCalls)
	}

	// Sanity: B works right now, before the replay.
	if _, err := deps.tokens.FindByHash(ctx, hashToken(rawB)); err != nil {
		t.Fatalf("token B is not present after rotation: %v", err)
	}

	// The replay. An attacker presents A, which the honest client discarded
	// the moment it received B.
	_, err = svc.RefreshSession(ctx, rawA)
	if err == nil {
		t.Fatal("replaying an already-rotated refresh token was accepted")
	}
	if !errors.Is(err, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want it to wrap %v", err, apperror.ErrUnauthorized)
	}

	// THE ASSERTION §B1 EXISTS FOR: token B is now revoked too.
	rowB, err := deps.tokens.FindByHash(ctx, hashToken(rawB))
	if err != nil {
		t.Fatalf("token B row disappeared: %v", err)
	}
	if rowB.RevokedAt == nil {
		t.Fatal("token B — the legitimately rotated, currently-valid token — was NOT revoked after a replay of token A was detected; only the replayed request was rejected, leaving the attacker's chain and the victim's session both live")
	}

	if len(deps.tokens.revokeAllCalls) != 1 || deps.tokens.revokeAllCalls[0] != user.ID {
		t.Errorf("RevokeAllForUser calls = %v, want exactly one for %q", deps.tokens.revokeAllCalls, user.ID)
	}

	// And B is genuinely unusable end to end, not merely flagged in storage.
	if _, err := svc.RefreshSession(ctx, rawB); !errors.Is(err, apperror.ErrUnauthorized) {
		t.Errorf("refreshing with the revoked token B returned %v, want an unauthorized error", err)
	}
}

// TestRefreshSession_ReuseOnlyRevokesTheReportingUsersTokens bounds the blast
// radius. Revoking a session family is a heavy response, and it must be
// scoped to the user whose token was replayed — an unrelated user's session
// must survive untouched, or a single stolen token becomes a denial of
// service against everyone.
func TestRefreshSession_ReuseOnlyRevokesTheReportingUsersTokens(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	victim, _ := deps.users.Create(ctx, fakeNewUser("li-sub-victim"))
	bystander, _ := deps.users.Create(ctx, fakeNewUser("li-sub-bystander"))

	rawVictim, hashVictim, _ := newRefreshToken()
	_, _ = deps.tokens.Create(ctx, victim.ID, hashVictim, time.Now().Add(RefreshTokenTTL))
	rawBystander, hashBystander, _ := newRefreshToken()
	_, _ = deps.tokens.Create(ctx, bystander.ID, hashBystander, time.Now().Add(RefreshTokenTTL))

	// Rotate the victim's token, then replay the old one.
	if _, err := svc.RefreshSession(ctx, rawVictim); err != nil {
		t.Fatalf("seed rotation: %v", err)
	}
	if _, err := svc.RefreshSession(ctx, rawVictim); err == nil {
		t.Fatal("replay was accepted")
	}

	row, err := deps.tokens.FindByHash(ctx, hashBystander)
	if err != nil {
		t.Fatalf("bystander token lookup: %v", err)
	}
	if row.RevokedAt != nil {
		t.Error("an unrelated user's refresh token was revoked by another user's reuse event")
	}
	if _, err := svc.RefreshSession(ctx, rawBystander); err != nil {
		t.Errorf("the bystander's session stopped working after someone else's token was replayed: %v", err)
	}
}

// TestRefreshSession_ReuseStillRejectsWhenRevocationFails pins the error
// posture. If the revocation write fails, the replayed request must still be
// rejected with the same unauthorized error — surfacing the revocation
// failure instead would turn a definite "no" into an ambiguous 500 that a
// client (or an attacker) would simply retry.
func TestRefreshSession_ReuseStillRejectsWhenRevocationFails(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	user, _ := deps.users.Create(ctx, fakeNewUser("li-sub-revokefail"))
	rawA, hashA, _ := newRefreshToken()
	_, _ = deps.tokens.Create(ctx, user.ID, hashA, time.Now().Add(RefreshTokenTTL))
	if _, err := svc.RefreshSession(ctx, rawA); err != nil {
		t.Fatalf("seed rotation: %v", err)
	}

	deps.tokens.revokeAllErr = errors.New("database unavailable")

	_, err := svc.RefreshSession(ctx, rawA)
	if err == nil {
		t.Fatal("the replayed token was accepted when the family revocation failed")
	}
	if !errors.Is(err, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want it to still wrap %v (a revocation failure must not change the rejection into a retryable server error)", err, apperror.ErrUnauthorized)
	}
}
