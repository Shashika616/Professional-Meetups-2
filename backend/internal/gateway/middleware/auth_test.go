package middleware

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"

	sharedjwt "professional-meetups-monolith/backend/internal/platform/jwt"
)

// testKeypair mirrors shared/jwt's own (unexported, different package)
// generateTestKeypair. Returns the raw private key too — needed to hand-craft
// an already-expired-but-validly-signed token for TestAuth_ExpiredTokenRejected,
// since Signer.Sign always overwrites exp/iat with fresh values.
func testKeypair(t *testing.T) (privKey *rsa.PrivateKey, signer *sharedjwt.Signer, verifier *sharedjwt.Verifier) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	dir := t.TempDir()

	privPath := filepath.Join(dir, "private.pem")
	privPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	if err := os.WriteFile(privPath, privPEM, 0o600); err != nil {
		t.Fatalf("write private key: %v", err)
	}

	pubBytes, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	pubPath := filepath.Join(dir, "public.pem")
	if err := os.WriteFile(pubPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubBytes}), 0o600); err != nil {
		t.Fatalf("write public key: %v", err)
	}

	signer, err = sharedjwt.NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err = sharedjwt.NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return key, signer, verifier
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(UserIDFromContext(r.Context())))
	})
}

func trustLevelHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, "%d", TrustLevelFromContext(r.Context()))
	})
}

func TestAuth_NoHeaderRejected(t *testing.T) {
	_, _, verifier := testKeypair(t)
	handler := Auth(verifier)(okHandler())

	req := httptest.NewRequest(http.MethodGet, "/v1/users/me", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestAuth_InvalidTokenRejected(t *testing.T) {
	_, _, verifier := testKeypair(t)
	handler := Auth(verifier)(okHandler())

	req := httptest.NewRequest(http.MethodGet, "/v1/users/me", nil)
	req.Header.Set("Authorization", "Bearer not-a-real-token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ExpiredTokenRejected(t *testing.T) {
	privKey, _, verifier := testKeypair(t)
	handler := Auth(verifier)(okHandler())

	// Hand-crafted directly against the same private key the verifier
	// trusts, with an expiry in the past — Signer.Sign always overwrites
	// exp/iat with fresh values, so it can't produce this on its own.
	claims := sharedjwt.Claims{
		UserID: "user-1",
		RegisteredClaims: jwtlib.RegisteredClaims{
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(-time.Hour)),
			IssuedAt:  jwtlib.NewNumericDate(time.Now().Add(-2 * time.Hour)),
			Issuer:    "professional-connections-auth",
		},
	}
	expired, err := jwtlib.NewWithClaims(jwtlib.SigningMethodRS256, claims).SignedString(privKey)
	if err != nil {
		t.Fatalf("sign expired token: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/users/me", nil)
	req.Header.Set("Authorization", "Bearer "+expired)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestAuth_ValidTokenExtractsCorrectUserID(t *testing.T) {
	_, signer, verifier := testKeypair(t)
	handler := Auth(verifier)(okHandler())

	for _, userID := range []string{"user-1", "user-2"} {
		token, err := signer.Sign(sharedjwt.Claims{UserID: userID, TrustLevel: 1})
		if err != nil {
			t.Fatalf("sign: %v", err)
		}

		req := httptest.NewRequest(http.MethodGet, "/v1/users/me", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
		}
		// Two different valid tokens for two different users must extract
		// two distinct, correct user IDs — not a shared/stale value.
		if got := rec.Body.String(); got != userID {
			t.Errorf("extracted user_id = %q, want %q", got, userID)
		}
	}
}

func TestAuth_ValidTokenExtractsCorrectTrustLevel(t *testing.T) {
	_, signer, verifier := testKeypair(t)
	handler := Auth(verifier)(trustLevelHandler())

	// 0 included deliberately (ADR-014): TrustLevelFromContext's own
	// zero-value fallback for "no claim attached" is also 0, so an
	// explicit trust_level: 0 claim needs its own case to prove it's
	// actually carried through Auth, not just coincidentally matching
	// that fallback.
	for _, trustLevel := range []int{0, 1, 2, 4} {
		token, err := signer.Sign(sharedjwt.Claims{UserID: "user-1", TrustLevel: trustLevel})
		if err != nil {
			t.Fatalf("sign: %v", err)
		}

		req := httptest.NewRequest(http.MethodGet, "/v1/meetups", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
		}
		if got := rec.Body.String(); got != fmt.Sprintf("%d", trustLevel) {
			t.Errorf("extracted trust_level = %q, want %q", got, fmt.Sprintf("%d", trustLevel))
		}
	}
}
