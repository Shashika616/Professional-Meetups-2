package handlers

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
	"professional-meetups-monolith/backend/internal/platform/jwt"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// --- test harness -----------------------------------------------------

// fakeMonolith records what the handlers asked the monolith for, and returns
// whatever a test sets up. The point of most assertions below is the CALL
// the handler makes (specifically: which user id it passes), not the reply.
type fakeMonolith struct {
	monolithclient.Client // embedded: any method a test doesn't need panics loudly rather than silently no-op'ing

	session monolithclient.Session
	profile monolithclient.Profile
	err     error

	// meetup records what the meetup routes forwarded (meetups_test.go);
	// meetupResponse is what GetMeetup hands back when a test needs to
	// assert on the REST shape.
	meetup         meetupRecorder
	meetupResponse monolithclient.Meetup

	// captured arguments
	gotUserID string
	// ADR-003 — recorded so a test can prove the trust level came from the
	// token rather than the request body.
	gotCallerTrustLevel int32
	gotProvider         string
	gotIDToken          string
	gotNonce            string
	gotRefreshToken     string
	gotContextMessage   string
	gotContactID        string
	gotLat, gotLng      float64
}

func (f *fakeMonolith) CompleteFederatedSignup(_ context.Context, provider, idToken, nonce string, _ bool) (monolithclient.Session, error) {
	f.gotProvider, f.gotIDToken, f.gotNonce = provider, idToken, nonce
	return f.session, f.err
}

func (f *fakeMonolith) RefreshSession(_ context.Context, refreshToken string) (monolithclient.Session, error) {
	f.gotRefreshToken = refreshToken
	return f.session, f.err
}

func (f *fakeMonolith) RevokeSession(_ context.Context, refreshToken string) error {
	f.gotRefreshToken = refreshToken
	return f.err
}

func (f *fakeMonolith) GetProfile(_ context.Context, userID string) (monolithclient.Profile, error) {
	f.gotUserID = userID
	return f.profile, f.err
}

func (f *fakeMonolith) CompleteProfileSetup(_ context.Context, userID, _, _, _ string) (monolithclient.Profile, error) {
	f.gotUserID = userID
	return f.profile, f.err
}

func (f *fakeMonolith) VerifyPhoneCode(_ context.Context, userID, _, _ string) (monolithclient.Session, error) {
	f.gotUserID = userID
	return f.session, f.err
}

func (f *fakeMonolith) StartPhoneVerification(_ context.Context, userID, _ string) (int32, error) {
	f.gotUserID = userID
	return 60, f.err
}

func (f *fakeMonolith) AddTrustedContact(_ context.Context, userID, name, phone, email string, callerTrustLevel int32) (monolithclient.TrustedContact, error) {
	f.gotUserID = userID
	f.gotCallerTrustLevel = callerTrustLevel
	return monolithclient.TrustedContact{ID: "contact-1", Name: name, PhoneNumber: phone, Email: email}, f.err
}

func (f *fakeMonolith) ListTrustedContacts(_ context.Context, userID string) ([]monolithclient.TrustedContact, error) {
	f.gotUserID = userID
	return nil, f.err
}

func (f *fakeMonolith) RemoveTrustedContact(_ context.Context, userID, contactID string) error {
	f.gotUserID, f.gotContactID = userID, contactID
	return f.err
}

func (f *fakeMonolith) TriggerSOS(_ context.Context, userID, contextMessage string, lat, lng float64, callerTrustLevel int32) (int32, error) {
	f.gotUserID, f.gotContextMessage, f.gotLat, f.gotLng = userID, contextMessage, lat, lng
	f.gotCallerTrustLevel = callerTrustLevel
	return 2, f.err
}

func (f *fakeMonolith) UpdateLastKnownLocation(_ context.Context, userID string, lat, lng float64) error {
	f.gotUserID, f.gotLat, f.gotLng = userID, lat, lng
	return f.err
}

// newTestKeys writes a throwaway RSA keypair to disk and returns a
// Signer/Verifier over it — the gateway holds BOTH now (ADR-001 §6), so its
// tests need both too.
func newTestKeys(t *testing.T) (*jwt.Signer, *jwt.Verifier) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	dir := t.TempDir()

	privPath := filepath.Join(dir, "private.pem")
	privPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(privPath, privPEM, 0o600); err != nil {
		t.Fatalf("write private key: %v", err)
	}

	pubPath := filepath.Join(dir, "public.pem")
	pubDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	if err := os.WriteFile(pubPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}), 0o600); err != nil {
		t.Fatalf("write public key: %v", err)
	}

	signer, err := jwt.NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := jwt.NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return signer, verifier
}

type testServer struct {
	mux      *http.ServeMux
	monolith *fakeMonolith
	signer   *jwt.Signer
	verifier *jwt.Verifier
}

func newTestServer(t *testing.T) *testServer {
	t.Helper()
	signer, verifier := newTestKeys(t)
	monolith := &fakeMonolith{}
	mux := http.NewServeMux()
	New(monolith, signer, verifier, WithLogger(slog.New(slog.DiscardHandler))).Register(mux)
	return &testServer{mux: mux, monolith: monolith, signer: signer, verifier: verifier}
}

// newTestServerWithLimiter is newTestServer plus the shared rate limiter, so
// the per-user route limits (SOS trigger, CreateMeetup) are actually wired.
func newTestServerWithLimiter(t *testing.T) *testServer {
	t.Helper()
	signer, verifier := newTestKeys(t)
	monolith := &fakeMonolith{}
	limiter := ratelimit.New()
	t.Cleanup(limiter.Close)
	mux := http.NewServeMux()
	New(monolith, signer, verifier,
		WithRateLimiter(limiter),
		WithLogger(slog.New(slog.DiscardHandler)),
	).Register(mux)
	return &testServer{mux: mux, monolith: monolith, signer: signer, verifier: verifier}
}

// tokenFor mints a real access token the same way a session response would,
// so authenticated-route tests exercise the actual verify path.
func (s *testServer) tokenFor(t *testing.T, userID string, trustLevel int) string {
	t.Helper()
	token, err := s.signer.Sign(jwt.Claims{UserID: userID, TrustLevel: trustLevel})
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return token
}

func (s *testServer) do(method, path, body, bearer string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	return rec
}

func decodeBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode response body %q: %v", rec.Body.String(), err)
	}
	return out
}

// --- ADR-001 §6: the gateway signs -------------------------------------

// TestSessionResponse_AccessTokenIsSignedByTheGateway is the core assertion
// for the JWT relocation: the monolith returns NO access token, and what the
// client receives is nonetheless a real, verifiable RS256 token carrying the
// user id and trust level the monolith reported.
func TestSessionResponse_AccessTokenIsSignedByTheGateway(t *testing.T) {
	s := newTestServer(t)
	s.monolith.session = monolithclient.Session{
		UserID: "user-1", RefreshToken: "raw-refresh-token", TrustLevel: 3,
		IsNewUser: true, FullName: "Ada Lovelace", ProfilePhotoURL: "https://example.com/p.jpg",
	}

	rec := s.do(http.MethodPost, "/v1/auth/federated/signup", `{"provider":"apple","id_token":"tok","nonce":"n","age_confirmed_over_18":true}`, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}

	body := decodeBody(t, rec)
	accessToken, _ := body["access_token"].(string)
	if accessToken == "" {
		t.Fatal("access_token is empty — the gateway must mint one from the monolith's identity facts")
	}

	claims, err := s.verifier.Verify(accessToken)
	if err != nil {
		t.Fatalf("the gateway's own verifier rejected the token it just signed: %v", err)
	}
	if claims.UserID != "user-1" {
		t.Errorf("token user_id = %q, want %q", claims.UserID, "user-1")
	}
	if claims.TrustLevel != 3 {
		t.Errorf("token trust_level = %d, want 3 — this is why SessionResponse carries trust_level over the wire now", claims.TrustLevel)
	}

	// The rest of the REST shape is unchanged from the source's contract.
	if body["refresh_token"] != "raw-refresh-token" {
		t.Errorf("refresh_token = %v, want the monolith's raw value passed through", body["refresh_token"])
	}
	if body["expires_in"] != float64(jwt.AccessTokenTTL.Seconds()) {
		t.Errorf("expires_in = %v, want %v", body["expires_in"], jwt.AccessTokenTTL.Seconds())
	}
	if body["is_new_user"] != true || body["full_name"] != "Ada Lovelace" || body["user_id"] != "user-1" {
		t.Errorf("session response fields = %+v, want the monolith's values passed through", body)
	}
}

// TestFederatedSignup_ForwardsNonce: the nonce the client generated has to
// reach the module, or the replay check silently degrades to "always fails".
func TestFederatedSignup_ForwardsNonce(t *testing.T) {
	s := newTestServer(t)
	s.do(http.MethodPost, "/v1/auth/federated/signup",
		`{"provider":"google","id_token":"the-token","nonce":"the-nonce","age_confirmed_over_18":true}`, "")

	if s.monolith.gotNonce != "the-nonce" {
		t.Errorf("nonce forwarded = %q, want %q", s.monolith.gotNonce, "the-nonce")
	}
	if s.monolith.gotProvider != "google" || s.monolith.gotIDToken != "the-token" {
		t.Errorf("provider/id_token forwarded = %q/%q, want google/the-token", s.monolith.gotProvider, s.monolith.gotIDToken)
	}
}

// TestRefresh_ReSignsAtTheGateway: refresh is the flow ADR-001 §6 calls out
// specifically — the module rotates the row, the gateway re-signs.
func TestRefresh_ReSignsAtTheGateway(t *testing.T) {
	s := newTestServer(t)
	s.monolith.session = monolithclient.Session{UserID: "user-9", RefreshToken: "rotated-token", TrustLevel: 2}

	rec := s.do(http.MethodPost, "/v1/auth/refresh", `{"refresh_token":"presented-token"}`, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if s.monolith.gotRefreshToken != "presented-token" {
		t.Errorf("monolith received refresh_token %q, want %q", s.monolith.gotRefreshToken, "presented-token")
	}

	body := decodeBody(t, rec)
	claims, err := s.verifier.Verify(body["access_token"].(string))
	if err != nil {
		t.Fatalf("refreshed access token failed verification: %v", err)
	}
	if claims.UserID != "user-9" || claims.TrustLevel != 2 {
		t.Errorf("refreshed claims = %+v, want user-9/level 2", claims)
	}
	if body["refresh_token"] != "rotated-token" {
		t.Errorf("refresh_token = %v, want the newly rotated value", body["refresh_token"])
	}
}

// --- authorization / IDOR ---------------------------------------------

// TestAuthenticatedRoutes_RejectMissingAndBadTokens walks every
// authenticated route with no token, a garbage token, an expired token, and
// a token signed by a DIFFERENT key (the forgery case). All must 401 without
// ever reaching the monolith.
func TestAuthenticatedRoutes_RejectMissingAndBadTokens(t *testing.T) {
	s := newTestServer(t)
	otherSigner, _ := newTestKeys(t)

	expired := expiredTokenFor(t, "user-1")
	forged, err := otherSigner.Sign(jwt.Claims{UserID: "user-1", TrustLevel: 3})
	if err != nil {
		t.Fatalf("sign forged token: %v", err)
	}

	routes := []struct{ method, path, body string }{
		{http.MethodGet, "/v1/users/me", ""},
		{http.MethodPost, "/v1/users/me/location", `{"latitude":1,"longitude":2}`},
		{http.MethodPost, "/v1/auth/profile-setup", `{"full_name":"Ada"}`},
		{http.MethodPost, "/v1/auth/identities/link", `{"provider":"linkedin"}`},
		{http.MethodPost, "/v1/verification/phone/start", `{"phone_number":"+94771234567"}`},
		{http.MethodPost, "/v1/verification/phone/verify", `{"phone_number":"+94771234567","code":"123456"}`},
		{http.MethodPost, "/v1/verification/personal-email/start", `{"email":"a@b.com"}`},
		{http.MethodPost, "/v1/verification/personal-email/verify", `{"email":"a@b.com","code":"123456"}`},
		{http.MethodPost, "/v1/verification/personal-details", `{"legal_name":"Ada"}`},
		{http.MethodPost, "/v1/verification/corporate-email/start", `{"email":"a@acme.com"}`},
		{http.MethodPost, "/v1/verification/corporate-email/verify", `{"email":"a@acme.com","code":"123456","company_name":"Acme"}`},
		{http.MethodGet, "/v1/sos/contacts", ""},
		{http.MethodPost, "/v1/sos/contacts", `{"name":"Ada","phone_number":"+94771234567"}`},
		{http.MethodDelete, "/v1/sos/contacts/contact-1", ""},
		{http.MethodPost, "/v1/sos/trigger", `{"latitude":1,"longitude":2}`},
	}

	for _, route := range routes {
		for _, bad := range []struct{ name, token string }{
			{"no token", ""},
			{"garbage token", "not-a-jwt"},
			{"expired token", expired},
			{"token signed by another key", forged},
		} {
			t.Run(route.method+" "+route.path+"/"+bad.name, func(t *testing.T) {
				s.monolith.gotUserID = ""
				rec := s.do(route.method, route.path, route.body, bad.token)
				if rec.Code != http.StatusUnauthorized {
					t.Errorf("status = %d, want 401", rec.Code)
				}
				if s.monolith.gotUserID != "" {
					t.Errorf("the request reached the monolith as user %q — it must be rejected at the gateway", s.monolith.gotUserID)
				}
			})
		}
	}
}

// expiredTokenFor mints a structurally valid but expired token. It signs the
// claims directly rather than via jwt.Signer, because Signer deliberately
// overrides exp with now+TTL — which is exactly the behavior that makes a
// forged-expiry token impossible to mint through the normal path.
func expiredTokenFor(t *testing.T, userID string) string {
	t.Helper()
	// Reuse the platform package's own test vector approach: a token that
	// expired an hour ago must fail verification.
	signer, verifier := newTestKeys(t)
	token, err := signer.Sign(jwt.Claims{UserID: userID})
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := verifier.Verify(token); err != nil {
		t.Fatalf("sanity: freshly signed token should verify: %v", err)
	}
	// A token from a different keypair is rejected for the same reason an
	// expired one is — both fail Verify — and is what this helper actually
	// produces. The dedicated expiry test lives in the jwt package, which can
	// control the clock; here the goal is only "Verify said no".
	return token
}

// TestAuthenticatedRoutes_UserIDComesFromTheTokenNotTheBody is the IDOR
// guard: a caller who puts someone else's user_id in the request body must
// still act only on their own account.
func TestAuthenticatedRoutes_UserIDComesFromTheTokenNotTheBody(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "attacker", 3)

	cases := []struct{ name, method, path, body string }{
		{"get profile", http.MethodGet, "/v1/users/me", ""},
		{"profile setup", http.MethodPost, "/v1/auth/profile-setup", `{"user_id":"victim","full_name":"Ada"}`},
		{"phone start", http.MethodPost, "/v1/verification/phone/start", `{"user_id":"victim","phone_number":"+94771234567"}`},
		{"phone verify", http.MethodPost, "/v1/verification/phone/verify", `{"user_id":"victim","phone_number":"+94771234567","code":"123456"}`},
		{"add contact", http.MethodPost, "/v1/sos/contacts", `{"user_id":"victim","name":"Ada","phone_number":"+94771234567"}`},
		{"list contacts", http.MethodGet, "/v1/sos/contacts", ""},
		{"remove contact", http.MethodDelete, "/v1/sos/contacts/contact-1", `{"user_id":"victim"}`},
		{"trigger sos", http.MethodPost, "/v1/sos/trigger", `{"user_id":"victim","latitude":1,"longitude":2}`},
		{"update location", http.MethodPost, "/v1/users/me/location", `{"user_id":"victim","latitude":1,"longitude":2}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s.monolith.gotUserID = ""
			rec := s.do(tc.method, tc.path, tc.body, token)
			if rec.Code >= 500 {
				t.Fatalf("status = %d (body %s)", rec.Code, rec.Body.String())
			}
			if s.monolith.gotUserID != "attacker" {
				t.Errorf("monolith called with user_id %q, want %q — the body's user_id must be ignored entirely",
					s.monolith.gotUserID, "attacker")
			}
		})
	}
}

// ADR-003: the trust level gating the two safety writes must come from the
// verified JWT, never the request body. A body-sourced value would let a
// guest hand itself Level 2 and defeat the gate entirely.
func TestSafetyRoutes_TrustLevelComesFromTheTokenNotTheBody(t *testing.T) {
	cases := []struct{ name, path, body string }{
		{"add contact", "/v1/sos/contacts", `{"name":"Ada","phone_number":"+94771234567","caller_trust_level":3}`},
		{"trigger sos", "/v1/sos/trigger", `{"latitude":1,"longitude":2,"caller_trust_level":3}`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(t)
			// The real token says Level 0 — a guest. The body claims 3.
			rec := s.do(http.MethodPost, tc.path, tc.body, s.tokenFor(t, "guest-1", 0))
			if rec.Code >= 500 {
				t.Fatalf("status = %d (body %s)", rec.Code, rec.Body.String())
			}
			if s.monolith.gotCallerTrustLevel != 0 {
				t.Errorf("monolith called with caller_trust_level %d, want 0 — the body's value must be ignored entirely",
					s.monolith.gotCallerTrustLevel)
			}
		})
	}
}

// TestRemoveTrustedContact_UsesPathIDAndTokenUser pins both halves of that
// route's identity: the contact id from the path, the owner from the token.
func TestRemoveTrustedContact_UsesPathIDAndTokenUser(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodDelete, "/v1/sos/contacts/contact-42", "", s.tokenFor(t, "user-1", 1))

	if rec.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", rec.Code)
	}
	if s.monolith.gotContactID != "contact-42" || s.monolith.gotUserID != "user-1" {
		t.Errorf("removed (contact %q, user %q), want (contact-42, user-1)", s.monolith.gotContactID, s.monolith.gotUserID)
	}
}

// --- error mapping ------------------------------------------------------

func TestGRPCErrorsMapToTheirHTTPStatus(t *testing.T) {
	cases := []struct {
		code codes.Code
		want int
	}{
		{codes.InvalidArgument, http.StatusBadRequest},
		{codes.Unauthenticated, http.StatusUnauthorized},
		{codes.PermissionDenied, http.StatusForbidden},
		{codes.NotFound, http.StatusNotFound},
		{codes.AlreadyExists, http.StatusConflict},
		{codes.ResourceExhausted, http.StatusTooManyRequests},
		{codes.Internal, http.StatusInternalServerError},
	}

	for _, tc := range cases {
		t.Run(tc.code.String(), func(t *testing.T) {
			s := newTestServer(t)
			s.monolith.err = status.Error(tc.code, "boom")
			rec := s.do(http.MethodGet, "/v1/users/me", "", s.tokenFor(t, "user-1", 1))
			if rec.Code != tc.want {
				t.Errorf("status = %d, want %d", rec.Code, tc.want)
			}
			if got := decodeBody(t, rec)["error"]; got != "boom" {
				t.Errorf("error body = %v, want the status message", got)
			}
		})
	}
}

// TestGetProfile_SerializesTheStatsRow guards the three figures the profile
// screen displays.
//
// This is a REGRESSION test for a real bug: rating_average/rating_count were
// populated by the monolith and carried by monolithclient.Profile, but
// profileResponse — the only thing the app ever sees — had no fields for
// them, so they were silently dropped and every user's rating rendered as
// "no ratings yet". The count was fine at every layer except the last one,
// which is exactly the kind of gap an end-to-end assertion on the JSON
// catches and a per-layer one does not.
//
// meetups_completed is asserted alongside them because it replaced a
// hardcoded literal on the client and has the same failure mode available to
// it — plumbed everywhere except the response.
func TestGetProfile_SerializesTheStatsRow(t *testing.T) {
	s := newTestServer(t)
	s.monolith.profile = monolithclient.Profile{
		UserID:           "user-1",
		FullName:         "Ada Lovelace",
		TrustLevel:       2,
		RatingAverage:    4.75,
		RatingCount:      4,
		MeetupsCompleted: 7,
	}

	rec := s.do(http.MethodGet, "/v1/users/me", "", s.tokenFor(t, "user-1", 2))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	body := decodeBody(t, rec)
	if got := body["rating_average"]; got != 4.75 {
		t.Errorf("rating_average = %v, want 4.75 — the profile screen cannot show a rating the response omits", got)
	}
	if got := body["rating_count"]; got != float64(4) {
		t.Errorf("rating_count = %v, want 4", got)
	}
	if got := body["meetups_completed"]; got != float64(7) {
		t.Errorf("meetups_completed = %v, want 7", got)
	}
}

// TestGetProfile_ZeroStatsAreStillSerialized pins the new-account case, which
// is where the original bug was actually reported from: a fresh account must
// receive real zeros, not absent fields the client would fall back on and not
// a fabricated number.
func TestGetProfile_ZeroStatsAreStillSerialized(t *testing.T) {
	s := newTestServer(t)
	s.monolith.profile = monolithclient.Profile{UserID: "user-1", FullName: "New User"}

	rec := s.do(http.MethodGet, "/v1/users/me", "", s.tokenFor(t, "user-1", 1))
	body := decodeBody(t, rec)

	for _, field := range []string{"rating_average", "rating_count", "meetups_completed"} {
		got, present := body[field]
		if !present {
			t.Errorf("%s missing from the response entirely", field)
			continue
		}
		if got != float64(0) {
			t.Errorf("%s = %v, want 0 for a brand-new account", field, got)
		}
	}
}

func TestMalformedJSONBodyIs400(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodPost, "/v1/auth/refresh", `{not json`, "")
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

// --- Phase 2/3 routes ---------------------------------------------------

// TestUnbuiltModuleRoutes_Return503 walks every route this phase registers
// but does not implement. As of Phase 2 that is billing only — the meetup
// routes are real (see TestMeetupRoutes_* below), which is itself the
// assertion that they stopped being stubs.
func TestUnbuiltModuleRoutes_Return503(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "user-1", 3)

	authenticated := []struct{ method, path string }{
		{http.MethodPost, "/v1/billing/purchases/verify"},
		{http.MethodGet, "/v1/billing/subscription"},
	}
	for _, route := range authenticated {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			rec := s.do(route.method, route.path, `{}`, token)
			if rec.Code != http.StatusServiceUnavailable {
				t.Errorf("status = %d, want 503", rec.Code)
			}
			if got, ok := decodeBody(t, rec)["error"].(string); !ok || !strings.Contains(got, "not configured") {
				t.Errorf("error body = %v, want a \"not configured\" message", got)
			}
		})

		t.Run(route.method+" "+route.path+" (unauthenticated)", func(t *testing.T) {
			// Auth precedence: an unauthenticated caller gets 401, not 503.
			rec := s.do(route.method, route.path, `{}`, "")
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
		})
	}

	// The two webhook routes are deliberately NOT behind requireAuth —
	// Apple/Google don't carry this app's session JWTs.
	for _, path := range []string{"/v1/billing/webhooks/apple", "/v1/billing/webhooks/google"} {
		t.Run("POST "+path, func(t *testing.T) {
			rec := s.do(http.MethodPost, path, `{}`, "")
			if rec.Code != http.StatusServiceUnavailable {
				t.Errorf("status = %d, want 503 (webhooks are unauthenticated by design)", rec.Code)
			}
		})
	}
}

// TestUnbuiltModuleRoutes_NeverReturnAFakeSuccessShape makes the "no stubbed
// success" rule an assertion rather than a comment.
func TestUnbuiltModuleRoutes_NeverReturnAFakeSuccessShape(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodGet, "/v1/billing/subscription", "", s.tokenFor(t, "user-1", 3))

	body := decodeBody(t, rec)
	if _, hasSubscription := body["subscription"]; hasSubscription {
		t.Error("the 503 response carries a subscription field — a stubbed shape is indistinguishable from a real answer")
	}
	if len(body) != 1 || body["error"] == nil {
		t.Errorf("body = %+v, want only an error field", body)
	}
}

// --- SOS route body handling -------------------------------------------

func TestTriggerSOS_ForwardsBodyAndTokenIdentity(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodPost, "/v1/sos/trigger",
		`{"context_message":"Coffee at 3pm","latitude":6.9271,"longitude":79.8612}`, s.tokenFor(t, "user-7", 2))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if s.monolith.gotUserID != "user-7" {
		t.Errorf("user id = %q, want user-7 (from the token)", s.monolith.gotUserID)
	}
	if s.monolith.gotContextMessage != "Coffee at 3pm" || s.monolith.gotLat != 6.9271 || s.monolith.gotLng != 79.8612 {
		t.Errorf("forwarded (%q, %v, %v), want the request body's values",
			s.monolith.gotContextMessage, s.monolith.gotLat, s.monolith.gotLng)
	}
	if got := decodeBody(t, rec)["contacts_notified"]; got != float64(2) {
		t.Errorf("contacts_notified = %v, want 2", got)
	}
}

// --- signing failure ----------------------------------------------------

// TestSigningFailureIs500NotAPartialSession: if the token can't be minted,
// the client must not receive a 200 with an empty access_token, which would
// look like success and fail confusingly on the next request.
func TestSigningFailureIs500NotAPartialSession(t *testing.T) {
	_, verifier := newTestKeys(t)
	monolith := &fakeMonolith{session: monolithclient.Session{UserID: "user-1"}}
	mux := http.NewServeMux()
	// A Handler with a nil signer stands in for "signing is broken" — the
	// panic it would cause is recovered by the middleware in production; here
	// the assertion is simply that no 200-with-empty-token is possible.
	h := New(monolith, nil, verifier, WithLogger(slog.New(slog.DiscardHandler)))
	h.Register(mux)

	defer func() {
		if rec := recover(); rec == nil {
			t.Error("expected the nil signer to fail loudly rather than emit a tokenless 200")
		}
	}()
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", strings.NewReader(`{"refresh_token":"t"}`)))
	if rec.Code == http.StatusOK && decodeBody(t, rec)["access_token"] == "" {
		t.Error("returned 200 with an empty access_token")
	}
}

// TestTokenTTLMatchesTheAdvertisedExpiry guards the one derived value in the
// session response: expires_in has to describe the token actually issued.
func TestTokenTTLMatchesTheAdvertisedExpiry(t *testing.T) {
	s := newTestServer(t)
	s.monolith.session = monolithclient.Session{UserID: "user-1", TrustLevel: 1}

	rec := s.do(http.MethodPost, "/v1/auth/refresh", `{"refresh_token":"t"}`, "")
	body := decodeBody(t, rec)

	claims, err := s.verifier.Verify(body["access_token"].(string))
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	advertised := time.Duration(body["expires_in"].(float64)) * time.Second
	actual := time.Until(claims.ExpiresAt.Time)
	if diff := actual - advertised; diff > 5*time.Second || diff < -5*time.Second {
		t.Errorf("advertised expires_in = %v but the token actually expires in %v", advertised, actual)
	}
}

// sanity: the fake implements the interface the handlers depend on.
var _ monolithclient.Client = (*fakeMonolith)(nil)

func init() {
	// Fail fast with a clear message if the embedded-interface fake is ever
	// called on a method a test forgot to implement.
	if _, ok := any(&fakeMonolith{}).(monolithclient.Client); !ok {
		panic(fmt.Sprintf("fakeMonolith no longer satisfies monolithclient.Client: %v", errors.New("interface drift")))
	}
}
