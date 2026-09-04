package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// newTestSigner is gone, deliberately: the source's equivalent helper
// generated a throwaway RSA keypair because Service held a jwt.Signer and
// every session-issuing test asserted on the token it minted. This module
// holds no signer at all (ADR-001 §6) — token signing is the gateway's, and
// is covered by internal/gateway/handlers' own tests. What these tests
// assert instead, on every session path, is the identity facts the gateway
// signs FROM: user id, trust level, and a fresh refresh token.

// newTestLinkedInServer stands in for LinkedIn's token + userinfo endpoints.
func newTestLinkedInServer(t *testing.T) (*linkedin.Client, func()) {
	t.Helper()

	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"li-access-token","expires_in":5184000}`))
	})
	mux.HandleFunc("/userinfo", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"sub":"li-sub-123","name":"Ada Lovelace","picture":"https://example.com/p.jpg"}`))
	})
	server := httptest.NewServer(mux)

	client := linkedin.New(
		linkedin.Config{ClientID: "cid", ClientSecret: "csecret"},
		linkedin.WithTokenURL(server.URL+"/token"),
		linkedin.WithUserInfoURL(server.URL+"/userinfo"),
	)

	return client, server.Close
}

// newFederatedTestService builds a Service with fakes for every dependency except
// the ones the caller overrides — a shared constructor so each test below
// only has to spell out what it actually cares about, mirroring the
// pattern this file already used pre-ADR-014 for New(...)'s previously
// shorter argument list.
func newFederatedTestService(t *testing.T, opts ...func(*testServiceDeps)) (*service, *testServiceDeps) {
	t.Helper()

	li, closeLI := newTestLinkedInServer(t)
	t.Cleanup(closeLI)

	deps := &testServiceDeps{
		users:           newFakeUserRepository(),
		identities:      newFakeUserIdentityRepository(),
		tokens:          newFakeRefreshTokenRepository(),
		codes:           newFakeVerificationCodeRepository(),
		companies:       newFakeKnownCompanyRepository(),
		claims:          &fakeUnverifiedCompanyClaimRepository{},
		trustedContacts: newFakeTrustedContactRepository(),
		sosEvents:       &fakeSOSEventRepository{},
		linkedin:        li,
		apple:           &fakeIdentityProvider{validTokens: map[string]identity.VerifiedIdentity{}},
		google:          &fakeIdentityProvider{validTokens: map[string]identity.VerifiedIdentity{}},
		emailer:         &fakeEmailSender{},
		smser:           &fakeSmsSender{},
	}
	for _, opt := range opts {
		opt(deps)
	}

	svc := New(Deps{
		Users:                   deps.users,
		Identities:              deps.identities,
		RefreshTokens:           deps.tokens,
		VerificationCodes:       deps.codes,
		KnownCompanies:          deps.companies,
		UnverifiedCompanyClaims: deps.claims,
		TrustedContacts:         deps.trustedContacts,
		SOSEvents:               deps.sosEvents,
		LinkedIn:                deps.linkedin,
		Apple:                   deps.apple,
		Google:                  deps.google,
		Email:                   deps.emailer,
		SMS:                     deps.smser,
		WorkEmailHMACKey:        []byte("test-hmac-key"),
		Logger:                  slog.New(slog.DiscardHandler),
	}).(*service)
	return svc, deps
}

type testServiceDeps struct {
	users           *fakeUserRepository
	identities      *fakeUserIdentityRepository
	tokens          *fakeRefreshTokenRepository
	codes           *fakeVerificationCodeRepository
	companies       *fakeKnownCompanyRepository
	claims          *fakeUnverifiedCompanyClaimRepository
	trustedContacts *fakeTrustedContactRepository
	sosEvents       *fakeSOSEventRepository
	linkedin        *linkedin.Client
	apple           *fakeIdentityProvider
	google          *fakeIdentityProvider
	emailer         *fakeEmailSender
	smser           *fakeSmsSender
}

func TestCompleteFederatedSignup_NewUser(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "apple-sub-123", Email: "ada@example.com", Name: "Ada Lovelace",
	}

	resp, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
	})
	if err != nil {
		t.Fatalf("CompleteFederatedSignup() error: %v", err)
	}

	if !resp.IsNewUser {
		t.Error("IsNewUser = false, want true")
	}
	// No access token to assert on here any more (ADR-001 §6) — what the
	// gateway needs in order to mint one is the refresh token plus the
	// identity facts, so those are what this checks instead.
	if resp.RefreshToken == "" {
		t.Error("RefreshToken is empty")
	}
	if resp.FullName != "Ada Lovelace" {
		t.Errorf("FullName = %q, want %q", resp.FullName, "Ada Lovelace")
	}

	created := deps.users.byID[resp.UserID]
	if created.TrustLevel != 0 {
		t.Errorf("new federated user's TrustLevel = %d, want 0 (Level 0, no LinkedIn linked yet)", created.TrustLevel)
	}
	if !created.AgeConfirmedOver18 {
		t.Error("AgeConfirmedOver18 = false, want true")
	}
	if created.AgeConfirmedAt == nil {
		t.Error("AgeConfirmedAt is nil, want set")
	}

	identityRow, err := deps.identities.GetByProviderSubject(context.Background(), repository.IdentityProviderApple, "apple-sub-123")
	if err != nil {
		t.Fatalf("expected a user_identities row for the new apple identity, got error: %v", err)
	}
	if identityRow.UserID != resp.UserID {
		t.Errorf("identity row UserID = %q, want %q", identityRow.UserID, resp.UserID)
	}
	if identityRow.Email != "ada@example.com" {
		t.Errorf("identity row Email = %q, want %q", identityRow.Email, "ada@example.com")
	}

	// Create is only ever called to make a genuinely new account (never for
	// an existing one) — the real repository writes the user-onboarded
	// outbox row transactionally inside Create itself (ADR-018), so one
	// createCalls entry here is the same guarantee "PublishUserOnboarded
	// called once" used to assert directly.
	if len(deps.users.createCalls) != 1 {
		t.Fatalf("Create called %d times, want 1", len(deps.users.createCalls))
	}
	if deps.users.createCalls[0].TrustLevel != 0 {
		t.Errorf("created user's TrustLevel = %d, want 0", deps.users.createCalls[0].TrustLevel)
	}
}

func TestCompleteFederatedSignup_ReturningUserLogsIn(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.google.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "google-sub-123", Email: "ada@example.com", Name: "Ada Lovelace",
	}

	first, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderGoogle,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
	})
	if err != nil {
		t.Fatalf("first CompleteFederatedSignup() error: %v", err)
	}

	second, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderGoogle,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
	})
	if err != nil {
		t.Fatalf("second CompleteFederatedSignup() error: %v", err)
	}

	if second.IsNewUser {
		t.Error("IsNewUser = true on the second sign-in, want false")
	}
	if second.UserID != first.UserID {
		t.Errorf("second sign-in UserId = %q, want the same user %q", second.UserID, first.UserID)
	}
	if len(deps.users.createCalls) != 1 {
		t.Errorf("Create called %d times across both sign-ins, want 1 (only the first)", len(deps.users.createCalls))
	}
}

func TestCompleteFederatedSignup_RejectsAgeNotConfirmed(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{Subject: "apple-sub-123", Name: "Ada Lovelace"}

	_, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "good-token",
		AgeConfirmedOver18: false,
		Nonce:              "test-nonce",
	})
	if err == nil {
		t.Fatal("CompleteFederatedSignup() returned nil error for age_confirmed_over_18=false, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
	if len(deps.users.createCalls) != 0 {
		t.Errorf("Create called %d times, want 0 — no account should be created when age isn't confirmed", len(deps.users.createCalls))
	}
}

func TestCompleteFederatedSignup_RejectsFailedVerification(t *testing.T) {
	svc, _ := newFederatedTestService(t, func(d *testServiceDeps) {
		d.apple = &fakeIdentityProvider{err: context.DeadlineExceeded}
	})

	_, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "any-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
	})
	if err == nil {
		t.Fatal("CompleteFederatedSignup() returned nil error for a failed id_token verification, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

func TestLinkIdentity_LinksLinkedInToExistingFederatedUser(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	user, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: "Ada Lovelace", TrustLevel: 0, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed federated user: %v", err)
	}

	resp, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:            user.ID,
		Provider:          FederatedProviderLinkedIn,
		AuthorizationCode: "auth-code",
		RedirectURI:       "app://callback",
	})
	if err != nil {
		t.Fatalf("LinkIdentity() error: %v", err)
	}

	if resp.UserID != user.ID {
		t.Errorf("UserId = %q, want %q", resp.UserID, user.ID)
	}
	linked := deps.users.byID[user.ID]
	if linked.LinkedInSub != "li-sub-123" {
		t.Errorf("LinkedInSub = %q, want %q", linked.LinkedInSub, "li-sub-123")
	}
	if linked.TrustLevel != 1 {
		t.Errorf("TrustLevel after linking LinkedIn = %d, want 1", linked.TrustLevel)
	}
}

// TestLinkIdentity_RejectsLinkedInSubjectAlreadyLinkedToADifferentUser is
// the explicit abuse-case test the backend plan calls out by name: linking
// must never silently merge two accounts.
func TestLinkIdentity_RejectsLinkedInSubjectAlreadyLinkedToADifferentUser(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	// A different user already has this exact LinkedIn subject linked
	// (li-sub-123, per newTestLinkedInServer's fixed response).
	if _, err := deps.users.Create(context.Background(), fakeNewUser("li-sub-123")); err != nil {
		t.Fatalf("seed existing linkedin-linked user: %v", err)
	}

	victim, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: "Bob", TrustLevel: 0, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed second federated user: %v", err)
	}

	_, err = svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:            victim.ID,
		Provider:          FederatedProviderLinkedIn,
		AuthorizationCode: "auth-code",
		RedirectURI:       "app://callback",
	})
	if err == nil {
		t.Fatal("LinkIdentity() returned nil error when the LinkedIn subject already belongs to a different user, want error")
	}
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("error = %v, want %v (ErrConflict)", err, apperror.ErrConflict)
	}

	// The victim must not have been silently merged/updated.
	unchanged := deps.users.byID[victim.ID]
	if unchanged.LinkedInSub != "" {
		t.Errorf("victim's LinkedInSub = %q, want unchanged (empty)", unchanged.LinkedInSub)
	}
}

// TestLinkIdentity_SupportsAppleAndGoogleToo confirms LinkIdentity dispatches
// the Apple/Google branch (id_token verification, no server-to-server
// exchange) just as validly as the LinkedIn branch — ADR-014's Profile
// "Connect LinkedIn" flow is the only one built out end-to-end in the
// frontend for v1, but the RPC itself is provider-generic (a future "add
// Apple/Google as backup sign-in" reuses this same path).
func TestLinkIdentity_SupportsAppleAndGoogleToo(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{Subject: "apple-sub-77"}
	user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

	resp, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:   user.ID,
		Provider: FederatedProviderApple,
		IDToken:  "good-token",
		Nonce:    "test-nonce",
	})
	if err != nil {
		t.Fatalf("LinkIdentity() error: %v", err)
	}
	if resp.UserID != user.ID {
		t.Errorf("UserId = %q, want %q", resp.UserID, user.ID)
	}

	row, err := deps.identities.GetByProviderSubject(context.Background(), repository.IdentityProviderApple, "apple-sub-77")
	if err != nil {
		t.Fatalf("expected a user_identities row, got error: %v", err)
	}
	if row.UserID != user.ID {
		t.Errorf("identity row UserID = %q, want %q", row.UserID, user.ID)
	}
}

func TestLinkIdentity_RejectsUnspecifiedProvider(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

	_, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:   user.ID,
		Provider: FederatedProvider(""),
	})
	if err == nil {
		t.Fatal("LinkIdentity() returned nil error for provider=UNSPECIFIED, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

func TestCompleteLinkedInOnboarding_NewUserGrantsLevel1Immediately(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	resp, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode:  "auth-code",
		RedirectURI:        "app://callback",
		AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteLinkedInOnboarding() error: %v", err)
	}
	if !resp.IsNewUser {
		t.Error("IsNewUser = false, want true")
	}

	created := deps.users.byID[resp.UserID]
	if created.LinkedInSub != "li-sub-123" {
		t.Errorf("LinkedInSub = %q, want %q", created.LinkedInSub, "li-sub-123")
	}
	if created.TrustLevel != 1 {
		t.Errorf("TrustLevel = %d, want 1 (LinkedIn direct signup, unchanged from ADR-011)", created.TrustLevel)
	}
	if created.ProfilePhotoURL == "" {
		t.Error("ProfilePhotoURL is empty, want the photo from LinkedIn's userinfo response (no regression vs. ADR-011)")
	}
}

func TestCompleteLinkedInOnboarding_ReturningUserLogsIn(t *testing.T) {
	svc, _ := newFederatedTestService(t)

	first, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode:  "auth-code",
		RedirectURI:        "app://callback",
		AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("first CompleteLinkedInOnboarding() error: %v", err)
	}

	second, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode:  "auth-code-2",
		RedirectURI:        "app://callback",
		AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("second CompleteLinkedInOnboarding() error: %v", err)
	}
	if second.IsNewUser {
		t.Error("IsNewUser = true on the second sign-in, want false")
	}
	if second.UserID != first.UserID {
		t.Errorf("second sign-in UserId = %q, want the same user %q", second.UserID, first.UserID)
	}
}

// TestCompleteLinkedInOnboarding_RejectsAgeNotConfirmed is the one addition
// to this RPC's behavior vs. ADR-011 (backend/level0-federated-identity-
// PLAN.md Step 6) — LinkedIn direct signup didn't have an age gate before
// ADR-014 and needed one, since it's a standalone account-creation path
// just like the other three.
func TestCompleteLinkedInOnboarding_RejectsAgeNotConfirmed(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	_, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode:  "auth-code",
		RedirectURI:        "app://callback",
		AgeConfirmedOver18: false,
	})
	if err == nil {
		t.Fatal("CompleteLinkedInOnboarding() returned nil error for age_confirmed_over_18=false, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
	if len(deps.users.createCalls) != 0 {
		t.Errorf("Create called %d times, want 0 — no account should be created when age isn't confirmed", len(deps.users.createCalls))
	}
}

func TestEmailSignupAndLogin_FullRoundTrip(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	startResp, err := svc.StartEmailSignup(context.Background(), StartVerificationRequest{
		Purpose: VerificationPurposeEmailSignup,
		Target:  "ada@example.com",
	})
	if err != nil {
		t.Fatalf("StartEmailSignup() error: %v", err)
	}
	if startResp.ResendAfterSeconds <= 0 {
		t.Error("ResendAfterSeconds <= 0, want positive")
	}
	code := deps.emailer.lastCode()
	if code == "" {
		t.Fatal("no OTP was dispatched")
	}

	signupResp, err := svc.CompleteEmailSignup(context.Background(), CompleteEmailSignupRequest{
		Email:              "ada@example.com",
		Code:               code,
		AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("CompleteEmailSignup() error: %v", err)
	}
	if !signupResp.IsNewUser {
		t.Error("IsNewUser = false, want true")
	}

	created := deps.users.byID[signupResp.UserID]
	if created.TrustLevel != 0 {
		t.Errorf("TrustLevel = %d, want 0 (email alone never grants Level 1)", created.TrustLevel)
	}

	// The same code must not be usable twice.
	if _, err := svc.CompleteEmailSignup(context.Background(), CompleteEmailSignupRequest{
		Email: "ada@example.com", Code: code, AgeConfirmedOver18: true,
	}); err == nil {
		t.Error("CompleteEmailSignup() with an already-consumed code returned nil error, want error")
	}

	// Passwordless login (ADR-019 §1): every return visit sends a fresh
	// code and verifies it — no stored credential to check.
	loginStartResp, err := svc.StartEmailLogin(context.Background(), StartVerificationRequest{
		Purpose: VerificationPurposeEmailLogin,
		Target:  "ada@example.com",
	})
	if err != nil {
		t.Fatalf("StartEmailLogin() error: %v", err)
	}
	if loginStartResp.ResendAfterSeconds <= 0 {
		t.Error("ResendAfterSeconds <= 0, want positive")
	}
	loginCode := deps.emailer.lastCode()
	if loginCode == "" {
		t.Fatal("no login OTP was dispatched")
	}

	loginResp, err := svc.CompleteEmailLogin(context.Background(), VerifyCodeRequest{
		Purpose: VerificationPurposeEmailLogin,
		Target:  "ada@example.com",
		Code:    loginCode,
	})
	if err != nil {
		t.Fatalf("CompleteEmailLogin() error: %v", err)
	}
	if loginResp.UserID != signupResp.UserID {
		t.Errorf("CompleteEmailLogin UserId = %q, want %q", loginResp.UserID, signupResp.UserID)
	}
}

func TestCompleteEmailLogin_RejectsWrongCodeAndUnknownEmailIdentically(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	existing, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})
	_, _ = deps.users.UpdatePersonalEmail(context.Background(), existing.ID, "ada@example.com", 0)

	if _, err := svc.StartEmailLogin(context.Background(), StartVerificationRequest{
		Purpose: VerificationPurposeEmailLogin, Target: "ada@example.com",
	}); err != nil {
		t.Fatalf("StartEmailLogin() error: %v", err)
	}

	_, wrongCodeErr := svc.CompleteEmailLogin(context.Background(), VerifyCodeRequest{
		Purpose: VerificationPurposeEmailLogin, Target: "ada@example.com", Code: "000000",
	})
	_, unknownEmailErr := svc.CompleteEmailLogin(context.Background(), VerifyCodeRequest{
		Purpose: VerificationPurposeEmailLogin, Target: "nobody@example.com", Code: "000000",
	})

	if wrongCodeErr == nil || unknownEmailErr == nil {
		t.Fatal("expected both wrong-code and unknown-email login attempts to fail")
	}
	if wrongCodeErr.Error() != unknownEmailErr.Error() {
		t.Errorf("error messages differ (%q vs %q) — must be identical to avoid leaking account existence",
			wrongCodeErr.Error(), unknownEmailErr.Error())
	}
	if !errors.Is(wrongCodeErr, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want it to wrap %v", wrongCodeErr, apperror.ErrUnauthorized)
	}
}

func TestLinkIdentity_LinkedInExchangeFails(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	defer server.Close()

	li := linkedin.New(linkedin.Config{ClientID: "cid", ClientSecret: "csecret"}, linkedin.WithTokenURL(server.URL))
	svc, deps := newFederatedTestService(t, func(d *testServiceDeps) { d.linkedin = li })
	user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

	_, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:            user.ID,
		Provider:          FederatedProviderLinkedIn,
		AuthorizationCode: "bad-code",
		RedirectURI:       "app://callback",
	})
	if err == nil {
		t.Fatal("LinkIdentity() returned nil error, want error")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

// TestLinkIdentity_LinkedInExchangeFailureDoesNotLeakUpstreamBody guards
// the security-review fix carried over from before ADR-014: LinkedIn's raw
// token-exchange error body must never reach the client-facing error
// message, even though it's embedded in the error linkedin.Client returns
// internally.
func TestLinkIdentity_LinkedInExchangeFailureDoesNotLeakUpstreamBody(t *testing.T) {
	const upstreamBody = `{"error":"invalid_grant","error_description":"the provided authorization grant is invalid, expired, revoked"}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(upstreamBody))
	}))
	defer server.Close()

	li := linkedin.New(linkedin.Config{ClientID: "cid", ClientSecret: "csecret"}, linkedin.WithTokenURL(server.URL))
	svc, deps := newFederatedTestService(t, func(d *testServiceDeps) { d.linkedin = li })
	user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

	_, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:            user.ID,
		Provider:          FederatedProviderLinkedIn,
		AuthorizationCode: "bad-code",
		RedirectURI:       "app://callback",
	})
	if err == nil {
		t.Fatal("LinkIdentity() returned nil error, want error")
	}

	msg := err.Error()
	if strings.Contains(msg, "invalid_grant") || strings.Contains(msg, "error_description") {
		t.Errorf("client-facing message leaked LinkedIn's raw response body: %q", msg)
	}
	const wantMsg = "linkedin sign-in failed, please try again: invalid input"
	if msg != wantMsg {
		t.Errorf("client-facing message = %q, want %q", msg, wantMsg)
	}
}

func TestRefreshSession(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	user, err := deps.users.Create(context.Background(), fakeNewUser("li-sub-123"))
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	rawToken, hash, err := newRefreshToken()
	if err != nil {
		t.Fatalf("newRefreshToken: %v", err)
	}
	seeded, err := deps.tokens.Create(context.Background(), user.ID, hash, time.Now().Add(RefreshTokenTTL))
	if err != nil {
		t.Fatalf("seed refresh token: %v", err)
	}

	resp, err := svc.RefreshSession(context.Background(), rawToken)
	if err != nil {
		t.Fatalf("RefreshSession() error: %v", err)
	}
	if resp.RefreshToken == rawToken {
		t.Error("RefreshSession returned the same raw refresh token, want a new one")
	}
	if resp.UserID != user.ID {
		t.Errorf("UserId = %q, want %q", resp.UserID, user.ID)
	}
	if resp.FullName != user.FullName {
		t.Errorf("FullName = %q, want %q", resp.FullName, user.FullName)
	}

	old := deps.tokens.byID[seeded.ID]
	if old.ReplacedBy == nil {
		t.Error("old refresh token row has no ReplacedBy set after rotation")
	}
}

func TestRefreshSession_RejectsAlreadyRotatedToken(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	user, _ := deps.users.Create(context.Background(), fakeNewUser("li-sub-123"))
	rawToken, hash, _ := newRefreshToken()
	seeded, _ := deps.tokens.Create(context.Background(), user.ID, hash, time.Now().Add(RefreshTokenTTL))

	replacedID := "already-replaced"
	seeded.ReplacedBy = &replacedID
	deps.tokens.byID[seeded.ID] = seeded
	deps.tokens.byHash[hash] = seeded

	_, err := svc.RefreshSession(context.Background(), rawToken)
	if err == nil {
		t.Fatal("RefreshSession() returned nil error for an already-rotated token, want error")
	}
	if !errors.Is(err, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want it to wrap %v", err, apperror.ErrUnauthorized)
	}
}

func TestRefreshSession_RejectsExpiredToken(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	user, _ := deps.users.Create(context.Background(), fakeNewUser("li-sub-123"))
	rawToken, hash, _ := newRefreshToken()
	_, _ = deps.tokens.Create(context.Background(), user.ID, hash, time.Now().Add(-time.Hour))

	_, err := svc.RefreshSession(context.Background(), rawToken)
	if err == nil {
		t.Fatal("RefreshSession() returned nil error for an expired token, want error")
	}
	if !errors.Is(err, apperror.ErrUnauthorized) {
		t.Errorf("error = %v, want it to wrap %v", err, apperror.ErrUnauthorized)
	}
}

func TestRefreshSession_UnknownTokenNotFound(t *testing.T) {
	svc, _ := newFederatedTestService(t)

	_, err := svc.RefreshSession(context.Background(), "never-issued")
	if err == nil {
		t.Fatal("RefreshSession() returned nil error for an unknown token, want error")
	}
	if !errors.Is(err, apperror.ErrNotFound) {
		t.Errorf("error = %v, want %v", err, apperror.ErrNotFound)
	}
}

func TestRevokeSession_IdempotentOnUnknownToken(t *testing.T) {
	svc, _ := newFederatedTestService(t)

	err := svc.RevokeSession(context.Background(), "never-issued")
	if err != nil {
		t.Fatalf("RevokeSession() on an unknown token returned error: %v", err)
	}
}

func TestRevokeSession_KnownToken(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	user, _ := deps.users.Create(context.Background(), fakeNewUser("li-sub-123"))
	rawToken, hash, _ := newRefreshToken()
	_, _ = deps.tokens.Create(context.Background(), user.ID, hash, time.Now().Add(RefreshTokenTTL))

	err := svc.RevokeSession(context.Background(), rawToken)
	if err != nil {
		t.Fatalf("RevokeSession() error: %v", err)
	}
	if deps.tokens.byHash[hash].RevokedAt == nil {
		t.Error("token was not marked revoked")
	}
}

func fakeNewUser(linkedInSub string) repository.NewUser {
	return repository.NewUser{LinkedInSub: linkedInSub, FullName: "Ada Lovelace", TrustLevel: 1}
}
