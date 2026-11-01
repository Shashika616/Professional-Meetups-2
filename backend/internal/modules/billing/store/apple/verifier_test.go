package apple

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple/appletest"
)

// roundTrip answers the App Store Server API in tests. It sees the real
// request, so the host and the bearer can be checked.
type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func reply(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

func testVerifier(t *testing.T, chain appletest.Chain, rt roundTrip) *Verifier {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	v, err := New(Config{BundleID: "com.example.app", IssuerID: "issuer", KeyID: "KEY123",
		PrivateKeyPEM: pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})}, chain.Roots)
	if err != nil {
		t.Fatal(err)
	}
	v.client = &http.Client{Transport: rt}
	return v
}

func TestVerifyFetchesApplesCopyFromTheRightHost(t *testing.T) {
	chain := appletest.New(t)
	for _, c := range []struct {
		env, host string
		want      store.Environment
	}{
		{"Production", "api.storekit.itunes.apple.com", store.Production},
		{"Sandbox", "api.storekit-sandbox.itunes.apple.com", store.Sandbox},
	} {
		claims := appletest.Transaction("t1", "o1", "com.example.app", "credits_50", "Consumable", "ACC", c.env, nil)
		signed := chain.Sign(t, claims)
		var sawHost, sawPath string
		var sawBearer jwt.MapClaims
		v := testVerifier(t, chain, func(r *http.Request) (*http.Response, error) {
			sawHost, sawPath = r.URL.Host, r.URL.Path
			tok, _, err := jwt.NewParser().ParseUnverified(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "), jwt.MapClaims{})
			if err != nil {
				t.Fatalf("bearer: %v", err)
			}
			sawBearer = tok.Claims.(jwt.MapClaims)
			if tok.Header["kid"] != "KEY123" {
				t.Errorf("bearer kid = %v", tok.Header["kid"])
			}
			body, _ := json.Marshal(map[string]string{"signedTransactionInfo": signed})
			return reply(http.StatusOK, string(body)), nil
		})
		tx, err := v.Verify(context.Background(), store.Request{Platform: store.IOS, Kind: store.Consumable, ProductID: "credits_50", Token: signed})
		if err != nil {
			t.Fatalf("%s: %v", c.env, err)
		}
		if sawHost != c.host || sawPath != "/inApps/v1/transactions/t1" {
			t.Fatalf("%s: called %s%s", c.env, sawHost, sawPath)
		}
		if sawBearer["aud"] != "appstoreconnect-v1" || sawBearer["bid"] != "com.example.app" || sawBearer["iss"] != "issuer" {
			t.Fatalf("bearer claims = %v", sawBearer)
		}
		if tx.TransactionID != "t1" || tx.Environment != c.want || tx.AccountToken != "acc" || tx.AppID != "com.example.app" {
			t.Fatalf("%s: tx = %+v", c.env, tx)
		}
	}
}

// Apple's copy is what counts: a revocation the app's copy predates is seen.
func TestVerifyUsesApplesCopy(t *testing.T) {
	chain := appletest.New(t)
	claims := appletest.Transaction("t1", "o1", "com.example.app", "credits_50", "Consumable", "acc", "Production", nil)
	appCopy := chain.Sign(t, claims)
	claims["revocationDate"] = time.Now().UnixMilli()
	applesCopy := chain.Sign(t, claims)
	v := testVerifier(t, chain, func(*http.Request) (*http.Response, error) {
		body, _ := json.Marshal(map[string]string{"signedTransactionInfo": applesCopy})
		return reply(http.StatusOK, string(body)), nil
	})
	tx, err := v.Verify(context.Background(), store.Request{Platform: store.IOS, Token: appCopy})
	if err != nil {
		t.Fatal(err)
	}
	if !tx.Revoked {
		t.Fatal("the revocation in Apple's copy was missed")
	}
}

func TestVerifyClassifiesFailures(t *testing.T) {
	chain := appletest.New(t)
	signed := chain.Sign(t, appletest.Transaction("t1", "o1", "b", "p", "Consumable", "a", "Production", nil))
	for status, want := range map[int]error{
		http.StatusNotFound: store.ErrRejected, http.StatusUnauthorized: store.ErrUnavailable,
		http.StatusTooManyRequests: store.ErrUnavailable, http.StatusInternalServerError: store.ErrUnavailable,
	} {
		v := testVerifier(t, chain, func(*http.Request) (*http.Response, error) { return reply(status, `{}`), nil })
		if _, err := v.Verify(context.Background(), store.Request{Token: signed}); !errors.Is(err, want) {
			t.Errorf("status %d: err = %v, want %v", status, err, want)
		}
	}
	// A token that is not Apple-signed never reaches the network.
	v := testVerifier(t, chain, func(*http.Request) (*http.Response, error) {
		t.Fatal("called Apple for an unsigned token")
		return nil, nil
	})
	forged := appletest.New(t).Sign(t, appletest.Transaction("t1", "o1", "b", "p", "Consumable", "a", "Production", nil))
	if _, err := v.Verify(context.Background(), store.Request{Token: forged}); !errors.Is(err, store.ErrRejected) {
		t.Fatalf("forged token: %v", err)
	}
}

func TestNewRefusesAnIncompleteKey(t *testing.T) {
	if _, err := New(Config{BundleID: "b", IssuerID: "i", KeyID: "k"}, nil); err == nil {
		t.Fatal("a config with no private key was accepted")
	}
	if _, err := New(Config{BundleID: "b", IssuerID: "i", KeyID: "k", PrivateKeyPEM: []byte("junk")}, nil); err == nil {
		t.Fatal("an unreadable private key was accepted")
	}
}

func TestParseNotificationVerifiesEverythingInside(t *testing.T) {
	chain := appletest.New(t)
	expires := time.Now().Add(time.Hour)
	tx := chain.Sign(t, appletest.Transaction("t2", "o1", "com.example.app", "premium_monthly", "Auto-Renewable Subscription", "acc", "Production", &expires))
	grace := time.Now().Add(72 * time.Hour).UnixMilli()
	renewal := chain.Sign(t, jwt.MapClaims{"autoRenewStatus": 1, "gracePeriodExpiresDate": grace})
	payload := chain.Sign(t, jwt.MapClaims{
		"notificationType": "DID_FAIL_TO_RENEW", "subtype": "GRACE_PERIOD", "notificationUUID": "n-1",
		"data": map[string]any{"bundleId": "com.example.app", "environment": "Production",
			"signedTransactionInfo": tx, "signedRenewalInfo": renewal},
	})
	n, err := ParseNotification(payload, chain.Roots)
	if err != nil {
		t.Fatal(err)
	}
	if n.ID != "n-1" || n.Type != "DID_FAIL_TO_RENEW" || n.Subtype != "GRACE_PERIOD" || n.Transaction == nil ||
		n.Transaction.OriginalTransactionID != "o1" || n.GracePeriodEnd == nil || n.AutoRenew == nil || !*n.AutoRenew {
		t.Fatalf("notification = %+v", n)
	}

	// A genuine envelope around a forged transaction is refused whole.
	forgedTx := appletest.New(t).Sign(t, appletest.Transaction("t3", "o1", "com.example.app", "premium_monthly", "", "acc", "Production", nil))
	payload = chain.Sign(t, jwt.MapClaims{"notificationType": "REFUND", "notificationUUID": "n-2",
		"data": map[string]any{"signedTransactionInfo": forgedTx}})
	if _, err := ParseNotification(payload, chain.Roots); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("forged inner transaction: %v, want ErrBadSignature", err)
	}
	if _, err := ParseNotification(appletest.New(t).Sign(t, jwt.MapClaims{"notificationUUID": "x"}), chain.Roots); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("forged envelope: %v", err)
	}
}
