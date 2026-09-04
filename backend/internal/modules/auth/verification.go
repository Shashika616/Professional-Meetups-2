package auth

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Server-side max lengths for free-text fields that are only ever checked
// for emptiness otherwise. The backing columns are plain TEXT with no length
// constraint, and the gateway decodes request bodies with only a 1 MiB
// blanket cap — without a bound here a caller could persist an arbitrarily
// large value against these columns. Generous enough for any real
// name/address/company name, not a tight UX-driven limit (that already
// exists client-side).
const (
	maxFullNameLength    = 200
	maxLegalNameLength   = 200
	maxAddressLength     = 500
	maxCompanyNameLength = 200
)

// requireLinkedIn rejects a caller who hasn't linked LinkedIn yet — LinkedIn
// is a hard prerequisite for Level 2+, not just one signal among several, so
// every method that would advance a user toward Level 2/3 checks this
// explicitly rather than relying on computeTrustLevel's passive "stays at
// 0/1" behavior alone. A clear, specific rejection here beats letting a
// phone/email OTP go out (a real cost via Twilio/Resend) for a verification
// that can never actually raise the caller's trust level.
func (s *service) requireLinkedIn(ctx context.Context, userID string) (repository.User, error) {
	user, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return repository.User{}, err
	}
	if user.LinkedInSub == "" {
		return repository.User{}, fmt.Errorf("connect LinkedIn before verifying phone, email, or personal details: %w", apperror.ErrForbidden)
	}
	return user, nil
}

// StartPhoneVerification generates and sends a phone OTP.
func (s *service) StartPhoneVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	if req.Purpose != VerificationPurposePhone {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartPhoneVerification: %w", apperror.ErrInvalidInput)
	}
	// Format check: an addition over the source, which only checked
	// non-emptiness server-side and left the shape rule to the Flutter
	// client. See validate.go.
	if err := validatePhoneNumber(req.Target); err != nil {
		return StartVerificationResult{}, err
	}
	if _, err := s.requireLinkedIn(ctx, req.UserID); err != nil {
		return StartVerificationResult{}, err
	}
	return s.startVerification(ctx, req.UserID, repository.VerificationPurposePhone, req.Target)
}

// VerifyPhoneCode verifies a phone OTP and, on success, persists
// phone_number and returns a fresh session reflecting the new trust level.
func (s *service) VerifyPhoneCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error) {
	if req.Purpose != VerificationPurposePhone {
		return SessionResult{}, fmt.Errorf("purpose mismatch for VerifyPhoneCode: %w", apperror.ErrInvalidInput)
	}
	if err := s.verifyAndConsumeCode(ctx, req.UserID, repository.VerificationPurposePhone, req.Target, req.Code); err != nil {
		return SessionResult{}, err
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return SessionResult{}, err
	}
	hypothetical := user
	hypothetical.PhoneNumber = req.Target

	persisted, err := s.users.UpdatePhoneNumber(ctx, req.UserID, req.Target, computeTrustLevel(hypothetical))
	if err != nil {
		return SessionResult{}, err
	}
	return s.issueSession(ctx, persisted)
}

// StartPersonalEmailVerification generates and sends a personal-email OTP.
func (s *service) StartPersonalEmailVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	if req.Purpose != VerificationPurposePersonalEmail {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartPersonalEmailVerification: %w", apperror.ErrInvalidInput)
	}
	if err := validateEmailShape(req.Target); err != nil {
		return StartVerificationResult{}, err
	}
	if _, err := s.requireLinkedIn(ctx, req.UserID); err != nil {
		return StartVerificationResult{}, err
	}
	return s.startVerification(ctx, req.UserID, repository.VerificationPurposePersonalEmail, req.Target)
}

// VerifyPersonalEmailCode verifies a personal-email OTP and, on success,
// persists personal_email and returns a fresh session.
func (s *service) VerifyPersonalEmailCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error) {
	if req.Purpose != VerificationPurposePersonalEmail {
		return SessionResult{}, fmt.Errorf("purpose mismatch for VerifyPersonalEmailCode: %w", apperror.ErrInvalidInput)
	}
	if err := s.verifyAndConsumeCode(ctx, req.UserID, repository.VerificationPurposePersonalEmail, req.Target, req.Code); err != nil {
		return SessionResult{}, err
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return SessionResult{}, err
	}
	hypothetical := user
	hypothetical.PersonalEmail = req.Target

	persisted, err := s.users.UpdatePersonalEmail(ctx, req.UserID, req.Target, computeTrustLevel(hypothetical))
	if err != nil {
		return SessionResult{}, err
	}
	return s.issueSession(ctx, persisted)
}

// SubmitPersonalDetails is the one Level 2 step with no OTP — legal name and
// address are self-reported. Address is accepted-if-sent but not required;
// only legal name is.
func (s *service) SubmitPersonalDetails(ctx context.Context, req SubmitPersonalDetailsRequest) (SessionResult, error) {
	if req.LegalName == "" {
		return SessionResult{}, fmt.Errorf("legal name is required: %w", apperror.ErrInvalidInput)
	}
	if len(req.LegalName) > maxLegalNameLength {
		return SessionResult{}, fmt.Errorf("legal name is too long: %w", apperror.ErrInvalidInput)
	}
	if len(req.Address) > maxAddressLength {
		return SessionResult{}, fmt.Errorf("address is too long: %w", apperror.ErrInvalidInput)
	}

	user, err := s.requireLinkedIn(ctx, req.UserID)
	if err != nil {
		return SessionResult{}, err
	}
	hypothetical := user
	hypothetical.LegalName = req.LegalName
	hypothetical.Address = req.Address

	persisted, err := s.users.UpdatePersonalDetails(ctx, req.UserID, req.LegalName, req.Address, computeTrustLevel(hypothetical))
	if err != nil {
		return SessionResult{}, err
	}
	return s.issueSession(ctx, persisted)
}

// StartCorporateEmailVerification rejects free/role-based addresses before a
// code is ever generated, then generates and sends a corporate-email OTP.
// Unlike the phone/personal-email starts, this does NOT call requireLinkedIn:
// company email verification is reachable from the mandatory post-auth
// profile-setup screen, potentially at Level 0, before LinkedIn is ever
// connected. The Profile-page-reachable path this also serves is unaffected
// — a Level 2+ caller there already has LinkedIn by definition.
func (s *service) StartCorporateEmailVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	if req.Purpose != VerificationPurposeCorporateEmail {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartCorporateEmailVerification: %w", apperror.ErrInvalidInput)
	}
	// Safe to be specific here (unlike the enumeration-sensitive cases
	// elsewhere) — this only reveals something about the domain the user
	// themselves just typed, not about any account's existence. Runs before
	// the generic shape check so a malformed address keeps the source's own
	// wording rather than gaining a new message.
	if isRejectedCorporateEmail(req.Target) {
		return StartVerificationResult{}, fmt.Errorf("please use your work email, not a personal address: %w", apperror.ErrInvalidInput)
	}
	if err := validateEmailShape(req.Target); err != nil {
		return StartVerificationResult{}, err
	}
	return s.startVerification(ctx, req.UserID, repository.VerificationPurposeCorporateEmail, req.Target)
}

// errReputationalRisk/errCompanyDomainMismatch are the two specific
// rejection messages VerifyCorporateEmailCode's branches share — kept as
// vars so the branches and their tests reference the exact same wording, not
// near-duplicates that could drift.
var (
	errReputationalRisk = fmt.Errorf(
		"this work email has already been used to verify a different account, which harms this company's standing on the platform: %w", apperror.ErrConflict)
	errCompanyDomainMismatch = fmt.Errorf(
		"the email domain does not match the company name entered — please check both and try again: %w", apperror.ErrInvalidInput)
)

// VerifyCorporateEmailCode verifies a corporate-email OTP and, on success,
// extracts+persists company_domain (never the raw address), marks
// work_email_verified, and returns a fresh session. Two checks run beyond
// the OTP itself, both after the code checks out but before anything is
// persisted:
//
//  1. Reuse-abuse: a keyed HMAC of the normalized raw address (hashWorkEmail)
//     is looked up via GetByWorkEmailHash. A match on a DIFFERENT user is
//     rejected (errReputationalRisk) — the same mailbox can't verify two
//     accounts. A match on the SAME user (re-verifying) is not an error; the
//     flow just proceeds.
//  2. Company name-vs-domain cross-check against known_companies,
//     normalized-name-keyed: a known company with a non-matching domain is
//     rejected (errCompanyDomainMismatch, the lookalike-domain case); an
//     unknown company proceeds exactly as before (accept, extract+store the
//     domain) but is additionally flagged into unverified_company_claims for
//     manual review.
func (s *service) VerifyCorporateEmailCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error) {
	if req.Purpose != VerificationPurposeCorporateEmail {
		return SessionResult{}, fmt.Errorf("purpose mismatch for VerifyCorporateEmailCode: %w", apperror.ErrInvalidInput)
	}
	companyName := strings.TrimSpace(req.CompanyName)
	if companyName == "" {
		return SessionResult{}, fmt.Errorf("company name is required: %w", apperror.ErrInvalidInput)
	}
	if len(companyName) > maxCompanyNameLength {
		return SessionResult{}, fmt.Errorf("company name is too long: %w", apperror.ErrInvalidInput)
	}
	if err := s.verifyAndConsumeCode(ctx, req.UserID, repository.VerificationPurposeCorporateEmail, req.Target, req.Code); err != nil {
		return SessionResult{}, err
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return SessionResult{}, err
	}

	workEmailHash := hashWorkEmail(s.workEmailHMACKey, req.Target)
	if holder, err := s.users.GetByWorkEmailHash(ctx, workEmailHash); err == nil && holder.ID != user.ID {
		return SessionResult{}, errReputationalRisk
	} else if err != nil && !errors.Is(err, apperror.ErrNotFound) {
		return SessionResult{}, err
	}

	domain := domainFromEmail(req.Target)
	normalizedName := normalizeCompanyName(companyName)
	known, err := s.knownCompanies.GetByNameNormalized(ctx, normalizedName)
	switch {
	case err == nil:
		if !slices.Contains(known.Domains, domain) {
			return SessionResult{}, errCompanyDomainMismatch
		}
	case errors.Is(err, apperror.ErrNotFound):
		if err := s.unverifiedCompanyClaims.Insert(ctx, repository.UnverifiedCompanyClaim{
			UserID:             user.ID,
			CompanyNameEntered: companyName,
			Domain:             domain,
		}); err != nil {
			return SessionResult{}, err
		}
	default:
		return SessionResult{}, err
	}

	hypothetical := user
	hypothetical.CompanyDomain = domain
	hypothetical.WorkEmailVerified = true

	persisted, err := s.users.UpdateWorkEmailVerified(ctx, req.UserID, domain, true, time.Now(), workEmailHash, computeTrustLevel(hypothetical))
	if err != nil {
		return SessionResult{}, err
	}
	return s.issueSession(ctx, persisted)
}

// GetProfile returns everything the profile screen needs to render real
// verification state, plus four raw PII fields about the caller's OWN
// account. userID here is set by the gateway from the verified JWT, never
// client-supplied, which is what makes returning those raw fields safe: this
// method cannot be used to read anyone else's data.
func (s *service) GetProfile(ctx context.Context, userID string) (Profile, error) {
	user, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return Profile{}, err
	}
	return profileFromUser(user), nil
}

// profileFromUser's four raw fields (PhoneNumber/PersonalEmail/LegalName/
// Address) are the account owner's own data: both GetProfile and
// CompleteProfileSetup return this to the owner only — no other method and
// no other user ever sees these values. Work email has no raw field here and
// never will: it is never stored past the verification round-trip at all,
// which is a stronger rule than "not returned".
func profileFromUser(user repository.User) Profile {
	return Profile{
		UserID:                  user.ID,
		FullName:                user.FullName,
		ProfilePhotoURL:         user.ProfilePhotoURL,
		TrustLevel:              user.TrustLevel,
		PhoneVerified:           user.PhoneNumber != "",
		PersonalEmailVerified:   user.PersonalEmail != "",
		PersonalDetailsComplete: user.LegalName != "",
		CompanyDomain:           user.CompanyDomain,
		WorkEmailVerified:       user.WorkEmailVerified,
		RatingAverage:           user.RatingAverage,
		RatingCount:             user.RatingCount,
		PhoneNumber:             user.PhoneNumber,
		PersonalEmail:           user.PersonalEmail,
		LegalName:               user.LegalName,
		Address:                 user.Address,
	}
}

// CompleteProfileSetup backs the mandatory post-auth screen, called once by
// every one of the four sign-up/login paths right after auth succeeds.
// full_name is always required — the caller (gateway) sets user_id from the
// verified JWT. company_name/company_email are optional as a pair: if
// company_email is set, this kicks off the same corporate-email
// verification-start flow StartCorporateEmailVerification itself uses (a
// fresh OTP is sent) rather than duplicating that logic. It does NOT itself
// mark work email verified; the frontend's own "Verify" sub-step completes
// that via VerifyCorporateEmailCode.
func (s *service) CompleteProfileSetup(ctx context.Context, req CompleteProfileSetupRequest) (Profile, error) {
	fullName := strings.TrimSpace(req.FullName)
	if fullName == "" {
		return Profile{}, fmt.Errorf("full name is required: %w", apperror.ErrInvalidInput)
	}
	if len(fullName) > maxFullNameLength {
		return Profile{}, fmt.Errorf("full name is too long: %w", apperror.ErrInvalidInput)
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return Profile{}, err
	}

	if user.FullName != fullName {
		user, err = s.users.UpdateFullName(ctx, req.UserID, fullName)
		if err != nil {
			return Profile{}, err
		}
	}

	if companyEmail := req.CompanyEmail; companyEmail != "" {
		companyName := strings.TrimSpace(req.CompanyName)
		if companyName == "" {
			return Profile{}, fmt.Errorf("company name is required alongside a company email: %w", apperror.ErrInvalidInput)
		}
		if len(companyName) > maxCompanyNameLength {
			return Profile{}, fmt.Errorf("company name is too long: %w", apperror.ErrInvalidInput)
		}
		if _, err := s.StartCorporateEmailVerification(ctx, StartVerificationRequest{
			UserID:  req.UserID,
			Purpose: VerificationPurposeCorporateEmail,
			Target:  companyEmail,
		}); err != nil {
			return Profile{}, err
		}
	}

	return profileFromUser(user), nil
}

// startVerification is the shared Start* implementation for the three
// userID-keyed purposes — one send mechanism, not three.
func (s *service) startVerification(
	ctx context.Context, userID string, purpose repository.VerificationPurpose, target string,
) (StartVerificationResult, error) {
	if target == "" {
		return StartVerificationResult{}, fmt.Errorf("target is required: %w", apperror.ErrInvalidInput)
	}

	existing, err := s.verificationCodes.Get(ctx, userID, purpose)
	if err == nil {
		if age := time.Since(existing.CreatedAt); age < otpResendCooldown {
			return StartVerificationResult{}, fmt.Errorf("please wait before requesting another code: %w", apperror.ErrRateLimited)
		}
	} else if !errors.Is(err, apperror.ErrNotFound) {
		return StartVerificationResult{}, err
	}

	code, err := generateOTP()
	if err != nil {
		return StartVerificationResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.verificationCodes.Upsert(ctx, userID, purpose, target, hashOTP(code), time.Now().Add(otpExpiry)); err != nil {
		return StartVerificationResult{}, err
	}

	if err := s.dispatchVerificationCode(ctx, purpose, target, code); err != nil {
		s.logger.Error("verification code dispatch failed", "purpose", purpose, "error", err)
		return StartVerificationResult{}, fmt.Errorf("failed to send verification code, please try again: %w", apperror.ErrInternal)
	}

	return StartVerificationResult{ResendAfterSeconds: int32(otpResendCooldown.Seconds())}, nil
}

func (s *service) dispatchVerificationCode(ctx context.Context, purpose repository.VerificationPurpose, target, code string) error {
	switch purpose {
	case repository.VerificationPurposePhone:
		return s.sms.SendVerificationCode(ctx, target, code)
	case repository.VerificationPurposePersonalEmail:
		return s.email.SendVerificationCode(ctx, target, code, email.PurposePersonalEmail)
	case repository.VerificationPurposeCorporateEmail:
		return s.email.SendVerificationCode(ctx, target, code, email.PurposeCorporateEmail)
	default:
		return fmt.Errorf("auth: unknown verification purpose %q", purpose)
	}
}

// verifyAndConsumeCode checks a presented code against the pending row for
// (userID, purpose), enforcing expiry, target match, and the attempt cap,
// and deletes the row on success (so the raw target, kept only transiently,
// doesn't linger — a minimal-retention requirement for the corporate-email
// case, applied uniformly to all purposes here rather than as a special
// case).
func (s *service) verifyAndConsumeCode(ctx context.Context, userID string, purpose repository.VerificationPurpose, target, code string) error {
	pending, err := s.verificationCodes.Get(ctx, userID, purpose)
	if err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return fmt.Errorf("no pending verification code, please request a new one: %w", apperror.ErrInvalidInput)
		}
		return err
	}

	if time.Now().After(pending.ExpiresAt) {
		_ = s.verificationCodes.Delete(ctx, userID, purpose)
		return fmt.Errorf("code expired, please request a new one: %w", apperror.ErrInvalidInput)
	}
	if pending.Target != target {
		return fmt.Errorf("target does not match the pending verification: %w", apperror.ErrInvalidInput)
	}
	if pending.Attempts >= otpMaxAttempts {
		_ = s.verificationCodes.Delete(ctx, userID, purpose)
		return fmt.Errorf("too many attempts, please request a new code: %w", apperror.ErrInvalidInput)
	}

	if !otpMatches(pending.CodeHash, code) {
		updated, incErr := s.verificationCodes.IncrementAttempts(ctx, userID, purpose)
		if incErr == nil && updated.Attempts >= otpMaxAttempts {
			_ = s.verificationCodes.Delete(ctx, userID, purpose)
		}
		return fmt.Errorf("invalid code: %w", apperror.ErrInvalidInput)
	}

	return s.verificationCodes.Delete(ctx, userID, purpose)
}
