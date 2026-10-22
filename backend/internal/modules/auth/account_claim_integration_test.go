package auth_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The claim ceremony against real Postgres. The fakes can prove the service
// logic; only this can prove the two migrations it rests on — 0017's
// case-insensitive unique index on personal_email, and 0018's account_claim
// value on the verification_purpose enum. A missing enum value fails at the
// INSERT, which no fake would ever notice.

// appleSignIn runs the real federated signup for an Apple token carrying
// email, and returns whatever it produced.
func appleSignIn(t *testing.T, h *harness, token, subject, email string) (auth.SessionResult, error) {
	t.Helper()
	h.apple.validTokens[token] = identity.VerifiedIdentity{
		Subject: subject, Email: email, Name: "Ada",
	}
	return h.svc.CompleteFederatedSignup(context.Background(), auth.CompleteFederatedSignupRequest{
		Provider:           auth.FederatedProviderApple,
		IDToken:            token,
		Nonce:              "n-" + subject,
		AgeConfirmedOver18: true,
	})
}

func TestAccountClaim_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// An account exists, created through the ordinary email-OTP path, which
	// is what writes personal_email today.
	first := h.signUpByEmail(t, "ada@example.com")

	// Apple now presents the SAME address with a capital letter, which is
	// one mailbox and must behave like one. 0017's lower() index is the only
	// reason this is true.
	_, err := appleSignIn(t, h, "apple-token", "apple-sub-1", "Ada@Example.com")
	var claim *auth.AccountClaimRequiredError
	if !errors.As(err, &claim) {
		t.Fatalf("error = %v, want an *AccountClaimRequiredError", err)
	}
	if !errors.Is(err, apperror.ErrConflict) {
		t.Error("the claim error must still classify as ErrConflict")
	}
	if claim.Ticket == "" {
		t.Fatal("no ticket")
	}
	if claim.Email != "ada@example.com" {
		t.Errorf("Email = %q, want the normalised address", claim.Email)
	}

	// No second account, and the row really is the one the unique index
	// protects.
	var users int
	if err := h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 1 {
		t.Fatalf("auth.users rows = %d, want 1 — the colliding signup created an account", users)
	}

	// 0018's enum value: the code row was actually written, under the new
	// purpose. Without the migration the INSERT fails and the claim never
	// gets off the ground.
	var pending int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.verification_codes WHERE purpose = 'account_claim' AND target = $1`,
		"ada@example.com",
	).Scan(&pending); err != nil {
		t.Fatalf("count claim codes: %v", err)
	}
	if pending != 1 {
		t.Errorf("account_claim code rows = %d, want 1", pending)
	}

	code := h.emailer.lastCode()
	if code == "" {
		t.Fatal("no code was mailed")
	}

	session, err := h.svc.CompleteAccountClaim(ctx, auth.CompleteAccountClaimRequest{
		Ticket: claim.Ticket, Code: code,
	})
	if err != nil {
		t.Fatalf("CompleteAccountClaim: %v", err)
	}
	if session.UserID != first.UserID {
		t.Errorf("session is for %q, want the existing account %q", session.UserID, first.UserID)
	}

	// The Apple identity is attached, so the next sign-in resolves straight
	// through rather than asking for a code forever.
	var identities int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.user_identities WHERE provider = 'apple' AND subject = 'apple-sub-1' AND user_id = $1`,
		first.UserID,
	).Scan(&identities); err != nil {
		t.Fatalf("count identities: %v", err)
	}
	if identities != 1 {
		t.Errorf("user_identities rows for the claimed account = %d, want 1", identities)
	}

	// The code is consumed, so the ticket cannot be replayed.
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.verification_codes WHERE purpose = 'account_claim'`).Scan(&pending); err != nil {
		t.Fatalf("recount claim codes: %v", err)
	}
	if pending != 0 {
		t.Errorf("account_claim code rows after a successful claim = %d, want 0", pending)
	}
	if _, err := h.svc.CompleteAccountClaim(ctx, auth.CompleteAccountClaimRequest{
		Ticket: claim.Ticket, Code: code,
	}); err == nil {
		t.Error("the same ticket and code were spent twice")
	}

	// And the second Apple sign-in is now an ordinary login.
	second, err := appleSignIn(t, h, "apple-token-2", "apple-sub-1", "ada@example.com")
	if err != nil {
		t.Fatalf("second Apple sign-in: %v", err)
	}
	if second.UserID != first.UserID || second.IsNewUser {
		t.Errorf("second sign-in: user=%q isNew=%v, want %q and false", second.UserID, second.IsNewUser, first.UserID)
	}
}

// The index is the thing that actually holds the line, not the pre-check.
// This asserts the constraint exists and bites, so that a future migration
// dropping it fails here rather than in production.
func TestPersonalEmailUniqueness_IsEnforcedByTheDatabase_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	h.signUpByEmail(t, "ada@example.com")

	var indexes int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM pg_indexes
		 WHERE schemaname = 'auth' AND tablename = 'users'
		   AND indexname = 'idx_users_personal_email_lower'`).Scan(&indexes); err != nil {
		t.Fatalf("look up the index: %v", err)
	}
	if indexes != 1 {
		t.Fatal("idx_users_personal_email_lower is missing: nothing is enforcing that an email identifies one account")
	}

	// Straight at the table, bypassing every Go-level check, in both cases.
	_, err := h.pool.Exec(ctx,
		`INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18, personal_email)
		 VALUES ('Impostor', 1, true, $1)`, "ada@example.com")
	if err == nil {
		t.Error("an exact duplicate address was accepted")
	}
	_, err = h.pool.Exec(ctx,
		`INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18, personal_email)
		 VALUES ('Impostor', 1, true, $1)`, "ADA@Example.com")
	if err == nil {
		t.Error("a differently-capitalised duplicate was accepted — the index is not on lower()")
	} else if !strings.Contains(err.Error(), "idx_users_personal_email_lower") {
		t.Errorf("rejected, but by something else: %v", err)
	}

	// Two accounts with NO address must still both be allowed: the index is
	// partial for exactly this reason, and CreateUser's NULLIF is what keeps
	// absent addresses out of it.
	for i := 0; i < 2; i++ {
		if _, err := h.pool.Exec(ctx,
			`INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18)
			 VALUES ('Addressless', 1, true)`); err != nil {
			t.Fatalf("an account with no address was refused: %v", err)
		}
	}
}
