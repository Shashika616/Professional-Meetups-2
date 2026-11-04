package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// StartEmailSignup sends an OTP to email as the first step of the email-OTP
// signup flow. Unauthenticated — there is no user_id yet (the account may
// never even be created, see SignUpOrRecoverWithEmail's recovery path) — so
// this cannot reuse startVerification's userID-keyed Upsert/Get; it uses the
// target-keyed methods instead.
func (s *service) StartEmailSignup(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	req.Target = normalizeVerificationTarget(VerificationPurposeEmailSignup, req.Target)
	if req.Purpose != VerificationPurposeEmailSignup {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartEmailSignup: %w", apperror.ErrInvalidInput)
	}
	return s.startTargetKeyedVerification(ctx, repository.VerificationPurposeEmailSignup, req.Target)
}

// StartEmailLogin sends an OTP to email as the first step of passwordless
// email login — symmetric to StartEmailSignup in shape (target-keyed, no
// user_id yet), but for a return visit rather than account creation.
// Deliberately does NOT check whether email belongs to an existing account
// before sending: doing so would let the Start step itself leak account
// existence, undercutting the same enumeration-safety CompleteEmailLogin's
// generic error message below is for.
func (s *service) StartEmailLogin(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	req.Target = normalizeVerificationTarget(VerificationPurposeEmailLogin, req.Target)
	if req.Purpose != VerificationPurposeEmailLogin {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartEmailLogin: %w", apperror.ErrInvalidInput)
	}
	return s.startTargetKeyedVerification(ctx, repository.VerificationPurposeEmailLogin, req.Target)
}

// startTargetKeyedVerification is the shared body of StartEmailSignup and
// StartEmailLogin — identical in the source too, line for line, minus the
// purpose constant; shared here rather than duplicated so the cooldown and
// expiry rules can't drift between the two.
func (s *service) startTargetKeyedVerification(
	ctx context.Context, purpose repository.VerificationPurpose, target string,
) (StartVerificationResult, error) {
	if target == "" {
		return StartVerificationResult{}, fmt.Errorf("target is required: %w", apperror.ErrInvalidInput)
	}
	// Same shape rule the personal/corporate verification paths apply. These
	// two endpoints are unauthenticated, and until 2026-09-15 they accepted
	// any non-empty string, stored it, and asked Gmail to deliver to it.
	if err := validateEmailShape(target); err != nil {
		return StartVerificationResult{}, err
	}

	existing, err := s.verificationCodes.GetByTarget(ctx, purpose, target)
	if err == nil {
		if age := time.Since(existing.CreatedAt); age < otpResendCooldown {
			return StartVerificationResult{}, fmt.Errorf("please wait before requesting another code: %w", apperror.ErrRateLimited)
		}
	} else if !errors.Is(err, apperror.ErrNotFound) {
		return StartVerificationResult{}, err
	}
	if err := s.takeOTPSend(ctx, purpose, target); err != nil {
		return StartVerificationResult{}, err
	}

	code, err := generateOTP()
	if err != nil {
		return StartVerificationResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.verificationCodes.UpsertForSignup(ctx, purpose, target, hashOTP(code), time.Now().Add(otpExpiry)); err != nil {
		return StartVerificationResult{}, err
	}

	// The signup/login twin of the skip in dispatchVerificationCode: an
	// allowlisted test address (TEST_OTP_BYPASS_EMAILS) gets no real send.
	// This site is separate from that one because these two purposes are
	// target-keyed rather than user-keyed — there is no user row yet at
	// signup — so they never reach that switch. Both sites are needed; a
	// skip in only one leaves the other mailing reserved .test domains.
	if testOTPBypassEmails()[normalizeBypassEmail(target)] {
		s.logger.Warn(testEmailBypassSkipLogMsg, "purpose", purpose, "target", target, "code", code)
		return StartVerificationResult{ResendAfterSeconds: int32(otpResendCooldown.Seconds())}, nil
	}

	if err := s.email.SendVerificationCode(ctx, target, code, email.PurposePersonalEmail); err != nil {
		s.logger.Error("verification code dispatch failed", "purpose", purpose, "error", err)
		return StartVerificationResult{}, fmt.Errorf("failed to send verification code, please try again: %w", apperror.ErrInternal)
	}

	return StartVerificationResult{ResendAfterSeconds: int32(otpResendCooldown.Seconds())}, nil
}

// CompleteEmailSignup verifies the OTP sent by StartEmailSignup, then calls
// SignUpOrRecoverWithEmail — which may create a new Level 0 user or recover
// an existing one. No password anywhere: proving inbox control via OTP is
// the entire credential, at signup and on every later login.
func (s *service) CompleteEmailSignup(ctx context.Context, req CompleteEmailSignupRequest) (SessionResult, error) {
	req.Email = normalizeVerificationTarget(VerificationPurposeEmailSignup, req.Email)
	if err := s.verifyAndConsumeTargetKeyedCode(ctx, repository.VerificationPurposeEmailSignup, req.Email, req.Code); err != nil {
		return SessionResult{}, err
	}

	user, isNewUser, err := s.SignUpOrRecoverWithEmail(ctx, req.Email, req.AgeConfirmedOver18)
	if err != nil {
		return SessionResult{}, err
	}

	return s.finishSignupSession(ctx, user, isNewUser)
}

// CompleteEmailLogin verifies the OTP sent by StartEmailLogin against an
// ALREADY-existing account and, on success, issues a session. Returns the
// same generic "invalid email or code" error whether the account doesn't
// exist or the code is wrong — an account-enumeration-safe pattern. The OTP
// check runs unconditionally, whether or not the account exists, so a
// wrong-code attempt against a real account and any attempt against a
// nonexistent one cost the same.
func (s *service) CompleteEmailLogin(ctx context.Context, req VerifyCodeRequest) (SessionResult, error) {
	req.Target = normalizeVerificationTarget(VerificationPurposeEmailLogin, req.Target)
	if req.Purpose != VerificationPurposeEmailLogin {
		return SessionResult{}, fmt.Errorf("purpose mismatch for CompleteEmailLogin: %w", apperror.ErrInvalidInput)
	}

	codeErr := s.verifyAndConsumeTargetKeyedCode(ctx, repository.VerificationPurposeEmailLogin, req.Target, req.Code)
	// The daily budget's refusal is keyed by the address typed, account or
	// not, so saying so reveals nothing; and the person needs to know that
	// another code today will not help.
	if errors.Is(codeErr, errOTPGuessBudget) || errors.Is(codeErr, apperror.ErrUnavailable) {
		return SessionResult{}, codeErr
	}
	user, userErr := s.users.GetByPersonalEmail(ctx, req.Target)
	if codeErr != nil || userErr != nil {
		return SessionResult{}, fmt.Errorf("invalid email or code: %w", apperror.ErrUnauthorized)
	}

	return s.issueSession(ctx, user)
}

// verifyAndConsumeTargetKeyedCode mirrors verifyAndConsumeCode exactly,
// except keyed by (purpose, target) instead of (userID, purpose) — and is
// shared by both target-keyed purposes rather than duplicated per purpose.
// Unlike verifyAndConsumeCode there's no separate "target matches" check:
// GetByTarget already looks the row up BY target, so a mismatch can't occur
// here the way it can for the userID-keyed methods.
// Spends the attempt atomically before comparing, for the same reason and in
// the same order as verifyAndConsumeCode — see its comment for the full
// reasoning on V-1.
//
// This is the half that mattered most. Every purpose routed through here is
// UNAUTHENTICATED (email signup, email login, and account_claim as of
// ADR-009), so the cap below is the only thing standing between a stranger
// and a six-digit secret. Before this change a hundred parallel guesses got
// a hundred turns.
//
// No separate "target matches" check, for the same reason as before: the
// claim is keyed BY target, so a mismatch cannot occur here the way it can
// for the user-keyed twin.
func (s *service) verifyAndConsumeTargetKeyedCode(ctx context.Context, purpose repository.VerificationPurpose, target, code string) error {
	refund, err := s.takeOTPGuess(ctx, purpose, target)
	if err != nil {
		return err
	}
	if err := s.claimAndConsumeTargetKeyedCode(ctx, purpose, target, code); err != nil {
		return err
	}
	refund()
	return nil
}

// claimAndConsumeTargetKeyedCode is the per-code half of
// verifyAndConsumeTargetKeyedCode: the five-attempt cap on this code, then
// the comparison.
func (s *service) claimAndConsumeTargetKeyedCode(ctx context.Context, purpose repository.VerificationPurpose, target, code string) error {
	claimed, err := s.verificationCodes.ClaimAttemptByTarget(ctx, purpose, target, otpMaxAttempts)
	if err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return s.explainUnclaimableTargetKeyedAttempt(ctx, purpose, target)
		}
		return err
	}

	if !otpMatches(claimed.CodeHash, code, purpose, target) {
		if claimed.Attempts >= otpMaxAttempts {
			_ = s.verificationCodes.DeleteByTarget(ctx, purpose, target)
		}
		return fmt.Errorf("invalid code: %w", apperror.ErrInvalidInput)
	}

	if err := s.verificationCodes.ConsumeByTarget(ctx, purpose, target, claimed.CodeHash); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return fmt.Errorf("invalid code: %w", apperror.ErrInvalidInput)
		}
		return err
	}
	return nil
}

// explainUnclaimableTargetKeyedAttempt is explainUnclaimableAttempt for the
// target-keyed purposes; see that function for why the spent-cap case
// deliberately does not delete the row.
func (s *service) explainUnclaimableTargetKeyedAttempt(
	ctx context.Context, purpose repository.VerificationPurpose, target string,
) error {
	pending, err := s.verificationCodes.GetByTarget(ctx, purpose, target)
	if err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return fmt.Errorf("no pending verification code, please request a new one: %w", apperror.ErrInvalidInput)
		}
		return err
	}
	if time.Now().After(pending.ExpiresAt) {
		_ = s.verificationCodes.DeleteByTarget(ctx, purpose, target)
		return fmt.Errorf("code expired, please request a new one: %w", apperror.ErrInvalidInput)
	}
	return fmt.Errorf("too many attempts, please request a new code: %w", apperror.ErrInvalidInput)
}
