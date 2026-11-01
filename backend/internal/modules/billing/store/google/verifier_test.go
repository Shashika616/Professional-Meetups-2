package google

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func reply(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

// playAPI answers the token endpoint and hands everything else to api.
func playAPI(t *testing.T, api func(*http.Request) *http.Response) *Verifier {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(rsaKey(t))
	if err != nil {
		t.Fatal(err)
	}
	sa, _ := json.Marshal(map[string]string{
		"client_email": "verifier@project.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		// Ignored: the token endpoint is hard-coded.
		"token_uri": "https://evil.example.com/token",
	})
	v, err := New(sa, "com.example.app")
	if err != nil {
		t.Fatal(err)
	}
	v.client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "oauth2.googleapis.com" && r.URL.Path == "/token" {
			return reply(http.StatusOK, `{"access_token":"at-1","expires_in":3600}`), nil
		}
		if r.URL.Host != "androidpublisher.googleapis.com" {
			t.Fatalf("called %s: only Google's own hosts may be called", r.URL.Host)
		}
		if r.Header.Get("Authorization") != "Bearer at-1" {
			t.Fatalf("authorization = %q", r.Header.Get("Authorization"))
		}
		return api(r), nil
	})}
	return v
}

func TestVerifyOneTimeProduct(t *testing.T) {
	var path string
	v := playAPI(t, func(r *http.Request) *http.Response {
		path = r.URL.EscapedPath()
		return reply(http.StatusOK, `{"orderId":"GPA.1","purchaseState":0,"purchaseTimeMillis":"1761300000000",
			"acknowledgementState":0,"obfuscatedExternalAccountId":"ACC","regionCode":"LK","developerPayload":"x"}`)
	})
	tx, err := v.Verify(context.Background(), store.Request{Platform: store.Android, Kind: store.Consumable, ProductID: "credits_50", Token: "tok/1"})
	if err != nil {
		t.Fatal(err)
	}
	if path != "/androidpublisher/v3/applications/com.example.app/purchases/products/credits_50/tokens/tok%2F1" {
		t.Fatalf("path = %s", path)
	}
	if tx.TransactionID != "GPA.1" || tx.AccountToken != "acc" || tx.Environment != store.Production ||
		tx.TokenHash != store.HashToken("tok/1") || tx.Pending || tx.Revoked || tx.AppID != "com.example.app" {
		t.Fatalf("tx = %+v", tx)
	}
	if strings.Contains(string(tx.Raw), "LK") || strings.Contains(string(tx.Raw), "developerPayload") {
		t.Fatalf("raw kept fields it should not: %s", tx.Raw)
	}
}

// purchaseType 0 is a license tester; no orderId falls back to the hash.
func TestVerifyTestPurchase(t *testing.T) {
	v := playAPI(t, func(*http.Request) *http.Response {
		return reply(http.StatusOK, `{"purchaseState":0,"purchaseType":0,"obfuscatedExternalAccountId":"a"}`)
	})
	tx, err := v.Verify(context.Background(), store.Request{Kind: store.Consumable, ProductID: "credits_50", Token: "t"})
	if err != nil {
		t.Fatal(err)
	}
	if tx.Environment != store.Sandbox || tx.TransactionID != "token:"+store.HashToken("t") {
		t.Fatalf("tx = %+v", tx)
	}
}

// The subscription resource can carry the buyer's name and email; none of
// it reaches raw.
func TestVerifySubscriptionDropsPersonalData(t *testing.T) {
	v := playAPI(t, func(r *http.Request) *http.Response {
		if !strings.Contains(r.URL.Path, "/purchases/subscriptions/premium_monthly/tokens/") {
			t.Fatalf("path = %s", r.URL.Path)
		}
		return reply(http.StatusOK, `{"orderId":"GPA.2..0","startTimeMillis":"1761300000000","expiryTimeMillis":"1763900000000",
			"autoRenewing":true,"paymentState":1,"obfuscatedExternalAccountId":"acc",
			"emailAddress":"buyer@example.com","givenName":"Ann","familyName":"Smith","profileName":"ann","countryCode":"LK"}`)
	})
	tx, err := v.Verify(context.Background(), store.Request{Kind: store.Subscription, ProductID: "premium_monthly", Token: "t"})
	if err != nil {
		t.Fatal(err)
	}
	if tx.ExpiresAt == nil || !tx.AutoRenew || tx.OriginalTransactionID != store.HashToken("t") {
		t.Fatalf("tx = %+v", tx)
	}
	for _, pii := range []string{"buyer@example.com", "Ann", "Smith", "profileName", "countryCode"} {
		if strings.Contains(string(tx.Raw), pii) {
			t.Fatalf("raw contains %q: %s", pii, tx.Raw)
		}
	}
}

func TestVerifyClassifiesFailures(t *testing.T) {
	for status, want := range map[int]error{
		http.StatusNotFound: store.ErrRejected, http.StatusGone: store.ErrRejected,
		http.StatusUnauthorized: store.ErrUnavailable, http.StatusInternalServerError: store.ErrUnavailable,
	} {
		v := playAPI(t, func(*http.Request) *http.Response { return reply(status, `{"error":{"message":"tok-echo"}}`) })
		_, err := v.Verify(context.Background(), store.Request{Kind: store.Consumable, ProductID: "p", Token: "secret-token"})
		if !errors.Is(err, want) {
			t.Errorf("status %d: err = %v, want %v", status, err, want)
		}
		if err != nil && (strings.Contains(err.Error(), "secret-token") || strings.Contains(err.Error(), "tok-echo")) {
			t.Errorf("status %d: the error carries the token or the body: %v", status, err)
		}
	}
}

func TestFinishConsumesOrAcknowledges(t *testing.T) {
	var calls []string
	v := playAPI(t, func(r *http.Request) *http.Response {
		calls = append(calls, r.Method+" "+r.URL.Path)
		if strings.HasSuffix(r.URL.Path, "already:consume") {
			return reply(http.StatusBadRequest, `{"error":{"message":"The purchase has already been consumed."}}`)
		}
		return reply(http.StatusOK, `{}`)
	})
	ctx := context.Background()
	if err := v.Finish(ctx, store.Android, store.Consumable, "credits_50", "t1"); err != nil {
		t.Fatal(err)
	}
	if err := v.Finish(ctx, store.Android, store.Subscription, "premium_monthly", "t2"); err != nil {
		t.Fatal(err)
	}
	if err := v.Finish(ctx, store.Android, store.Consumable, "credits_50", "already"); err != nil {
		t.Fatalf("an already-consumed purchase should count as done: %v", err)
	}
	want := []string{
		"POST /androidpublisher/v3/applications/com.example.app/purchases/products/credits_50/tokens/t1:consume",
		"POST /androidpublisher/v3/applications/com.example.app/purchases/subscriptions/premium_monthly/tokens/t2:acknowledge",
		"POST /androidpublisher/v3/applications/com.example.app/purchases/products/credits_50/tokens/already:consume",
	}
	if strings.Join(calls, "\n") != strings.Join(want, "\n") {
		t.Fatalf("calls:\n%s", strings.Join(calls, "\n"))
	}
}

func TestParseNotification(t *testing.T) {
	enc := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	n, err := ParseNotification("m-1", enc(`{"packageName":"com.example.app","eventTimeMillis":"1761300000000",
		"subscriptionNotification":{"notificationType":2,"purchaseToken":"tok","subscriptionId":"premium_monthly"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if n.ID != "m-1" || n.Subscription == nil || n.Subscription.Type != SubRenewed || n.Subscription.TokenHash != store.HashToken("tok") {
		t.Fatalf("n = %+v", n)
	}
	n, err = ParseNotification("m-2", enc(`{"packageName":"p","voidedPurchaseNotification":{"purchaseToken":"tok","orderId":"GPA.1","productType":2}}`))
	if err != nil || n.Voided == nil || n.Voided.ProductType != VoidedProductItem || n.Voided.OrderID != "GPA.1" {
		t.Fatalf("voided = %+v, %v", n, err)
	}
	if _, err := ParseNotification("", enc(`{}`)); !errors.Is(err, store.ErrRejected) {
		t.Fatalf("no message id: %v", err)
	}
	if _, err := ParseNotification("m", "%%%"); !errors.Is(err, store.ErrRejected) {
		t.Fatalf("bad base64: %v", err)
	}
}

// A network failure's error must not carry the request URL: the purchase
// token is in its path, and the error is logged.
func TestNetworkErrorsDoNotLeakTheToken(t *testing.T) {
	v := playAPI(t, func(*http.Request) *http.Response { return nil })
	v.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "oauth2.googleapis.com" {
			return reply(http.StatusOK, `{"access_token":"at-1","expires_in":3600}`), nil
		}
		return nil, errors.New("connection reset")
	})
	_, err := v.Verify(context.Background(), store.Request{Kind: store.Consumable, ProductID: "credits_50", Token: "secret-purchase-token"})
	if !errors.Is(err, store.ErrUnavailable) {
		t.Fatalf("err = %v, want unavailable", err)
	}
	if strings.Contains(err.Error(), "secret-purchase-token") {
		t.Fatalf("the error carries the token: %v", err)
	}
	if err := v.Finish(context.Background(), store.Android, store.Consumable, "credits_50", "secret-purchase-token"); err == nil || strings.Contains(err.Error(), "secret-purchase-token") {
		t.Fatalf("finish error = %v", err)
	}
}

// Whatever Google's wording for "already consumed", a purchase Google
// reports as consumed (or acknowledged) is done.
func TestFinishTreatsAnAlreadyFinishedPurchaseAsDone(t *testing.T) {
	v := playAPI(t, func(r *http.Request) *http.Response {
		switch {
		case r.Method == http.MethodPost:
			return reply(http.StatusBadRequest, `{"error":{"message":"The purchase is not in a valid state to perform the desired operation."}}`)
		case strings.Contains(r.URL.Path, "/purchases/products/"):
			return reply(http.StatusOK, `{"purchaseState":0,"consumptionState":1,"acknowledgementState":1}`)
		default:
			return reply(http.StatusOK, `{"acknowledgementState":1,"expiryTimeMillis":"1763900000000"}`)
		}
	})
	if err := v.Finish(context.Background(), store.Android, store.Consumable, "credits_50", "t"); err != nil {
		t.Fatalf("an already consumed pack: %v", err)
	}
	if err := v.Finish(context.Background(), store.Android, store.Subscription, "premium_monthly", "t"); err != nil {
		t.Fatalf("an already acknowledged subscription: %v", err)
	}
	// Not consumed, and Google refuses: that is a real failure.
	v = playAPI(t, func(r *http.Request) *http.Response {
		if r.Method == http.MethodPost {
			return reply(http.StatusBadRequest, `{"error":{"message":"invalid"}}`)
		}
		return reply(http.StatusOK, `{"purchaseState":0,"consumptionState":0}`)
	})
	if err := v.Finish(context.Background(), store.Android, store.Consumable, "credits_50", "t"); err == nil {
		t.Fatal("an unconsumed purchase Google refused to consume counted as done")
	}
}
