package auth_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// V-1: the five-attempt cap has to bound GUESSES, not turns.
//
// These must run against real Postgres, because the thing being tested is
// whether the database serialises the attempt increment. A fake that holds a
// mutex for the whole operation would pass no matter which order the service
// does things in, which is exactly the bug that shipped.
//
// maxAttempts is otpMaxAttempts in the service. Hard-coded here rather than
// exported, so a change to the cap fails these loudly instead of silently
// widening what they allow.
const maxAttempts = 5

// phoneVerificationFixture gives back a user id and the two calls, for the
// user-keyed half of the fix. Phone is used because its errors reach the
// caller unchanged — CompleteEmailLogin deliberately collapses every reason
// into one generic sentence, which would hide the very distinction these
// tests measure.
func phoneVerificationFixture(t *testing.T, h *harness) (start func(), verify func(string) error) {
	t.Helper()
	ctx := context.Background()

	// A LinkedIn-backed account: phone verification requires it
	// (requireLinkedIn, ADR-014 §4), same as TestOTP_ExpiryAttemptCapAndConsumption.
	session, err := h.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "code", RedirectURI: "app://cb", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding: %v", err)
	}

	const number = "+94771234567"
	start = func() {
		t.Helper()
		if _, err := h.svc.StartPhoneVerification(ctx, auth.StartVerificationRequest{
			UserID: session.UserID, Purpose: auth.VerificationPurposePhone, Target: number,
		}); err != nil {
			t.Fatalf("StartPhoneVerification: %v", err)
		}
	}
	verify = func(code string) error {
		_, err := h.svc.VerifyPhoneCode(ctx, auth.VerifyCodeRequest{
			UserID: session.UserID, Purpose: auth.VerificationPurposePhone,
			Target: number, Code: code,
		})
		return err
	}
	return start, verify
}

// run calls fn n times in parallel, releasing all of them at once, and
// returns every error. The shared start gate matters: staggered calls would
// serialise themselves and the old code would pass.
func inParallel(n int, fn func() error) []error {
	var (
		gate sync.WaitGroup
		done sync.WaitGroup
		mu   sync.Mutex
		errs []error
	)
	gate.Add(1)
	for i := 0; i < n; i++ {
		done.Add(1)
		go func() {
			defer done.Done()
			gate.Wait()
			err := fn()
			mu.Lock()
			defer mu.Unlock()
			errs = append(errs, err)
		}()
	}
	gate.Done()
	done.Wait()
	return errs
}

func TestOTPAttemptCap_ParallelWrongGuesses_Integration(t *testing.T) {
	h := newHarness(t)
	start, verify := phoneVerificationFixture(t, h)
	start()

	const guesses = 50
	errs := inParallel(guesses, func() error { return verify("000000") })

	// Every single one must be rejected.
	for _, err := range errs {
		if err == nil {
			t.Fatal("a wrong code was accepted")
		}
	}

	// THE ASSERTION THAT FAILS ON THE OLD CODE. "invalid code" is only
	// returned by the branch that actually compared the code, so counting it
	// counts comparisons. The old flow let all fifty through (every one read
	// attempts = 0 before any increment landed); the fix caps it at five,
	// and the other forty-five are turned away before the compare with
	// "too many attempts" or "no pending verification code".
	compared := 0
	for _, err := range errs {
		if strings.Contains(err.Error(), "invalid code") {
			compared++
		}
	}
	if compared > maxAttempts {
		t.Errorf("%d of %d parallel guesses were actually compared, want at most %d — the attempt cap is not atomic",
			compared, guesses, maxAttempts)
	}
	if compared == 0 {
		t.Error("no guess was compared at all, so this test is not exercising the compare path")
	}
}

// The other half of V-1: one correct code must be spendable ONCE, even when
// several requests present it at the same instant. The old success path was
// an unconditional DELETE whose result nobody read, so every caller holding
// the same correct code was told it worked.
//
// Deliberately on the EMAIL LOGIN path rather than phone verification. Phone
// verification writes the user row as part of succeeding, so concurrent
// calls serialise on that row and the second one fails for reasons that have
// nothing to do with the code — which makes "exactly one succeeded" true even
// when the code was consumed twice. (Checked: this test passes against a
// deliberately broken consume when written against phone.) Email login's
// only gate is the code, so the count means what it says. It is also the
// unauthenticated path, which is the one that matters.
func TestOTPAttemptCap_ParallelCorrectSubmissions_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const address = "single.use@example.com"
	h.signUpByEmail(t, address)

	if _, err := h.svc.StartEmailLogin(ctx, auth.StartVerificationRequest{
		Purpose: auth.VerificationPurposeEmailLogin, Target: address,
	}); err != nil {
		t.Fatalf("StartEmailLogin: %v", err)
	}
	code := h.emailer.lastCode()
	if code == "" {
		t.Fatal("no code was sent")
	}

	const callers = 4
	errs := inParallel(callers, func() error {
		_, err := h.svc.CompleteEmailLogin(ctx, auth.VerifyCodeRequest{
			Purpose: auth.VerificationPurposeEmailLogin, Target: address, Code: code,
		})
		return err
	})

	succeeded := 0
	for _, err := range errs {
		if err == nil {
			succeeded++
		}
	}
	if succeeded != 1 {
		t.Errorf("%d of %d simultaneous correct submissions succeeded, want exactly 1 — one code was spent more than once",
			succeeded, callers)
	}
}

// Many parallel guesses must not be able to outlast the cap and then land a
// correct one. This is the actual attack: spray guesses, and if the cap is
// not enforced per guess, keep going until one hits.
func TestOTPAttemptCap_CorrectCodeAfterTheCapIsSpent_Integration(t *testing.T) {
	h := newHarness(t)
	start, verify := phoneVerificationFixture(t, h)
	start()

	code := h.smser.lastCode()
	inParallel(20, func() error { return verify("000000") })

	if err := verify(code); err == nil {
		t.Error("the correct code was still accepted after 20 parallel wrong guesses, want the cap to have closed it")
	}
}

// The two mechanisms, pinned deterministically against real Postgres.
//
// WHY THIS EXISTS ALONGSIDE THE PARALLEL TESTS ABOVE. "Two correct
// submissions, one success" is genuinely hard to assert from the outside:
// the moment the winner's DELETE commits, every later caller fails at the
// CLAIM instead of at the consume, so the window in which the unchecked
// delete was observable is microseconds wide and a parallel test passes
// against the bug by luck. Measured: a deliberately broken consume survives
// the parallel test. It does not survive this one.
//
// Driving the repository directly is the point — these are the two
// guarantees the SQL makes, stated without a service in the way.
func TestVerificationCodeRepository_ClaimAndConsumeSemantics_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	codes := repository.NewVerificationCodeRepository(h.pool)

	const (
		purpose = repository.VerificationPurposeEmailLogin
		target  = "semantics@example.com"
		hash    = "hash-of-the-right-code"
	)
	if _, err := codes.UpsertForSignup(ctx, purpose, target, hash, time.Now().Add(10*time.Minute)); err != nil {
		t.Fatalf("seed the code row: %v", err)
	}

	t.Run("the cap is exact: maxAttempts claims succeed and the next does not", func(t *testing.T) {
		for i := 1; i <= maxAttempts; i++ {
			row, err := codes.ClaimAttemptByTarget(ctx, purpose, target, maxAttempts)
			if err != nil {
				t.Fatalf("claim %d of %d failed: %v", i, maxAttempts, err)
			}
			if row.Attempts != i {
				t.Errorf("claim %d returned attempts = %d, want %d", i, row.Attempts, i)
			}
		}
		if _, err := codes.ClaimAttemptByTarget(ctx, purpose, target, maxAttempts); !errors.Is(err, apperror.ErrNotFound) {
			t.Errorf("claim %d returned %v, want ErrNotFound — the cap is not enforced by the UPDATE",
				maxAttempts+1, err)
		}
	})

	t.Run("consume is single use", func(t *testing.T) {
		if err := codes.ConsumeByTarget(ctx, purpose, target, hash); err != nil {
			t.Fatalf("first consume: %v", err)
		}
		// THE ASSERTION A BROKEN CONSUME CANNOT PASS.
		if err := codes.ConsumeByTarget(ctx, purpose, target, hash); !errors.Is(err, apperror.ErrNotFound) {
			t.Errorf("second consume returned %v, want ErrNotFound — a spent code is still spendable", err)
		}
	})

	t.Run("consume refuses a hash that does not match the stored row", func(t *testing.T) {
		if _, err := codes.UpsertForSignup(ctx, purpose, target, hash, time.Now().Add(10*time.Minute)); err != nil {
			t.Fatalf("re-seed: %v", err)
		}
		if err := codes.ConsumeByTarget(ctx, purpose, target, "hash-of-a-different-code"); !errors.Is(err, apperror.ErrNotFound) {
			t.Errorf("consume with a wrong hash returned %v, want ErrNotFound", err)
		}
		// ...and the row is still there for the rightful caller.
		if err := codes.ConsumeByTarget(ctx, purpose, target, hash); err != nil {
			t.Errorf("the correct hash was refused after a wrong one: %v", err)
		}
	})

	t.Run("an expired row cannot be claimed at all", func(t *testing.T) {
		const expiredTarget = "expired@example.com"
		if _, err := codes.UpsertForSignup(ctx, purpose, expiredTarget, hash, time.Now().Add(-time.Second)); err != nil {
			t.Fatalf("seed an expired row: %v", err)
		}
		if _, err := codes.ClaimAttemptByTarget(ctx, purpose, expiredTarget, maxAttempts); !errors.Is(err, apperror.ErrNotFound) {
			t.Errorf("claim on an expired row returned %v, want ErrNotFound", err)
		}
	})
}

// TEST FIXTURES MUST KEEP WORKING (TESTING-NOTES.md).
//
// `TEST_OTP_BYPASS_EMAILS` and the seeded `@meetups.test` accounts are how
// the trust ladder gets exercised by hand, and the V-1 rework moved the code
// comparison to a different point in the flow. otpMatches — which is where
// the allowlist lives — is now called on the row returned by the atomic
// claim rather than on an unlocked read, so this pins that `123456` still
// works for an allowlisted address, and still does not for anything else.
//
// Deliberately asserts the NEGATIVE too. An allowlist that quietly started
// matching everything would look identical from the positive case alone, and
// that would be an open door on every account with a personal email.
func TestTestOTPBypassEmails_StillWorkThroughTheReworkedPath_Integration(t *testing.T) {
	const bypassAddress = "l2.a@meetups.test"
	const ordinaryAddress = "not.allowlisted@example.com"

	// Exactly the shape service.yaml uses: a comma-separated allowlist.
	t.Setenv("TEST_OTP_BYPASS_EMAILS", bypassAddress+",l3.a@meetups.test")

	h := newHarness(t)
	ctx := context.Background()

	// Separated, because the resend cooldown is one minute: a subtest that
	// needs two guesses at one address has to Start once and Complete twice.
	start := func(t *testing.T, address string) {
		t.Helper()
		if _, err := h.svc.StartEmailSignup(ctx, auth.StartVerificationRequest{
			Purpose: auth.VerificationPurposeEmailSignup, Target: address,
		}); err != nil {
			t.Fatalf("StartEmailSignup(%s): %v", address, err)
		}
	}
	complete := func(address, code string) error {
		_, err := h.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
			Email: address, Code: code, AgeConfirmedOver18: true,
		})
		return err
	}

	t.Run("an allowlisted address still verifies with 123456", func(t *testing.T) {
		start(t, bypassAddress)
		if err := complete(bypassAddress, "123456"); err != nil {
			t.Fatalf("the fixed code was refused for an allowlisted address: %v", err)
		}
	})

	t.Run("a non-allowlisted address does not", func(t *testing.T) {
		start(t, ordinaryAddress)
		realCode := h.emailer.lastCode()
		if realCode == "" {
			t.Fatal("no real code was sent to the non-allowlisted address")
		}

		if err := complete(ordinaryAddress, "123456"); err == nil {
			t.Fatal("123456 was accepted for an address that is not on the allowlist")
		}

		// And the real code still works, on the same code row, so the
		// allowlist has not broken ordinary verification and the wrong guess
		// above spent an attempt rather than the whole code.
		if err := complete(ordinaryAddress, realCode); err != nil {
			t.Fatalf("the real code was refused: %v", err)
		}
	})

	t.Run("the allowlist does not cover account_claim", func(t *testing.T) {
		// TESTING-NOTES.md records this explicitly: isEmailOTPPurpose is an
		// explicit list and account_claim is not on it, so a claim still
		// needs the real code. Pinned here so the V-1 rework cannot have
		// quietly widened it.
		if _, err := h.svc.CompleteAccountClaim(ctx, auth.CompleteAccountClaimRequest{
			Ticket: "not-a-real-ticket", Code: "123456",
		}); err == nil {
			t.Error("123456 completed a claim with an unsigned ticket")
		}
	})
}
