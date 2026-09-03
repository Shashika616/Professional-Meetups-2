package jwt

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

// generateTestKeypair writes a fresh RSA keypair to PEM files under t.TempDir
// so each test gets its own isolated Signer/Verifier pair.
func generateTestKeypair(t *testing.T) (privPath, pubPath string) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	dir := t.TempDir()

	privPath = filepath.Join(dir, "private.pem")
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
	pubPath = filepath.Join(dir, "public.pem")
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubBytes})
	if err := os.WriteFile(pubPath, pubPEM, 0o600); err != nil {
		t.Fatalf("write public key: %v", err)
	}

	return privPath, pubPath
}

func TestSignVerifyRoundTrip(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)

	signer, err := NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	token, err := signer.Sign(Claims{UserID: "user-123", TrustLevel: 2})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	claims, err := verifier.Verify(token)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if claims.UserID != "user-123" {
		t.Errorf("UserID = %q, want %q", claims.UserID, "user-123")
	}
	if claims.TrustLevel != 2 {
		t.Errorf("TrustLevel = %d, want %d", claims.TrustLevel, 2)
	}
	if claims.Subject != "user-123" {
		t.Errorf("Subject = %q, want %q", claims.Subject, "user-123")
	}
	if claims.Issuer != issuer {
		t.Errorf("Issuer = %q, want %q", claims.Issuer, issuer)
	}
}

// TestSignVerifyRoundTrip_TrustLevelZero guards ADR-014's Level 0: the
// trust_level claim can now legitimately be 0 (a real, federated-only
// account, not an error state) — Claims.TrustLevel has no `omitempty` tag,
// so 0 must round-trip as an explicit, present claim, not be
// indistinguishable from a token that never carried one at all.
func TestSignVerifyRoundTrip_TrustLevelZero(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)

	signer, err := NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	token, err := signer.Sign(Claims{UserID: "user-1", TrustLevel: 0})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	claims, err := verifier.Verify(token)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if claims.TrustLevel != 0 {
		t.Errorf("TrustLevel = %d, want 0", claims.TrustLevel)
	}
	if claims.UserID != "user-1" {
		t.Errorf("UserID = %q, want %q", claims.UserID, "user-1")
	}
}

func TestVerifyRejectsTamperedToken(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)

	signer, err := NewSigner(privPath)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	token, err := signer.Sign(Claims{UserID: "user-123", TrustLevel: 1})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Flip a character in the middle of the token, not the last character
	// of the string. The last base64url group of a segment can carry
	// unused padding bits, so changing only the final character doesn't
	// reliably change the decoded bytes — flipping the last char here
	// round-tripped to the identical signature about 1 run in 16, a real
	// flake this test used to have.
	mid := len(token) / 2
	replacement := byte('x')
	if token[mid] == replacement {
		replacement = 'y'
	}
	tampered := token[:mid] + string(replacement) + token[mid+1:]
	if tampered == token {
		t.Fatal("tamper produced identical token, test is broken")
	}

	if _, err := verifier.Verify(tampered); err == nil {
		t.Fatal("Verify accepted a tampered token")
	}
}

func TestVerifyRejectsExpiredToken(t *testing.T) {
	privPath, pubPath := generateTestKeypair(t)

	privRaw, err := os.ReadFile(privPath)
	if err != nil {
		t.Fatalf("read private key: %v", err)
	}
	privKey, err := jwtlib.ParseRSAPrivateKeyFromPEM(privRaw)
	if err != nil {
		t.Fatalf("parse private key: %v", err)
	}

	verifier, err := NewVerifier(pubPath)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	expired := Claims{
		UserID:     "user-123",
		TrustLevel: 1,
		RegisteredClaims: jwtlib.RegisteredClaims{
			Subject:   "user-123",
			Issuer:    issuer,
			IssuedAt:  jwtlib.NewNumericDate(time.Now().Add(-30 * time.Minute)),
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(-15 * time.Minute)),
		},
	}
	signed, err := jwtlib.NewWithClaims(jwtlib.SigningMethodRS256, expired).SignedString(privKey)
	if err != nil {
		t.Fatalf("sign expired token: %v", err)
	}

	if _, err := verifier.Verify(signed); err == nil {
		t.Fatal("Verify accepted an expired token")
	}
}

func TestVerifyRejectsWrongKey(t *testing.T) {
	privPathA, _ := generateTestKeypair(t)
	_, pubPathB := generateTestKeypair(t)

	signer, err := NewSigner(privPathA)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	verifier, err := NewVerifier(pubPathB)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	token, err := signer.Sign(Claims{UserID: "user-123", TrustLevel: 1})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	if _, err := verifier.Verify(token); err == nil {
		t.Fatal("Verify accepted a token signed by a different keypair")
	}
}
