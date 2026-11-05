package auth

import (
	"context"
	"crypto/sha256"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
)

// Daily OTP budgets (plan 30B, tracker #106, review N1-A1). Per target and
// purpose, per Asia/Colombo day, counted in Postgres so every instance
// shares them, and not reset by asking for a new code.
//
// Before this, the only limits were per code (five guesses) and per minute
// (one resend): a new code every minute bought five more guesses, about
// 7,200 a day against one passwordless account, and every request sent a
// real e-mail through the daily Gmail quota.
//
// Each caller has their own allowance for a target, so a stranger who knows
// someone's address spends only their own (#133). The higher per-target caps
// still bound brute force across many callers: 50 guesses at a six-digit code
// is a 1 in 20,000 chance a day.
const (
	otpMaxSendsPerDay               = 5
	otpMaxFailedGuessesPerDay       = 10
	otpTargetMaxSendsPerDay         = 20
	otpTargetMaxFailedGuessesPerDay = 50
)

// The refusals say nothing about whether an account exists: the budget is
// keyed by the target typed in, account or not.
var (
	errOTPSendBudget  = fmt.Errorf("too many codes requested for this address today, please try again tomorrow: %w", apperror.ErrRateLimited)
	errOTPGuessBudget = fmt.Errorf("too many attempts for this address today, please try again tomorrow: %w", apperror.ErrRateLimited)
)

// otpBudgetExempt reports whether target is one of the allowlisted test
// targets (TESTING-NOTES.md). They never send real mail or SMS, and the
// test codes must keep working however often they are used, so they never
// touch the budget.
func otpBudgetExempt(purpose repository.VerificationPurpose, target string) bool {
	if purpose == repository.VerificationPurposePhone {
		return testOTPBypassPhones()[target]
	}
	return testOTPBypassEmails()[normalizeBypassEmail(target)]
}

// otpTargetHash is what the budget is keyed by: the normalised target,
// hashed, so the table never holds an address or number.
func otpTargetHash(purpose repository.VerificationPurpose, target string) []byte {
	normalized := identity.NormalizeEmail(target)
	if purpose == repository.VerificationPurposePhone {
		normalized = identity.NormalizePhone(target)
	}
	sum := sha256.Sum256([]byte(normalized))
	return sum[:]
}

// otpRequesterHash is this caller's own allowance for a target. The requester
// is already a hash, so no address is stored.
func otpRequesterHash(ctx context.Context, targetHash []byte) []byte {
	sum := sha256.Sum256(append(append([]byte{}, targetHash...), clientinfo.From(ctx).Requester...))
	return sum[:]
}

// takeOTPSend spends one of the day's sends for target, before the code is
// made. Fails closed: if the budget cannot be read, no code is sent.
func (s *service) takeOTPSend(ctx context.Context, purpose repository.VerificationPurpose, target string) error {
	if s.otpBudgets == nil || otpBudgetExempt(purpose, target) {
		return nil
	}
	hash := otpTargetHash(purpose, target)
	ok, err := s.otpBudgets.TakeSend(ctx, otpRequesterHash(ctx, hash), string(purpose), otpMaxSendsPerDay)
	if err == nil && ok {
		ok, err = s.otpBudgets.TakeSend(ctx, hash, string(purpose), otpTargetMaxSendsPerDay)
	}
	if err != nil {
		s.logger.Error("otp budget unavailable, refusing to send", "purpose", purpose, "error", err)
		return fmt.Errorf("please try again in a moment: %w", apperror.ErrUnavailable)
	}
	if !ok {
		return errOTPSendBudget
	}
	return nil
}

// takeOTPGuess spends one of the day's guesses for target BEFORE the code
// is compared, so parallel guesses cannot overshoot the cap. refund hands
// it back when the guess turns out right: only failures count.
func (s *service) takeOTPGuess(ctx context.Context, purpose repository.VerificationPurpose, target string) (refund func(), err error) {
	if s.otpBudgets == nil || otpBudgetExempt(purpose, target) {
		return func() {}, nil
	}
	hash := otpTargetHash(purpose, target)
	mine := otpRequesterHash(ctx, hash)
	ok, err := s.otpBudgets.TakeGuess(ctx, mine, string(purpose), otpMaxFailedGuessesPerDay)
	if err == nil && ok {
		ok, err = s.otpBudgets.TakeGuess(ctx, hash, string(purpose), otpTargetMaxFailedGuessesPerDay)
	}
	if err != nil {
		s.logger.Error("otp budget unavailable, refusing the attempt", "purpose", purpose, "error", err)
		return nil, fmt.Errorf("please try again in a moment: %w", apperror.ErrUnavailable)
	}
	if !ok {
		return nil, errOTPGuessBudget
	}
	return func() {
		for _, key := range [][]byte{mine, hash} {
			if err := s.otpBudgets.RefundGuess(context.WithoutCancel(ctx), key, string(purpose)); err != nil {
				s.logger.Warn("otp budget: could not hand back a correct guess", "purpose", purpose, "error", err)
			}
		}
	}, nil
}

// SweepOTPBudgets deletes budget days before yesterday.
func (s *service) SweepOTPBudgets(ctx context.Context) (int, error) {
	if s.otpBudgets == nil {
		return 0, nil
	}
	n, err := s.otpBudgets.DeleteOld(ctx)
	return int(n), err
}

// SweepLocationRetention forgets last known locations older than 30 days
// and deletes SOS events older than 90 (plan 30B, 3.3). Both are kept no
// longer than the privacy policy says.
func (s *service) SweepLocationRetention(ctx context.Context) (int, error) {
	if s.retention == nil {
		return 0, nil
	}
	cleared, err := s.retention.ClearStaleLastKnownLocations(ctx)
	if err != nil {
		return 0, err
	}
	deleted, err := s.retention.DeleteOldSOSEvents(ctx)
	return int(cleared + deleted), err
}
