package auth

import (
	"context"
	"errors"
	"fmt"
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
	return newTestLinkedInServerNamed(t, "Ada Lovelace")
}

// newTestLinkedInServerNamed is newTestLinkedInServer with control over the
// name. The sub stays fixed, so a test that overrides deps.linkedin still
// links to the same li-sub-123 every other test in this file expects.
func newTestLinkedInServerNamed(t *testing.T, name string) (*linkedin.Client, func()) {
	t.Helper()
	return newTestLinkedInServerWith(t, name, "https://example.com/p.jpg")
}

// newTestLinkedInServerWith also varies the picture, for the photo-sync
// behaviour (the photo follows LinkedIn; the name only ever gets suggested).
// An empty picture stands for a LinkedIn response that omits the field.
func newTestLinkedInServerWith(t *testing.T, name, picture string) (*linkedin.Client, func()) {
	t.Helper()

	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"li-access-token","expires_in":5184000}`))
	})
	mux.HandleFunc("/userinfo", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"sub":"li-sub-123","name":"` + name + `","picture":"` + picture + `"}`))
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
	// CHANGED (ADR-002 §2): was 0, "no LinkedIn linked yet". A federated
	// signup is now worth Level 1 immediately; LinkedIn is still required to
	// climb to Level 2, which requireLinkedIn (unchanged) enforces.
	if created.TrustLevel != 1 {
		t.Errorf("new federated user's TrustLevel = %d, want 1 (ADR-002 §2)", created.TrustLevel)
	}
	if created.IsGuest {
		t.Error("IsGuest = true for a federated signup — only GuestSignup creates guests")
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
	// CHANGED (ADR-002 §2): was 0. Asserted on the Create call itself, not
	// just the stored row, so the value written at creation time is right
	// rather than corrected by a later recompute.
	if deps.users.createCalls[0].TrustLevel != 1 {
		t.Errorf("created user's TrustLevel = %d, want 1 (ADR-002 §2)", deps.users.createCalls[0].TrustLevel)
	}
	if deps.users.createCalls[0].IsGuest {
		t.Error("Create was called with IsGuest = true for a federated signup")
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
	// CHANGED (ADR-002 §2): was 0, "email alone never grants Level 1".
	if created.TrustLevel != 1 {
		t.Errorf("TrustLevel = %d, want 1 (email signup grants Level 1 immediately, ADR-002 §2)", created.TrustLevel)
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
	_, _ = deps.users.UpdatePersonalEmail(context.Background(), existing.ID, "ada@example.com", func(repository.User) int { return 0 })

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

// --- Plan 22: the provider's name at signup, and what a later LinkedIn
// link may and may not do with it. ---

// TestCompleteFederatedSignup_NameHintFillsAnEmptyVerifiedName is the Apple
// case this plan exists for: Apple's id_token carries no name claim at all,
// so verified.Name is empty, while its native SDK handed the client a name
// beside the token. Before Plan 22 that name was read and thrown away and
// the account was created nameless.
func TestCompleteFederatedSignup_NameHintFillsAnEmptyVerifiedName(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "apple-sub-123", Email: "grace@example.com", Name: "",
	}

	resp, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
		FullNameHint:       "  Grace Hopper  ", // trimmed, like the profile self-edit field
	})
	if err != nil {
		t.Fatalf("CompleteFederatedSignup() error: %v", err)
	}

	if resp.FullName != "Grace Hopper" {
		t.Errorf("session FullName = %q, want %q", resp.FullName, "Grace Hopper")
	}
	if created := deps.users.byID[resp.UserID]; created.FullName != "Grace Hopper" {
		t.Errorf("created user's FullName = %q, want %q", created.FullName, "Grace Hopper")
	}
	if got := deps.users.createCalls[0].FullName; got != "Grace Hopper" {
		t.Errorf("Create called with FullName = %q, want %q — the name must be written at creation, not patched afterwards", got, "Grace Hopper")
	}
}

// TestCompleteFederatedSignup_NoNameAnywhereStillCreatesTheAccount is the
// common Apple case on every authorization AFTER the first: Apple gives the
// client no name either, so there is nothing to fall back to. That is not an
// error — the account is created nameless exactly as before this plan, and
// the client renders its existing "Member" fallback.
func TestCompleteFederatedSignup_NoNameAnywhereStillCreatesTheAccount(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "apple-sub-456", Email: "anon@example.com", Name: "",
	}

	resp, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
		FullNameHint:       "",
	})
	if err != nil {
		t.Fatalf("CompleteFederatedSignup() error: %v", err)
	}
	if resp.FullName != "" {
		t.Errorf("session FullName = %q, want empty", resp.FullName)
	}
	if created := deps.users.byID[resp.UserID]; created.FullName != "" {
		t.Errorf("created user's FullName = %q, want empty", created.FullName)
	}
}

// TestCompleteFederatedSignup_VerifiedNameBeatsTheHint pins Google's
// behavior as unchanged. Google's id_token carries a signed `name` claim, so
// verified.Name is authoritative and a hint sent alongside it — by a buggy
// client, or a malicious one — is ignored outright rather than merged or
// preferred.
func TestCompleteFederatedSignup_VerifiedNameBeatsTheHint(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.google.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "google-sub-123", Email: "ada@example.com", Name: "Ada Lovelace",
	}

	resp, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderGoogle,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
		FullNameHint:       "Someone Else Entirely",
	})
	if err != nil {
		t.Fatalf("CompleteFederatedSignup() error: %v", err)
	}
	if resp.FullName != "Ada Lovelace" {
		t.Errorf("session FullName = %q, want the token's own %q", resp.FullName, "Ada Lovelace")
	}
	if created := deps.users.byID[resp.UserID]; created.FullName != "Ada Lovelace" {
		t.Errorf("created user's FullName = %q, want the token's own %q", created.FullName, "Ada Lovelace")
	}
}

// TestCompleteFederatedSignup_OverlongHintIsDroppedNotFatal covers the one
// deliberate difference between this field's validation and
// CompleteProfileSetup's: the same length rule applies (sanitizedNameHint),
// but a hint that breaks it is dropped rather than failing the signup. The
// user never typed this value, so it must not be able to cost them an
// account.
func TestCompleteFederatedSignup_OverlongHintIsDroppedNotFatal(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{Subject: "apple-sub-789"}

	resp, err := svc.CompleteFederatedSignup(context.Background(), CompleteFederatedSignupRequest{
		Provider:           FederatedProviderApple,
		IDToken:            "good-token",
		AgeConfirmedOver18: true,
		Nonce:              "test-nonce",
		FullNameHint:       strings.Repeat("a", maxFullNameLength+1),
	})
	if err != nil {
		t.Fatalf("CompleteFederatedSignup() error: %v — an unusable hint must not fail the signup", err)
	}
	if created := deps.users.byID[resp.UserID]; created.FullName != "" {
		t.Errorf("created user's FullName = %q, want empty — the oversized hint should be dropped", created.FullName)
	}
}

// TestLinkIdentity_LinkedInNameSuggestion covers the response half of the
// never-overwrite guarantee: LinkIdentity reports a difference, and reports
// nothing when there is none.
func TestLinkIdentity_LinkedInNameSuggestion(t *testing.T) {
	seedAndLink := func(t *testing.T, linkedInName, existingName string) SessionResult {
		t.Helper()
		svc, deps := newFederatedTestService(t, func(d *testServiceDeps) {
			li, closeLI := newTestLinkedInServerNamed(t, linkedInName)
			t.Cleanup(closeLI)
			d.linkedin = li
		})
		user, err := deps.users.Create(context.Background(), repository.NewUser{
			FullName: existingName, TrustLevel: 0, AgeConfirmedOver18: true,
		})
		if err != nil {
			t.Fatalf("seed user: %v", err)
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
		// Whatever the suggestion says, the stored name is untouched — the
		// point of the whole feature.
		if stored := deps.users.byID[user.ID].FullName; stored != existingName {
			t.Errorf("stored FullName = %q, want unchanged %q", stored, existingName)
		}
		return resp
	}

	t.Run("names differ: suggests LinkedIn's", func(t *testing.T) {
		resp := seedAndLink(t, "Grace Hopper", "Ada Lovelace")
		if resp.SuggestedNameUpdate != "Grace Hopper" {
			t.Errorf("SuggestedNameUpdate = %q, want %q", resp.SuggestedNameUpdate, "Grace Hopper")
		}
	})

	t.Run("names already match: suggests nothing", func(t *testing.T) {
		resp := seedAndLink(t, "Ada Lovelace", "Ada Lovelace")
		if resp.SuggestedNameUpdate != "" {
			t.Errorf("SuggestedNameUpdate = %q, want empty when the names agree", resp.SuggestedNameUpdate)
		}
	})

	t.Run("linkedin has no name: suggests nothing", func(t *testing.T) {
		resp := seedAndLink(t, "", "Ada Lovelace")
		if resp.SuggestedNameUpdate != "" {
			t.Errorf("SuggestedNameUpdate = %q, want empty when LinkedIn returned no name", resp.SuggestedNameUpdate)
		}
	})

	t.Run("account has no name yet: still only suggests, never applies", func(t *testing.T) {
		resp := seedAndLink(t, "Grace Hopper", "")
		if resp.SuggestedNameUpdate != "Grace Hopper" {
			t.Errorf("SuggestedNameUpdate = %q, want %q", resp.SuggestedNameUpdate, "Grace Hopper")
		}
	})
}

// TestLinkIdentity_AppleAndGoogleNeverSuggestAName: the suggestion is the
// LinkedIn branch's alone. Apple/Google linking verifies an id_token and has
// no userinfo call to learn a name from in the first place.
func TestLinkIdentity_AppleAndGoogleNeverSuggestAName(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	deps.apple.validTokens["good-token"] = identity.VerifiedIdentity{
		Subject: "apple-sub-link", Name: "Grace Hopper",
	}
	user, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: "Ada Lovelace", TrustLevel: 0, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	resp, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:   user.ID,
		Provider: FederatedProviderApple,
		IDToken:  "good-token",
		Nonce:    "test-nonce",
	})
	if err != nil {
		t.Fatalf("LinkIdentity() error: %v", err)
	}
	if resp.SuggestedNameUpdate != "" {
		t.Errorf("SuggestedNameUpdate = %q, want empty on the Apple/Google branch", resp.SuggestedNameUpdate)
	}
	if stored := deps.users.byID[user.ID].FullName; stored != "Ada Lovelace" {
		t.Errorf("stored FullName = %q, want unchanged %q", stored, "Ada Lovelace")
	}
}

// --- The profile photo follows LinkedIn (2026-09-26). ---

// seedAndLinkLinkedIn links li-sub-123 to a fresh user carrying the given
// name and photo, with LinkedIn answering with linkedInName/linkedInPhoto.
func seedAndLinkLinkedIn(t *testing.T, existingName, existingPhoto, linkedInName, linkedInPhoto string) (repository.User, SessionResult, *testServiceDeps) {
	t.Helper()
	svc, deps := newFederatedTestService(t, func(d *testServiceDeps) {
		li, closeLI := newTestLinkedInServerWith(t, linkedInName, linkedInPhoto)
		t.Cleanup(closeLI)
		d.linkedin = li
	})
	user, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: existingName, ProfilePhotoURL: existingPhoto,
		TrustLevel: 0, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed user: %v", err)
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
	return deps.users.byID[user.ID], resp, deps
}

// TestLinkIdentity_LinkedIn_GivesAnApplePhotolessAccountItsPhoto is the case
// this feature exists for: someone signs up with Apple or Google (no photo —
// Apple issues none, and this app deliberately does not take Google's), then
// connects LinkedIn. Their professional photo was already in the userinfo
// response the link flow fetches; before this it was read and dropped, and
// they kept initials forever.
func TestLinkIdentity_LinkedIn_GivesAnApplePhotolessAccountItsPhoto(t *testing.T) {
	stored, resp, _ := seedAndLinkLinkedIn(t,
		"Ada Lovelace", "", "Ada Lovelace", "https://media.licdn.com/ada.jpg")

	if stored.ProfilePhotoURL != "https://media.licdn.com/ada.jpg" {
		t.Errorf("stored photo = %q, want LinkedIn's", stored.ProfilePhotoURL)
	}
	// The session carries it immediately, so the app shows the avatar without
	// waiting for a later profile refetch.
	if resp.ProfilePhotoURL != "https://media.licdn.com/ada.jpg" {
		t.Errorf("session photo = %q, want LinkedIn's", resp.ProfilePhotoURL)
	}
}

// TestLinkIdentity_LinkedIn_PhotoIsSyncedButNameIsOnlySuggested pins the
// asymmetry that makes this safe. Both fields differ from the account's; the
// photo is written, the name is not — it comes back as a suggestion for the
// user to accept or decline (Plan 22).
func TestLinkIdentity_LinkedIn_PhotoIsSyncedButNameIsOnlySuggested(t *testing.T) {
	stored, resp, _ := seedAndLinkLinkedIn(t,
		"Ada Lovelace", "https://old.example.com/old.jpg",
		"Grace Hopper", "https://media.licdn.com/grace.jpg")

	if stored.ProfilePhotoURL != "https://media.licdn.com/grace.jpg" {
		t.Errorf("photo = %q, want LinkedIn's — the photo follows LinkedIn", stored.ProfilePhotoURL)
	}
	if stored.FullName != "Ada Lovelace" {
		t.Errorf("FullName = %q, want unchanged — linking must never rename the user", stored.FullName)
	}
	if resp.SuggestedNameUpdate != "Grace Hopper" {
		t.Errorf("SuggestedNameUpdate = %q, want LinkedIn's name offered", resp.SuggestedNameUpdate)
	}
}

// TestLinkIdentity_LinkedIn_MissingPictureLeavesTheExistingPhotoAlone: a
// LinkedIn response with no picture must not blank a photo the account
// already has. Losing one because the provider omitted a field would be
// strictly worse than keeping a stale one.
func TestLinkIdentity_LinkedIn_MissingPictureLeavesTheExistingPhotoAlone(t *testing.T) {
	stored, _, deps := seedAndLinkLinkedIn(t,
		"Ada Lovelace", "https://old.example.com/old.jpg", "Ada Lovelace", "")

	if stored.ProfilePhotoURL != "https://old.example.com/old.jpg" {
		t.Errorf("photo = %q, want the existing one kept", stored.ProfilePhotoURL)
	}
	if len(deps.users.photoUpdates) != 0 {
		t.Errorf("photo writes = %d, want 0 for an empty incoming picture", len(deps.users.photoUpdates))
	}
}

// TestLinkIdentity_LinkedIn_UnchangedPhotoIsNotRewritten: the write publishes
// a user-profile-updated event the meetup module consumes to refresh its
// display cache, so a no-op write is real wasted work downstream.
func TestLinkIdentity_LinkedIn_UnchangedPhotoIsNotRewritten(t *testing.T) {
	same := "https://media.licdn.com/ada.jpg"
	stored, _, deps := seedAndLinkLinkedIn(t, "Ada Lovelace", same, "Ada Lovelace", same)

	if stored.ProfilePhotoURL != same {
		t.Errorf("photo = %q, want %q", stored.ProfilePhotoURL, same)
	}
	if len(deps.users.photoUpdates) != 0 {
		t.Errorf("photo writes = %d, want 0 when the photo has not changed", len(deps.users.photoUpdates))
	}
}

// TestCompleteLinkedInOnboarding_ReturningUserPicksUpAChangedPhoto is the
// other half of "changed on LinkedIn, changed here": a LinkedIn signup who
// swaps their photo there gets it mirrored on their next sign-in, rather than
// keeping the one captured at account creation forever.
func TestCompleteLinkedInOnboarding_ReturningUserPicksUpAChangedPhoto(t *testing.T) {
	svc, deps := newFederatedTestService(t, func(d *testServiceDeps) {
		li, closeLI := newTestLinkedInServerWith(t, "Ada Lovelace", "https://media.licdn.com/first.jpg")
		t.Cleanup(closeLI)
		d.linkedin = li
	})
	first, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "auth-code", RedirectURI: "app://callback", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("first onboarding: %v", err)
	}
	if got := deps.users.byID[first.UserID].ProfilePhotoURL; got != "https://media.licdn.com/first.jpg" {
		t.Fatalf("photo at creation = %q, want the first one", got)
	}

	// They change it on LinkedIn, then sign in again.
	li2, close2 := newTestLinkedInServerWith(t, "Ada Lovelace", "https://media.licdn.com/second.jpg")
	t.Cleanup(close2)
	svc.linkedin = li2

	second, err := svc.CompleteLinkedInOnboarding(context.Background(), CompleteLinkedInOnboardingRequest{
		AuthorizationCode: "auth-code", RedirectURI: "app://callback", AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("second onboarding: %v", err)
	}
	if second.UserID != first.UserID {
		t.Fatalf("second sign-in made a new account: %q vs %q", second.UserID, first.UserID)
	}
	if got := deps.users.byID[first.UserID].ProfilePhotoURL; got != "https://media.licdn.com/second.jpg" {
		t.Errorf("photo after re-login = %q, want the updated one", got)
	}
	if second.ProfilePhotoURL != "https://media.licdn.com/second.jpg" {
		t.Errorf("session photo = %q, want the updated one", second.ProfilePhotoURL)
	}
}

// --- Account deletion (App Store 5.1.1(v), Play data-deletion). ---
//
// The auth service's share of deletion is its own data only. The meetup
// module is never called from here: it hears about the deletion through the
// user-deleted outbox row the repository writes in the same transaction
// (covered by the Postgres-backed integration test), and the "not while you
// have a live meetup" rule is asked of the meetup service by the gateway.

func seedDeletable(t *testing.T) (*service, *testServiceDeps, string) {
	t.Helper()
	svc, deps := newFederatedTestService(t)
	user, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: "Ada Lovelace", TrustLevel: 1, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return svc, deps, user.ID
}

func TestDeleteAccount_RemovesTheAccount(t *testing.T) {
	svc, deps, userID := seedDeletable(t)

	if err := svc.DeleteAccount(context.Background(), userID); err != nil {
		t.Fatalf("DeleteAccount() error: %v", err)
	}
	if _, ok := deps.users.byID[userID]; ok {
		t.Error("the account still exists after deletion")
	}
	if len(deps.users.deleted) != 1 || deps.users.deleted[0] != userID {
		t.Errorf("Delete calls = %v, want exactly this user once", deps.users.deleted)
	}
}

// TestDeleteAccount_IsIdempotent: deleting an account that is already gone
// SUCCEEDS. The id comes from a verified JWT, so the only ways to arrive here
// with no row are a retry after the first call worked (a dropped response, a
// double tap) or a token that outlived its account. Both mean "my account is
// deleted"; erroring would turn a completed deletion into a visible failure.
func TestDeleteAccount_IsIdempotent(t *testing.T) {
	svc, deps, userID := seedDeletable(t)

	if err := svc.DeleteAccount(context.Background(), userID); err != nil {
		t.Fatalf("first DeleteAccount() error: %v", err)
	}
	if err := svc.DeleteAccount(context.Background(), userID); err != nil {
		t.Fatalf("second DeleteAccount() error: %v, a repeat must succeed", err)
	}
	if len(deps.users.deleted) != 1 {
		t.Errorf("Delete called %d times, want 1: the repeat must not try again", len(deps.users.deleted))
	}
}

// TestDeleteAccount_ConcurrentDeleteIsNotAnError: two devices, one tap each.
// The loser finds the row gone between its read and its delete; it has still
// got exactly what it asked for.
func TestDeleteAccount_ConcurrentDeleteIsNotAnError(t *testing.T) {
	svc, deps, userID := seedDeletable(t)
	deps.users.deleteErr = fmt.Errorf("fake: %w", apperror.ErrNotFound)

	if err := svc.DeleteAccount(context.Background(), userID); err != nil {
		t.Errorf("DeleteAccount() error = %v, want nil when a concurrent delete won", err)
	}
}

// TestDeleteAccount_RealFailuresPropagate: idempotent must not decay into
// "always returns nil". A database failure has to reach the caller, or the
// app would tell someone their account is gone when it is not.
func TestDeleteAccount_RealFailuresPropagate(t *testing.T) {
	svc, deps, userID := seedDeletable(t)
	deps.users.deleteErr = errors.New("repository: delete user: connection reset")

	if err := svc.DeleteAccount(context.Background(), userID); err == nil {
		t.Fatal("DeleteAccount() returned nil for a real failure")
	}
	if _, ok := deps.users.byID[userID]; !ok {
		t.Error("the account was removed even though the delete failed")
	}
}
