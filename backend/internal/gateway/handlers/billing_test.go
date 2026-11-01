package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type billingRecorder struct {
	gotUserID     string
	gotTrustLevel int32
	gotCapacity   int32
	gotCursor     string
	appConfigUser *string

	gotPlatform, gotProductID, gotToken string
	catalogUser                         *string
	gotSignedPayload                    string
	gotAuthorization, gotMessageID      string
	gotMessageData                      string
}

func (f *fakeMonolith) VerifyPurchase(_ context.Context, userID string, trustLevel int32, platform, productID, token string) (monolithclient.PurchaseResult, error) {
	f.billing.gotUserID, f.billing.gotTrustLevel = userID, trustLevel
	f.billing.gotPlatform, f.billing.gotProductID, f.billing.gotToken = platform, productID, token
	return monolithclient.PurchaseResult{Kind: "consumable", ProductID: productID, CreditsGranted: 50,
		Wallet: monolithclient.Wallet{Balance: 50, ExpiringSoon: []monolithclient.ExpiringCredits{}}}, f.err
}

func (f *fakeMonolith) GetSubscription(_ context.Context, userID string) (monolithclient.Subscription, error) {
	f.billing.gotUserID = userID
	return monolithclient.Subscription{Status: "none"}, f.err
}

func (f *fakeMonolith) GetCatalog(_ context.Context, userID string) (monolithclient.Catalog, error) {
	f.billing.catalogUser = &userID
	return monolithclient.Catalog{CatalogVersion: 1, CreditPacks: []monolithclient.CreditPack{{ProductID: "credits_50", Credits: 50}},
		Plans: []monolithclient.CatalogPlan{}}, f.err
}

func (f *fakeMonolith) HandleAppleNotification(_ context.Context, signedPayload string) (bool, error) {
	f.billing.gotSignedPayload = signedPayload
	return true, f.err
}

func (f *fakeMonolith) HandleGoogleNotification(_ context.Context, authorization, messageID, data string) (bool, error) {
	f.billing.gotAuthorization, f.billing.gotMessageID, f.billing.gotMessageData = authorization, messageID, data
	return true, f.err
}

func (f *fakeMonolith) GetWallet(_ context.Context, userID string, trustLevel int32) (monolithclient.Wallet, error) {
	f.billing.gotUserID, f.billing.gotTrustLevel = userID, trustLevel
	return monolithclient.Wallet{Balance: 60, Available: 60, ExpiringSoon: []monolithclient.ExpiringCredits{}}, f.err
}

func (f *fakeMonolith) ListLedger(_ context.Context, userID, cursor string, _ int32) (monolithclient.LedgerPage, error) {
	f.billing.gotUserID, f.billing.gotCursor = userID, cursor
	return monolithclient.LedgerPage{Entries: []monolithclient.LedgerEntry{}}, f.err
}

func (f *fakeMonolith) Quote(_ context.Context, userID string, trustLevel, capacity int32, _ int64) (monolithclient.Quote, error) {
	f.billing.gotUserID, f.billing.gotTrustLevel, f.billing.gotCapacity = userID, trustLevel, capacity
	return monolithclient.Quote{Cost: 10, PriceVersion: 1}, f.err
}

func (f *fakeMonolith) GetEntitlements(_ context.Context, userID string, trustLevel int32) (monolithclient.Entitlements, error) {
	f.billing.gotUserID, f.billing.gotTrustLevel = userID, trustLevel
	return monolithclient.Entitlements{}, f.err
}

func (f *fakeMonolith) GetAppConfig(_ context.Context, userID string) (monolithclient.AppConfig, error) {
	f.billing.appConfigUser = &userID
	return monolithclient.AppConfig{Flags: map[string]bool{"billing.plans.visible": false}}, f.err
}

var billingRoutes = []struct{ method, path, body string }{
	{http.MethodGet, "/v1/billing/wallet", ""},
	{http.MethodGet, "/v1/billing/ledger", ""},
	{http.MethodPost, "/v1/billing/quote", `{"capacity":4,"window_start_unix_seconds":1900000000}`},
	{http.MethodGet, "/v1/billing/entitlements", ""},
}

func TestBillingRoutesRequireAuthentication(t *testing.T) {
	s := newTestServer(t)
	for _, r := range billingRoutes {
		if rec := s.do(r.method, r.path, r.body, ""); rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s without a token = %d, want 401", r.method, r.path, rec.Code)
		}
		if rec := s.do(r.method, r.path, r.body, "not-a-jwt"); rec.Code != http.StatusUnauthorized {
			t.Errorf("%s %s with a bad token = %d, want 401", r.method, r.path, rec.Code)
		}
	}
}

// API1: the user is the token's, whatever the request names.
func TestBillingRoutesUseOnlyTheTokensUser(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "alice", 3)
	for _, r := range []struct{ method, path, body string }{
		{http.MethodGet, "/v1/billing/wallet?user_id=bob", ""},
		{http.MethodGet, "/v1/billing/ledger?user_id=bob&cursor=abc", ""},
		{http.MethodGet, "/v1/billing/entitlements?user_id=bob", ""},
		{http.MethodPost, "/v1/billing/quote?user_id=bob", `{"capacity":4,"window_start_unix_seconds":1900000000}`},
	} {
		s.monolith.billing = billingRecorder{}
		rec := s.do(r.method, r.path, r.body, token)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s = %d: %s", r.method, r.path, rec.Code, rec.Body.String())
		}
		if s.monolith.billing.gotUserID != "alice" {
			t.Errorf("%s %s asked billing about %q, want alice", r.method, r.path, s.monolith.billing.gotUserID)
		}
	}
	if s.monolith.billing.gotTrustLevel != 3 {
		t.Errorf("trust level %d did not come from the token", s.monolith.billing.gotTrustLevel)
	}
}

// API3: a quote body naming a price, a user or anything else is refused.
func TestQuoteRejectsUnknownFields(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "alice", 3)
	for _, body := range []string{
		`{"capacity":4,"window_start_unix_seconds":1900000000,"cost":0}`,
		`{"capacity":4,"window_start_unix_seconds":1900000000,"user_id":"bob"}`,
		`{"capacity":4,"window_start_unix_seconds":1900000000,"price_version":1}`,
		`{"capacity":4} {"capacity":5}`,
		`{"capacity":"four"}`,
		`not json`,
		`{"capacity":4,"window_start_unix_seconds":1900000000,"pad":"` + strings.Repeat("x", 2048) + `"}`,
	} {
		if rec := s.do(http.MethodPost, "/v1/billing/quote", body, token); rec.Code != http.StatusBadRequest {
			t.Errorf("quote with body %.60q = %d, want 400", body, rec.Code)
		}
	}
}

func TestCodedErrorsBecomeStructuredResponses(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		wantCode int
		wantBody map[string]any
	}{
		{
			"insufficient credits",
			&apperror.CodedError{Sentinel: apperror.ErrPaymentRequired, Code: apperror.CodeInsufficientCredits,
				Message: "billing: not enough credits to host this meetup", Fields: map[string]int64{"cost": 10, "available": 4, "shortfall": 6}},
			http.StatusPaymentRequired,
			map[string]any{"code": "insufficient_credits", "cost": float64(10), "available": float64(4), "shortfall": float64(6)},
		},
		{
			"price changed",
			&apperror.CodedError{Sentinel: apperror.ErrConflict, Code: apperror.CodePriceChanged,
				Message: "meetup: the price changed; check the new price and try again", Fields: map[string]int64{"cost": 13, "price_version": 2}},
			http.StatusConflict,
			map[string]any{"code": "price_changed", "cost": float64(13), "price_version": float64(2)},
		},
		{
			"update required",
			&apperror.CodedError{Sentinel: apperror.ErrUpgradeRequired, Code: apperror.CodeUpdateRequired,
				Message: "Update TieHere to host a meetup."},
			http.StatusUpgradeRequired,
			map[string]any{"code": "update_required", "error": "Update TieHere to host a meetup."},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := newTestServer(t)
			// What the monolith client hands back: a gRPC status, the
			// detail included.
			s.monolith.err = status.Convert(apperror.ToGRPCStatus(tt.err)).Err()
			rec := s.do(http.MethodPost, "/v1/meetups", `{"intent":"coffee","capacity":4}`, s.tokenFor(t, "alice", 3))
			if rec.Code != tt.wantCode {
				t.Fatalf("status = %d, want %d: %s", rec.Code, tt.wantCode, rec.Body.String())
			}
			body := decodeBody(t, rec)
			for k, v := range tt.wantBody {
				if body[k] != v {
					t.Errorf("body[%q] = %v, want %v (body %v)", k, body[k], v, body)
				}
			}
			if msg, _ := body["error"].(string); msg == "" || strings.Contains(msg, "billing:") || strings.Contains(msg, "required") && tt.wantCode != http.StatusUpgradeRequired {
				t.Errorf("error message %q is not a sentence for a person", msg)
			}
		})
	}
}

func TestCreateMeetupForwardsTheChargeFields(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "alice", 3)
	r := httptest.NewRequest(http.MethodPost, "/v1/meetups",
		strings.NewReader(`{"intent":"coffee","capacity":4,"expected_cost":12,"price_version":3}`))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Idempotency-Key", "  8f9a-retry-key  ")
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	got := s.monolith.meetup.charge
	if got.ExpectedCost == nil || *got.ExpectedCost != 12 || got.PriceVersion != 3 || got.IdempotencyKey != "8f9a-retry-key" {
		t.Fatalf("forwarded %+v", got)
	}

	// An old build sends none of it, and still creates.
	s.monolith.meetup.charge = monolithclient.CreateCharge{}
	if rec := s.do(http.MethodPost, "/v1/meetups", `{"intent":"coffee","capacity":4}`, token); rec.Code != http.StatusOK {
		t.Fatalf("old-shape body: %d", rec.Code)
	}
	if c := s.monolith.meetup.charge; c.ExpectedCost != nil || c.IdempotencyKey != "" {
		t.Fatalf("old-shape body forwarded %+v", c)
	}

	// A malformed key is refused rather than dropped.
	for _, key := range []string{strings.Repeat("k", 129), "has space", "tab\there"} {
		r := httptest.NewRequest(http.MethodPost, "/v1/meetups", strings.NewReader(`{"intent":"coffee","capacity":4}`))
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("Idempotency-Key", key)
		rec := httptest.NewRecorder()
		s.mux.ServeHTTP(rec, r)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("Idempotency-Key %.20q = %d, want 400", key, rec.Code)
		}
	}
}

func TestAppConfigWorksSignedInAndOut(t *testing.T) {
	s := newTestServer(t)
	if rec := s.do(http.MethodGet, "/v1/app-config", "", ""); rec.Code != http.StatusOK {
		t.Fatalf("anonymous app-config = %d", rec.Code)
	}
	if s.monolith.billing.appConfigUser == nil || *s.monolith.billing.appConfigUser != "" {
		t.Fatalf("anonymous app-config asked for user %v", s.monolith.billing.appConfigUser)
	}
	if rec := s.do(http.MethodGet, "/v1/app-config", "", s.tokenFor(t, "alice", 1)); rec.Code != http.StatusOK {
		t.Fatalf("signed-in app-config = %d", rec.Code)
	}
	if *s.monolith.billing.appConfigUser != "alice" {
		t.Fatalf("signed-in app-config asked for %q", *s.monolith.billing.appConfigUser)
	}
	body := decodeBody(t, s.do(http.MethodGet, "/v1/app-config", "", ""))
	if _, ok := body["flags"].(map[string]any); !ok {
		t.Fatalf("app-config body has no flags object: %v", body)
	}
}

// 29B: verify forwards the token's user and the store's token, and nothing
// a client could use to name an amount or another account.
func TestVerifyPurchaseForwardsOnlyWhatTheStoreGave(t *testing.T) {
	s := newTestServer(t)
	token := s.tokenFor(t, "alice", 3)
	rec := s.do(http.MethodPost, "/v1/billing/purchases/verify?user_id=bob",
		`{"platform":"android","product_id":"credits_50","token":"purchase-token"}`, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("verify = %d: %s", rec.Code, rec.Body.String())
	}
	b := s.monolith.billing
	if b.gotUserID != "alice" || b.gotTrustLevel != 3 || b.gotPlatform != "android" || b.gotProductID != "credits_50" || b.gotToken != "purchase-token" {
		t.Fatalf("forwarded %+v", b)
	}
	body := decodeBody(t, rec)
	if body["credits_granted"] != float64(50) || body["wallet"] == nil {
		t.Fatalf("body = %v", body)
	}
	for _, bad := range []string{
		`{"platform":"android","product_id":"credits_50","token":"t","credits":500}`,
		`{"platform":"android","product_id":"credits_50","token":"t","user_id":"bob"}`,
		`{"platform":"android","product_id":"credits_50","token":"t","price":1}`,
		`{"platform":"android","product_id":"credits_50","token":"` + strings.Repeat("x", 40<<10) + `"}`,
		`not json`,
	} {
		if rec := s.do(http.MethodPost, "/v1/billing/purchases/verify", bad, token); rec.Code != http.StatusBadRequest {
			t.Errorf("verify with %.50q = %d, want 400", bad, rec.Code)
		}
	}
}

func TestVerifyPurchaseIsLimitedTo10AMinute(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "alice", 3)
	limited := 0
	for range verifyRateLimit + 3 {
		rec := s.do(http.MethodPost, "/v1/billing/purchases/verify", `{"platform":"ios","product_id":"credits_50","token":"t"}`, token)
		if rec.Code == http.StatusTooManyRequests {
			limited++
		}
	}
	if limited != 3 {
		t.Fatalf("%d of %d verifies were limited, want 3", limited, verifyRateLimit+3)
	}
}

func TestCatalogWorksSignedInAndOutAndHasNoPrices(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodGet, "/v1/billing/catalog", "", "")
	if rec.Code != http.StatusOK || s.monolith.billing.catalogUser == nil || *s.monolith.billing.catalogUser != "" {
		t.Fatalf("anonymous catalog = %d, user %v", rec.Code, s.monolith.billing.catalogUser)
	}
	if strings.Contains(strings.ToLower(rec.Body.String()), "price") {
		t.Fatalf("the catalog carries a price: %s", rec.Body.String())
	}
	if rec := s.do(http.MethodGet, "/v1/billing/catalog", "", s.tokenFor(t, "alice", 1)); rec.Code != http.StatusOK || *s.monolith.billing.catalogUser != "alice" {
		t.Fatalf("signed-in catalog = %d for %q", rec.Code, *s.monolith.billing.catalogUser)
	}
}

func TestStoreWebhooksForwardTheRequestUntouched(t *testing.T) {
	s := newTestServer(t)
	if rec := s.do(http.MethodPost, "/v1/billing/webhooks/apple", `{"signedPayload":"eyJ.a.b"}`, ""); rec.Code != http.StatusOK {
		t.Fatalf("apple = %d", rec.Code)
	}
	if s.monolith.billing.gotSignedPayload != "eyJ.a.b" {
		t.Fatalf("apple payload = %q", s.monolith.billing.gotSignedPayload)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/webhooks/google",
		strings.NewReader(`{"message":{"data":"ZGF0YQ==","messageId":"m-1"},"subscription":"projects/p/subscriptions/s"}`))
	req.Header.Set("Authorization", "Bearer oidc-token")
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("google = %d", rec.Code)
	}
	b := s.monolith.billing
	if b.gotAuthorization != "Bearer oidc-token" || b.gotMessageID != "m-1" || b.gotMessageData != "ZGF0YQ==" {
		t.Fatalf("google forwarded %+v", b)
	}
	for path, body := range map[string]string{
		"/v1/billing/webhooks/apple":  `{"signedPayload":""}`,
		"/v1/billing/webhooks/google": `not json`,
	} {
		if rec := s.do(http.MethodPost, path, body, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("%s with %q = %d, want 400", path, body, rec.Code)
		}
	}
	big := `{"signedPayload":"` + strings.Repeat("x", webhookMaxBody) + `"}`
	if rec := s.do(http.MethodPost, "/v1/billing/webhooks/apple", big, ""); rec.Code != http.StatusBadRequest {
		t.Errorf("an oversized notification = %d, want 400", rec.Code)
	}
}

// A notification billing cannot verify is 401, so the store knows to look,
// not 500.
func TestStoreWebhookVerificationFailureIs401(t *testing.T) {
	s := newTestServer(t)
	s.monolith.err = status.Error(codes.Unauthenticated, "billing: notification signature does not verify")
	if rec := s.do(http.MethodPost, "/v1/billing/webhooks/apple", `{"signedPayload":"forged"}`, ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("forged apple notification = %d, want 401", rec.Code)
	}
	s.monolith.err = status.Error(codes.Unavailable, "billing: purchases cannot be verified right now")
	if rec := s.do(http.MethodPost, "/v1/billing/purchases/verify", `{"platform":"ios","product_id":"credits_50","token":"t"}`,
		s.tokenFor(t, "alice", 3)); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("verify with the store unconfigured = %d, want 503", rec.Code)
	}
}

func TestBillingRoutesArePerUserRateLimited(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "alice", 3)
	limited := 0
	for i := 0; i < billingRateLimit+5; i++ {
		if rec := s.do(http.MethodGet, "/v1/billing/wallet", "", token); rec.Code == http.StatusTooManyRequests {
			limited++
		}
	}
	if limited != 5 {
		t.Fatalf("%d of %d wallet reads were limited, want 5", limited, billingRateLimit+5)
	}
	// Another user has their own budget.
	if rec := s.do(http.MethodGet, "/v1/billing/wallet", "", s.tokenFor(t, "bob", 3)); rec.Code != http.StatusOK {
		t.Fatalf("bob was limited by alice's traffic: %d", rec.Code)
	}
}
