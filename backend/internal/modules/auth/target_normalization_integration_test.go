package auth_test

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Tracker #82, review finding N-A1: one target, one budget.
//
// The OTP attempt budget, the one-minute resend cooldown and the
// per-target rate-limit bucket were all keyed on the raw string the
// caller typed, while login resolves accounts case-insensitively. So
// `Victim@x.com` and `victim@x.com` were the same ACCOUNT but two
// different verification rows — five attempts each, a cooldown each, and
// every code delivered to the same inbox. That is the V-1 attempt-limit
// fix undone by pressing shift.

func TestTargetNormalization_CasingSharesOneCooldown(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: "victim@example.com",
	}); err != nil {
		t.Fatalf("first send: %v", err)
	}

	// Same address, different shift key. Before #82 this was a second
	// row, a fresh cooldown, and a second email to the same person.
	for _, spelling := range []string{
		"Victim@example.com",
		"VICTIM@EXAMPLE.COM",
		"  victim@example.com  ",
	} {
		_, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
			Purpose: auth.VerificationPurposeEmailSignup, Target: spelling,
		})
		if !isSentinel(err, apperror.ErrRateLimited) {
			t.Errorf("resend as %q: error = %v, want ErrRateLimited — "+
				"a second spelling bought a second cooldown and a second email",
				spelling, err)
		}
	}

	// And exactly one row exists for the address, not one per spelling.
	var rows int
	if err := h.pool.QueryRow(ctx, `
		SELECT count(*) FROM auth.verification_codes
		WHERE user_id IS NULL AND purpose = 'email_signup'
		  AND lower(btrim(target)) = 'victim@example.com'`).Scan(&rows); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if rows != 1 {
		t.Errorf("verification_codes rows for the address = %d, want 1", rows)
	}
}

func TestTargetNormalization_CasingSharesOneAttemptBudget(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const address = "budget@example.com"
	if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailSignup, Target: address,
	}); err != nil {
		t.Fatalf("send: %v", err)
	}

	// FIVE wrong guesses, spread over three spellings. That split is the
	// whole point: the cap is five per target, so if each spelling kept
	// its own counter none of them would reach it (two, two and one) and
	// the row would survive. Sharing one counter spends the cap exactly,
	// and the capped row is deleted outright.
	spellings := []string{address, "Budget@example.com", "BUDGET@EXAMPLE.COM"}
	for i := 0; i < 5; i++ {
		if _, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
			Email:              spellings[i%len(spellings)],
			Code:               "000000",
			AgeConfirmedOver18: true,
		}); err == nil {
			t.Fatalf("attempt %d with a wrong code was accepted", i+1)
		}
	}

	var rows int
	if err := h.pool.QueryRow(ctx, `
		SELECT count(*) FROM auth.verification_codes
		WHERE user_id IS NULL AND purpose = 'email_signup'
		  AND lower(btrim(target)) = $1`, address).Scan(&rows); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if rows != 0 {
		t.Errorf("verification_codes rows after five guesses across three spellings = %d, "+
			"want 0 — each spelling kept its own attempt budget, so the cap was never reached",
			rows)
	}

	// The correct code is gone with it: the budget was real, not reset by
	// switching case.
	if _, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
		Email: "Budget@Example.com", Code: "000000", AgeConfirmedOver18: true,
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("after the cap: error = %v, want ErrInvalidInput (no pending code)", err)
	}
}

// The phone half of the same hole: spacing and punctuation.
func TestTargetNormalization_PhoneSpacingSharesOneTarget(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	// Phone verification requires a LinkedIn-linked account.
	session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding: %v", err)
	}
	userID := session.UserID

	if _, err := h.svc.StartPhoneVerification(ctx, auth.StartVerificationRequest{
		UserID: userID, Purpose: auth.VerificationPurposePhone, Target: "+94 77 123 4567",
	}); err != nil {
		t.Fatalf("send: %v", err)
	}

	var stored string
	if err := h.pool.QueryRow(ctx, `
		SELECT target FROM auth.verification_codes WHERE user_id = $1 AND purpose = 'phone'`,
		userID).Scan(&stored); err != nil {
		t.Fatalf("read target: %v", err)
	}
	if stored != "+94771234567" {
		t.Errorf("stored target = %q, want the normalised %q", stored, "+94771234567")
	}
}
