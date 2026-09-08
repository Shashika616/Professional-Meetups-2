package auth

import (
	"context"
	"errors"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The source's decodeUnverifiedTestClaims helper is gone, and so are the
// base64/json imports it needed. It existed to decode the access token a
// session-returning RPC minted, to prove the token carried the RECOMPUTED
// trust level rather than a stale one. That assertion still matters and is
// still made below — against SessionResult.TrustLevel, which is the value
// the gateway now signs into the token (ADR-001 §6). Same property, checked
// one layer earlier; the signing itself is covered by
// internal/gateway/handlers' tests.

// newTestService wires a Service against fakes only — no LinkedIn/Postgres
// dependency needed for the verification RPCs. identities/apple/google are
// unused by every test in this file (none of them touch federated
// signup/linking directly), but New still needs something non-nil to
// construct — see service_test.go's newFederatedTestService for the
// richer helper federated-signup/link-identity tests use instead.
func newTestService(t *testing.T) (*service, *fakeUserRepository, *fakeVerificationCodeRepository, *fakeEmailSender, *fakeSmsSender) {
	t.Helper()
	svc, users, codes, emailSender, smsSender, _, _ := newTestServiceWithCompanies(t)
	return svc, users, codes, emailSender, smsSender
}

// newTestServiceWithCompanies is newTestService plus access to the
// known-companies/unverified-claims fakes — used by
// VerifyCorporateEmailCode's ADR-019 §3 tests, which need to seed
// known_companies rows and assert against the manual-review queue.
func newTestServiceWithCompanies(t *testing.T) (*service, *fakeUserRepository, *fakeVerificationCodeRepository, *fakeEmailSender, *fakeSmsSender, *fakeKnownCompanyRepository, *fakeUnverifiedCompanyClaimRepository) {
	t.Helper()
	users := newFakeUserRepository()
	codes := newFakeVerificationCodeRepository()
	emailSender := &fakeEmailSender{}
	smsSender := &fakeSmsSender{}
	companies := newFakeKnownCompanyRepository()
	claims := &fakeUnverifiedCompanyClaimRepository{}
	svc := New(Deps{
		Users:                   users,
		Identities:              newFakeUserIdentityRepository(),
		RefreshTokens:           newFakeRefreshTokenRepository(),
		VerificationCodes:       codes,
		KnownCompanies:          companies,
		UnverifiedCompanyClaims: claims,
		TrustedContacts:         newFakeTrustedContactRepository(),
		SOSEvents:               &fakeSOSEventRepository{},
		Apple:                   &fakeIdentityProvider{},
		Google:                  &fakeIdentityProvider{},
		Email:                   emailSender,
		SMS:                     smsSender,
		WorkEmailHMACKey:        []byte("test-hmac-key"),
		Logger:                  slog.New(slog.DiscardHandler),
	}).(*service)
	return svc, users, codes, emailSender, smsSender, companies, claims
}

// seedUser seeds a user who already has LinkedIn linked — the pre-ADR-014
// default this file's tests assume throughout (every RPC here is a Level
// 2/3 verification step, and ADR-014 §4 makes LinkedIn a hard prerequisite
// for all of them — see requireLinkedIn in verification.go). Tests that
// specifically need a Level 0 (no LinkedIn) user construct one directly
// instead of calling this helper.
func seedUser(t *testing.T, users *fakeUserRepository, id string) repository.User {
	t.Helper()
	users.byID[id] = repository.User{ID: id, LinkedInSub: "sub-" + id, FullName: "Test User", TrustLevel: 1, AccountStatus: repository.AccountStatusActive}
	return users.byID[id]
}

func TestVerifyPhoneCode_FullRoundTrip(t *testing.T) {
	svc, users, _, _, smsSender := newTestService(t)
	seedUser(t, users, "user-1")

	startResp, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID:  "user-1",
		Purpose: VerificationPurposePhone,
		Target:  "+94771234567",
	})
	if err != nil {
		t.Fatalf("StartPhoneVerification() error: %v", err)
	}
	if startResp.ResendAfterSeconds != int32(otpResendCooldown.Seconds()) {
		t.Errorf("ResendAfterSeconds = %d, want %d", startResp.ResendAfterSeconds, int32(otpResendCooldown.Seconds()))
	}

	code := smsSender.lastCode()
	if code == "" {
		t.Fatal("no code was sent via SmsSender")
	}

	session, err := svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
		UserID:  "user-1",
		Purpose: VerificationPurposePhone,
		Target:  "+94771234567",
		Code:    code,
	})
	if err != nil {
		t.Fatalf("VerifyPhoneCode() error: %v", err)
	}
	if session.UserID != "user-1" {
		t.Errorf("UserId = %q, want %q", session.UserID, "user-1")
	}

	// The returned trust level must be the RECOMPUTED one (still 1 here —
	// phone alone isn't enough for Level 2). This is the value the gateway
	// signs into the fresh access token, so getting it wrong here is exactly
	// the "client shows a stale trust level" bug the reissue exists to
	// prevent.
	if session.TrustLevel != 1 {
		t.Errorf("session trust_level = %d, want %d (phone alone isn't Level 2)", session.TrustLevel, 1)
	}

	if users.byID["user-1"].PhoneNumber != "+94771234567" {
		t.Errorf("PhoneNumber not persisted: got %q", users.byID["user-1"].PhoneNumber)
	}
}

func TestVerifyPhoneCode_WrongCodeRejectedAndDoesNotAdvance(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("StartPhoneVerification() error: %v", err)
	}

	_, err := svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567", Code: "000000",
	})
	if err == nil {
		t.Fatal("VerifyPhoneCode() with wrong code returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
	if users.byID["user-1"].PhoneNumber != "" {
		t.Error("PhoneNumber was persisted despite a wrong code")
	}
}

func TestVerifyPhoneCode_AttemptCapInvalidatesCode(t *testing.T) {
	svc, users, verificationCodes, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("StartPhoneVerification() error: %v", err)
	}

	for i := 0; i < otpMaxAttempts; i++ {
		_, err := svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
			UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567", Code: "000000",
		})
		if err == nil {
			t.Fatalf("attempt %d: VerifyPhoneCode() with wrong code returned nil error, want error", i+1)
		}
	}

	// The code must be invalidated after the cap — confirm the row is gone,
	// not just that guesses keep failing.
	if _, err := verificationCodes.Get(context.Background(), "user-1", repository.VerificationPurposePhone); err == nil {
		t.Error("verification code row still exists after hitting the attempt cap, want it deleted")
	}
}

func TestStartPhoneVerification_ResendCooldownRejectsTooSoon(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("first StartPhoneVerification() error: %v", err)
	}

	_, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	})
	if err == nil {
		t.Fatal("second StartPhoneVerification() within the cooldown returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("error = %v, want %v", err, apperror.ErrRateLimited)
	}
}

func TestStartPhoneVerification_ResendAllowedAfterCooldownUpsertsFreshCode(t *testing.T) {
	svc, users, verificationCodes, _, smsSender := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("first StartPhoneVerification() error: %v", err)
	}
	firstCode := smsSender.lastCode()

	// Simulate the cooldown having elapsed by backdating the stored row's
	// CreatedAt directly, rather than sleeping the test for a real minute.
	key := verificationCodeKey("user-1", repository.VerificationPurposePhone)
	row := verificationCodes.rows[key]
	row.CreatedAt = time.Now().Add(-2 * otpResendCooldown)
	verificationCodes.rows[key] = row

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("second StartPhoneVerification() after cooldown elapsed returned error: %v", err)
	}
	secondCode := smsSender.lastCode()

	if secondCode == firstCode {
		t.Error("resend after cooldown produced the same code — want a freshly generated one")
	}
	// Only one row for (user, purpose) — upsert, not a stacked second row.
	if len(verificationCodes.rows) != 1 {
		t.Errorf("verification_codes rows for this user/purpose = %d, want 1 (upsert, not stack)", len(verificationCodes.rows))
	}
}

func TestStartCorporateEmailVerification_RejectsFreeAndRoleBasedDomains(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	_, err := svc.StartCorporateEmailVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposeCorporateEmail, Target: "someone@gmail.com",
	})
	if err == nil {
		t.Fatal("StartCorporateEmailVerification() with a free-domain address returned nil error, want error")
	}
	const wantMsg = "please use your work email, not a personal address: invalid input"
	if got := err.Error(); got != wantMsg {
		t.Errorf("error message = %q, want %q", got, wantMsg)
	}
}

// verifyCorporateEmail is a small helper shared by ADR-019 §3's test suite
// below — starts and completes corporate-email verification for userID
// against target/companyName in one call, returning the resulting session
// (or error).
func verifyCorporateEmail(t *testing.T, svc *service, emailSender *fakeEmailSender, userID, target, companyName string) (SessionResult, error) {
	t.Helper()
	if _, err := svc.StartCorporateEmailVerification(context.Background(), StartVerificationRequest{
		UserID: userID, Purpose: VerificationPurposeCorporateEmail, Target: target,
	}); err != nil {
		t.Fatalf("StartCorporateEmailVerification() error: %v", err)
	}
	return svc.VerifyCorporateEmailCode(context.Background(), VerifyCodeRequest{
		UserID: userID, Purpose: VerificationPurposeCorporateEmail,
		Target: target, Code: emailSender.lastCode(), CompanyName: companyName,
	})
}

func TestVerifyCorporateEmailCode_ExtractsDomainAndDeletesRawAddress(t *testing.T) {
	svc, users, verificationCodes, emailSender, _, _, _ := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")

	// "Acme Corp" is not seeded in known_companies — the unknown-company
	// fallback path, which still accepts and stores the domain (ADR-019
	// §3).
	session, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp")
	if err != nil {
		t.Fatalf("VerifyCorporateEmailCode() error: %v", err)
	}
	_ = session

	got := users.byID["user-1"]
	if got.CompanyDomain != "acmecorp.com" {
		t.Errorf("CompanyDomain = %q, want %q", got.CompanyDomain, "acmecorp.com")
	}
	if !got.WorkEmailVerified {
		t.Error("WorkEmailVerified = false, want true")
	}
	if got.CompanyDomain == "jane@acmecorp.com" {
		t.Error("CompanyDomain stores the raw address, want only the domain (ADR-003)")
	}
	if got.WorkEmailHash == "" {
		t.Error("WorkEmailHash is empty, want a computed hash (ADR-019 §3)")
	}

	// The raw address, transiently held in verification_codes.target, must
	// be gone after success — query the row, don't just trust the code path.
	if _, err := verificationCodes.Get(context.Background(), "user-1", repository.VerificationPurposeCorporateEmail); err == nil {
		t.Error("verification code row (containing the raw address) still exists after successful verification")
	}
}

func TestVerifyCorporateEmailCode_RequiresLinkedInIsNoLongerEnforced(t *testing.T) {
	// ADR-019 §4: company-email verification must be reachable from the new
	// mandatory post-auth profile-setup screen at Level 0, before LinkedIn
	// is ever connected — regression-guards against reintroducing
	// requireLinkedIn on this path.
	svc, users, _, emailSender, _, _, _ := newTestServiceWithCompanies(t)
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Level Zero", TrustLevel: 0, AccountStatus: repository.AccountStatusActive}

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp"); err != nil {
		t.Fatalf("VerifyCorporateEmailCode() for a Level 0 (no LinkedIn) user returned error: %v, want success", err)
	}
}

func TestVerifyCorporateEmailCode_KnownCompanyDomainMatch(t *testing.T) {
	svc, users, _, emailSender, _, companies, claims := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")
	companies.byNameNormalized["acme corp"] = repository.KnownCompany{NameNormalized: "acme corp", Domains: []string{"acmecorp.com"}}

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp"); err != nil {
		t.Fatalf("VerifyCorporateEmailCode() error: %v", err)
	}
	if !users.byID["user-1"].WorkEmailVerified {
		t.Error("WorkEmailVerified = false, want true")
	}
	if len(claims.claims) != 0 {
		t.Errorf("unverified_company_claims got %d row(s), want 0 — a known-company domain match should never be flagged", len(claims.claims))
	}
}

// TestVerifyCorporateEmailCode_KnownCompanyDomainCaseInsensitiveMatch guards
// ADR-019's 2026-08-24 correction: known_companies.domains is seeded
// lowercase, but a legitimate employee typing their email with any other
// capitalization must still match — domain names are case-insensitive
// (RFC 4343), and this isn't a security control (case variation gives an
// attacker no way to claim a domain they don't already control), so it
// must not produce a false errCompanyDomainMismatch.
func TestVerifyCorporateEmailCode_KnownCompanyDomainCaseInsensitiveMatch(t *testing.T) {
	svc, users, _, emailSender, _, companies, claims := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")
	companies.byNameNormalized["combank"] = repository.KnownCompany{NameNormalized: "combank", Domains: []string{"combank.lk"}}

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "Jane@ComBank.LK", "ComBank"); err != nil {
		t.Fatalf("VerifyCorporateEmailCode() error: %v, want success for a domain that only differs in case from the seeded row", err)
	}
	if !users.byID["user-1"].WorkEmailVerified {
		t.Error("WorkEmailVerified = false, want true")
	}
	if got := users.byID["user-1"].CompanyDomain; got != "combank.lk" {
		t.Errorf("CompanyDomain = %q, want %q (lowercased)", got, "combank.lk")
	}
	if len(claims.claims) != 0 {
		t.Errorf("unverified_company_claims got %d row(s), want 0 — a known-company domain match (case-insensitive) should never be flagged", len(claims.claims))
	}
}

func TestVerifyCorporateEmailCode_KnownCompanyDomainMismatchRejected(t *testing.T) {
	svc, users, _, emailSender, _, companies, _ := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")
	companies.byNameNormalized["acme corp"] = repository.KnownCompany{NameNormalized: "acme corp", Domains: []string{"acmecorp.com"}}

	_, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acme-hr-careers.net", "Acme Corp")
	if err == nil {
		t.Fatal("VerifyCorporateEmailCode() with a lookalike domain returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v (ErrInvalidInput)", err, apperror.ErrInvalidInput)
	}
	if users.byID["user-1"].WorkEmailVerified {
		t.Error("WorkEmailVerified = true, want false — domain mismatch must not persist")
	}
}

func TestVerifyCorporateEmailCode_UnknownCompanyAcceptsAndFlagsForReview(t *testing.T) {
	svc, users, _, emailSender, _, _, claims := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@unknownco.com", "Unknown Co"); err != nil {
		t.Fatalf("VerifyCorporateEmailCode() error: %v", err)
	}
	if !users.byID["user-1"].WorkEmailVerified {
		t.Error("WorkEmailVerified = false, want true — unknown company still accepts per the MVP fallback")
	}
	if len(claims.claims) != 1 {
		t.Fatalf("unverified_company_claims got %d row(s), want 1", len(claims.claims))
	}
	if claims.claims[0].UserID != "user-1" || claims.claims[0].Domain != "unknownco.com" {
		t.Errorf("claim = %+v, want UserID=user-1 Domain=unknownco.com", claims.claims[0])
	}
}

func TestVerifyCorporateEmailCode_SameUserReverifyIsNoOp(t *testing.T) {
	svc, users, _, emailSender, _, _, _ := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp"); err != nil {
		t.Fatalf("first VerifyCorporateEmailCode() error: %v", err)
	}
	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp"); err != nil {
		t.Fatalf("re-verification by the same user returned error, want no-op success: %v", err)
	}
}

func TestVerifyCorporateEmailCode_DifferentUserSameHashRejected(t *testing.T) {
	svc, users, _, emailSender, _, _, _ := newTestServiceWithCompanies(t)
	seedUser(t, users, "user-1")
	seedUser(t, users, "user-2")

	if _, err := verifyCorporateEmail(t, svc, emailSender, "user-1", "jane@acmecorp.com", "Acme Corp"); err != nil {
		t.Fatalf("first VerifyCorporateEmailCode() error: %v", err)
	}

	_, err := verifyCorporateEmail(t, svc, emailSender, "user-2", "jane@acmecorp.com", "Acme Corp")
	if err == nil {
		t.Fatal("VerifyCorporateEmailCode() for the same mailbox on a different account returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("error = %v, want %v (ErrConflict)", err, apperror.ErrConflict)
	}
	if users.byID["user-2"].WorkEmailVerified {
		t.Error("WorkEmailVerified = true for user-2, want false — reuse must not persist")
	}
}

func TestVerifyPhoneCode_ConflictWhenAlreadyVerifiedOnDifferentAccount(t *testing.T) {
	svc, users, _, _, smsSender := newTestService(t)
	seedUser(t, users, "user-1")
	seedUser(t, users, "user-2")

	// user-1 already verified this number.
	users.byID["user-1"] = repository.User{ID: "user-1", PhoneNumber: "+94771234567", TrustLevel: 2, AccountStatus: repository.AccountStatusActive}

	// user-2 independently starts and completes verification for the same
	// number — simulating the race the addendum describes (both hold a
	// valid pending code; this fake doesn't block Start on an already-taken
	// target, matching the real repository's design).
	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-2", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("StartPhoneVerification() for user-2 error: %v", err)
	}

	_, err := svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
		UserID: "user-2", Purpose: VerificationPurposePhone, Target: "+94771234567", Code: smsSender.lastCode(),
	})
	if err == nil {
		t.Fatal("VerifyPhoneCode() for a number already verified on a different account returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("error = %v, want %v (ErrConflict)", err, apperror.ErrConflict)
	}
}

// verifyPhone is a small helper mirroring verifyCorporateEmail — starts and
// completes phone verification for userID against target in one call. Safe
// to call twice in a row for the same user (re-verification, ADR-023 §5):
// verifyAndConsumeCode deletes the pending code row on success, so the
// second Start call's otpResendCooldown check (which only looks at an
// existing row) never finds one to rate-limit against.
func verifyPhone(t *testing.T, svc *service, smsSender *fakeSmsSender, userID, target string) (SessionResult, error) {
	t.Helper()
	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: userID, Purpose: VerificationPurposePhone, Target: target,
	}); err != nil {
		t.Fatalf("StartPhoneVerification() error: %v", err)
	}
	return svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
		UserID: userID, Purpose: VerificationPurposePhone, Target: target, Code: smsSender.lastCode(),
	})
}

// verifyPersonalEmail is verifyPhone's personal-email equivalent.
func verifyPersonalEmail(t *testing.T, svc *service, emailSender *fakeEmailSender, userID, target string) (SessionResult, error) {
	t.Helper()
	if _, err := svc.StartPersonalEmailVerification(context.Background(), StartVerificationRequest{
		UserID: userID, Purpose: VerificationPurposePersonalEmail, Target: target,
	}); err != nil {
		t.Fatalf("StartPersonalEmailVerification() error: %v", err)
	}
	return svc.VerifyPersonalEmailCode(context.Background(), VerifyCodeRequest{
		UserID: userID, Purpose: VerificationPurposePersonalEmail, Target: target, Code: emailSender.lastCode(),
	})
}

// TestVerifyPhoneCode_SameUserReverifyIsNoOp mirrors
// TestVerifyCorporateEmailCode_SameUserReverifyIsNoOp — ADR-023 §5 needs the
// already-verified Phone row to be re-editable, which starts with
// confirming re-verifying with the identical number is already a no-op
// success today (it is: UpdatePhoneNumber's uniqueness check only rejects a
// value already held by a *different* user, so updating a row to the value
// it already has never conflicts with itself — no code change was needed
// for this case, only this regression test).
func TestVerifyPhoneCode_SameUserReverifyIsNoOp(t *testing.T) {
	svc, users, _, _, smsSender := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := verifyPhone(t, svc, smsSender, "user-1", "+94771234567"); err != nil {
		t.Fatalf("first VerifyPhoneCode() error: %v", err)
	}
	if _, err := verifyPhone(t, svc, smsSender, "user-1", "+94771234567"); err != nil {
		t.Fatalf("re-verification by the same user with the same number returned error, want no-op success: %v", err)
	}
}

// TestVerifyPhoneCode_DifferentNumberUpdates confirms editing to a genuinely
// new number (ADR-023 §5's "Phone" row edit) goes through the full OTP
// round-trip against the new value and persists it.
func TestVerifyPhoneCode_DifferentNumberUpdates(t *testing.T) {
	svc, users, _, _, smsSender := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := verifyPhone(t, svc, smsSender, "user-1", "+94771234567"); err != nil {
		t.Fatalf("first VerifyPhoneCode() error: %v", err)
	}
	if _, err := verifyPhone(t, svc, smsSender, "user-1", "+94779999999"); err != nil {
		t.Fatalf("VerifyPhoneCode() with a new number returned error: %v", err)
	}
	if got := users.byID["user-1"].PhoneNumber; got != "+94779999999" {
		t.Errorf("PhoneNumber = %q, want %q (the new value)", got, "+94779999999")
	}
}

// TestVerifyPersonalEmailCode_SameUserReverifyIsNoOp is
// TestVerifyPhoneCode_SameUserReverifyIsNoOp's personal-email equivalent.
func TestVerifyPersonalEmailCode_SameUserReverifyIsNoOp(t *testing.T) {
	svc, users, _, emailSender, _ := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := verifyPersonalEmail(t, svc, emailSender, "user-1", "ada@example.com"); err != nil {
		t.Fatalf("first VerifyPersonalEmailCode() error: %v", err)
	}
	if _, err := verifyPersonalEmail(t, svc, emailSender, "user-1", "ada@example.com"); err != nil {
		t.Fatalf("re-verification by the same user with the same email returned error, want no-op success: %v", err)
	}
}

// TestVerifyPersonalEmailCode_DifferentEmailUpdates is
// TestVerifyPhoneCode_DifferentNumberUpdates's personal-email equivalent.
func TestVerifyPersonalEmailCode_DifferentEmailUpdates(t *testing.T) {
	svc, users, _, emailSender, _ := newTestService(t)
	seedUser(t, users, "user-1")

	if _, err := verifyPersonalEmail(t, svc, emailSender, "user-1", "ada@example.com"); err != nil {
		t.Fatalf("first VerifyPersonalEmailCode() error: %v", err)
	}
	if _, err := verifyPersonalEmail(t, svc, emailSender, "user-1", "ada.new@example.com"); err != nil {
		t.Fatalf("VerifyPersonalEmailCode() with a new email returned error: %v", err)
	}
	if got := users.byID["user-1"].PersonalEmail; got != "ada.new@example.com" {
		t.Errorf("PersonalEmail = %q, want %q (the new value)", got, "ada.new@example.com")
	}
}

func TestSubmitPersonalDetails(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	t.Run("rejects empty legal name even with an address set", func(t *testing.T) {
		_, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{UserID: "user-1", LegalName: "", Address: "1 Main St"})
		if err == nil {
			t.Fatal("SubmitPersonalDetails() with empty legal_name returned nil error, want error")
		}
	})

	t.Run("persists and reflects in trust level once all 3 fields are set, address empty", func(t *testing.T) {
		users.byID["user-1"] = repository.User{
			ID: "user-1", LinkedInSub: "sub-user-1", PhoneNumber: "+94771234567", PersonalEmail: "a@example.com", TrustLevel: 1, AccountStatus: repository.AccountStatusActive,
		}

		// ADR-023 §1: address is deliberately omitted here — reaching Level
		// 2 must not depend on it.
		session, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{
			UserID: "user-1", LegalName: "Ada Lovelace",
		})
		if err != nil {
			t.Fatalf("SubmitPersonalDetails() error: %v", err)
		}

		if session.TrustLevel != 2 {
			t.Errorf("session trust_level = %d, want %d", session.TrustLevel, 2)
		}
		if users.byID["user-1"].Address != "" {
			t.Errorf("Address = %q, want empty — it was never sent", users.byID["user-1"].Address)
		}
	})

	t.Run("rejects a legal name longer than the server-side max", func(t *testing.T) {
		_, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{
			UserID: "user-1", LegalName: strings.Repeat("a", maxLegalNameLength+1),
		})
		if err == nil {
			t.Fatal("SubmitPersonalDetails() with an over-long legal name returned nil error, want error")
		}
	})

	t.Run("rejects an address longer than the server-side max", func(t *testing.T) {
		_, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{
			UserID: "user-1", LegalName: "Ada Lovelace", Address: strings.Repeat("a", maxAddressLength+1),
		})
		if err == nil {
			t.Fatal("SubmitPersonalDetails() with an over-long address returned nil error, want error")
		}
	})

	t.Run("still accepts and persists an address if the caller sends one", func(t *testing.T) {
		users.byID["user-1"] = repository.User{
			ID: "user-1", LinkedInSub: "sub-user-1", PhoneNumber: "+94771234567", PersonalEmail: "a@example.com", TrustLevel: 1, AccountStatus: repository.AccountStatusActive,
		}

		if _, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{
			UserID: "user-1", LegalName: "Ada Lovelace", Address: "1 Main St, Colombo",
		}); err != nil {
			t.Fatalf("SubmitPersonalDetails() error: %v", err)
		}
		if got := users.byID["user-1"].Address; got != "1 Main St, Colombo" {
			t.Errorf("Address = %q, want %q — the column still accepts a value when sent", got, "1 Main St, Colombo")
		}
	})
}

// TestGetProfile_ReturnsRawContactInfoToOwner is ADR-023 §4's corrected
// behavior — Verification Model § 1's actual rule is "never reveal ... to
// other users", which this endpoint already only ever answers about the
// caller's own account (userID is gateway-set from the verified JWT). Prior
// to ADR-023 this test was named TestGetProfile_NeverReturnsRawContactInfo
// and asserted the opposite; that assertion encoded an over-generalization
// of the domain rule, not the rule itself — see the ADR for the full
// reasoning.
func TestGetProfile_ReturnsRawContactInfoToOwner(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	users.byID["user-1"] = repository.User{
		ID:                "user-1",
		FullName:          "Ada Lovelace",
		TrustLevel:        3,
		PhoneNumber:       "+94771234567",
		PersonalEmail:     "ada@example.com",
		LegalName:         "Ada Lovelace",
		Address:           "1 Main St, Colombo",
		CompanyDomain:     "acmecorp.com",
		WorkEmailVerified: true,
		AccountStatus:     repository.AccountStatusActive,
	}

	profile, err := svc.GetProfile(context.Background(), "user-1")
	if err != nil {
		t.Fatalf("GetProfile() error: %v", err)
	}

	if !profile.PhoneVerified || !profile.PersonalEmailVerified || !profile.PersonalDetailsComplete || !profile.WorkEmailVerified {
		t.Errorf("expected all verification booleans true, got %+v", profile)
	}
	if profile.CompanyDomain != "acmecorp.com" {
		t.Errorf("CompanyDomain = %q, want %q", profile.CompanyDomain, "acmecorp.com")
	}

	// The four new raw fields (ADR-023 §4) — this is the caller's own
	// account, so these must be populated, not blanked.
	if got := profile.PhoneNumber; got != "+94771234567" {
		t.Errorf("PhoneNumber = %q, want %q", got, "+94771234567")
	}
	if got := profile.PersonalEmail; got != "ada@example.com" {
		t.Errorf("PersonalEmail = %q, want %q", got, "ada@example.com")
	}
	if got := profile.LegalName; got != "Ada Lovelace" {
		t.Errorf("LegalName = %q, want %q", got, "Ada Lovelace")
	}
	if got := profile.Address; got != "1 Main St, Colombo" {
		t.Errorf("Address = %q, want %q", got, "1 Main St, Colombo")
	}

	// The response type still has no field capable of carrying a raw work
	// email — that rule is untouched, and is structural rather than a
	// "the code happens not to populate it" property. The source asserted
	// this by counting the protobuf message's fields; the module's own
	// response type is a plain struct, so this counts (and names) its fields
	// by reflection instead, which additionally catches a rename.
	wantFields := map[string]bool{
		"UserID": true, "FullName": true, "ProfilePhotoURL": true, "TrustLevel": true,
		"PhoneVerified": true, "PersonalEmailVerified": true, "PersonalDetailsComplete": true,
		"CompanyDomain": true, "WorkEmailVerified": true, "RatingAverage": true, "RatingCount": true,
		"PhoneNumber": true, "PersonalEmail": true, "LegalName": true, "Address": true,
		// ADR-002: IsGuest lets the client render guest chrome; CompanyName
		// is the user's own self-entered organisation name, self-view only,
		// alongside the CompanyDomain already allowed above. Both are
		// deliberate additions to this allowlist — the guard exists to catch
		// an ACCIDENTAL field (above all a raw work email, ADR-003), and it
		// did its job by failing when these two arrived.
		"IsGuest": true, "CompanyName": true, "LinkedInConnected": true,
		// MeetupsCompleted (auth/0005) is likewise a deliberate addition,
		// and likewise had to be added here because the guard failed first.
		// It is a count the user's own profile screen displays — no PII, and
		// nothing derived from a work email.
		"MeetupsCompleted": true,
	}
	profileType := reflect.TypeOf(profile)
	if got := profileType.NumField(); got != len(wantFields) {
		t.Errorf("Profile field count = %d, want %d — verify no unexpected field (e.g. a raw work email) was added", got, len(wantFields))
	}
	for i := 0; i < profileType.NumField(); i++ {
		name := profileType.Field(i).Name
		if !wantFields[name] {
			t.Errorf("Profile has unexpected field %q — a raw work email must never be returned to anyone", name)
		}
		if strings.Contains(strings.ToLower(name), "workemail") && name != "WorkEmailVerified" {
			t.Errorf("Profile field %q looks like it could carry work-email material", name)
		}
	}
}

// TestGetProfile_UserIDComesOnlyFromRequest_NeverABodyOrOtherSource is the
// service-layer half of ADR-023's explicitly-called-out security re-check:
// GetProfile has exactly one source of identity, the request's user_id
// (which the gateway sets from the verified JWT — see
// handlers/verification.go's getProfile and its own IDOR-guard test). There
// is no session/context-based identity this function could fall back to or
// be confused by; it looks up whatever user_id it's given, full stop. This
// test pins that shape so a future refactor can't quietly add a second,
// looser identity source.
func TestGetProfile_UserIDComesOnlyFromRequest_NeverABodyOrOtherSource(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "User One", AccountStatus: repository.AccountStatusActive}
	users.byID["user-2"] = repository.User{ID: "user-2", FullName: "User Two", PhoneNumber: "+94770000000", AccountStatus: repository.AccountStatusActive}

	profile, err := svc.GetProfile(context.Background(), "user-1")
	if err != nil {
		t.Fatalf("GetProfile() error: %v", err)
	}
	if profile.UserID != "user-1" || profile.PhoneNumber != "" {
		t.Errorf("GetProfile(user-1) = %+v, want user-1's own (empty) data, never user-2's", profile)
	}
}
