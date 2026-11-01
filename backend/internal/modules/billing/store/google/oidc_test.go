package google

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"errors"
	"math/big"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Ported from the source's webhookauth/google_test.go. Two changes follow
// the code: the audience is required, and keys are cached.

const (
	testKid      = "test-key-1"
	testAudience = "https://api.example.com/v1/billing/webhooks/google"
	testAccount  = "rtdn-push@project.iam.gserviceaccount.com"
)

func rsaKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func jwks(key *rsa.PrivateKey) func(context.Context) (map[string]*rsa.PublicKey, error) {
	return func(context.Context) (map[string]*rsa.PublicKey, error) {
		return map[string]*rsa.PublicKey{testKid: &key.PublicKey}, nil
	}
}

func signToken(t *testing.T, key *rsa.PrivateKey, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = testKid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func validClaims() jwt.MapClaims {
	return jwt.MapClaims{
		"iss": "https://accounts.google.com", "aud": testAudience,
		"email": testAccount, "email_verified": true, "exp": time.Now().Add(time.Hour).Unix(),
	}
}

func verifier(key *rsa.PrivateKey) *OIDCVerifier {
	return &OIDCVerifier{Audience: testAudience, ServiceAccount: testAccount, JWKS: jwks(key)}
}

func TestOIDCValidToken(t *testing.T) {
	key := rsaKey(t)
	claims, err := verifier(key).Verify(context.Background(), "Bearer "+signToken(t, key, validClaims()))
	if err != nil {
		t.Fatalf("a valid token did not verify: %v", err)
	}
	if claims["email"] != testAccount {
		t.Fatalf("claims = %v", claims)
	}
}

func TestOIDCRejections(t *testing.T) {
	key := rsaKey(t)
	cases := map[string]struct {
		mutate func(jwt.MapClaims)
		header func(string) string
		v      func() *OIDCVerifier
	}{
		"no Bearer prefix":   {header: func(tok string) string { return tok }},
		"wrong signing key":  {v: func() *OIDCVerifier { return verifier(rsaKey(t)) }},
		"wrong issuer":       {mutate: func(c jwt.MapClaims) { c["iss"] = "https://evil.example.com" }},
		"wrong audience":     {mutate: func(c jwt.MapClaims) { c["aud"] = "https://other.example.com" }},
		"wrong account":      {mutate: func(c jwt.MapClaims) { c["email"] = "someone@else.iam.gserviceaccount.com" }},
		"unverified email":   {mutate: func(c jwt.MapClaims) { c["email_verified"] = false }},
		"expired":            {mutate: func(c jwt.MapClaims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }},
		"no expiry":          {mutate: func(c jwt.MapClaims) { delete(c, "exp") }},
		"audience unset":     {v: func() *OIDCVerifier { return &OIDCVerifier{JWKS: jwks(key)} }},
		"empty bearer token": {header: func(string) string { return "Bearer " }},
	}
	for name, c := range cases {
		claims := validClaims()
		if c.mutate != nil {
			c.mutate(claims)
		}
		header := "Bearer " + signToken(t, key, claims)
		if c.header != nil {
			header = c.header(signToken(t, key, claims))
		}
		v := verifier(key)
		if c.v != nil {
			v = c.v()
		}
		if _, err := v.Verify(context.Background(), header); !errors.Is(err, ErrBadToken) {
			t.Errorf("%s: err = %v, want ErrBadToken", name, err)
		}
	}
}

func TestOIDCCachesKeysAndRefetchesForAnUnknownKid(t *testing.T) {
	key := rsaKey(t)
	var fetches atomic.Int32
	v := &OIDCVerifier{Audience: testAudience, JWKS: func(ctx context.Context) (map[string]*rsa.PublicKey, error) {
		fetches.Add(1)
		return jwks(key)(ctx)
	}}
	for range 3 {
		if _, err := v.Verify(context.Background(), "Bearer "+signToken(t, key, validClaims())); err != nil {
			t.Fatal(err)
		}
	}
	if n := fetches.Load(); n != 1 {
		t.Fatalf("fetched the keys %d times for three tokens, want 1", n)
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, validClaims())
	tok.Header["kid"] = "rotated"
	s, _ := tok.SignedString(key)
	if _, err := v.Verify(context.Background(), "Bearer "+s); err == nil {
		t.Fatal("an unknown kid verified")
	}
	if n := fetches.Load(); n != 2 {
		t.Fatalf("an unknown kid did not refetch (fetches %d)", n)
	}
}

func TestParseJWKS(t *testing.T) {
	if _, err := ParseJWKS([]byte(`{"keys":[{"kty":"RSA","kid":"k","n":"not+valid/base64url==","e":"AQAB"},{"kty":"EC","kid":"e"}]}`)); err == nil {
		t.Fatal("a malformed RSA modulus parsed")
	}
	key := rsaKey(t)
	n := base64.RawURLEncoding.EncodeToString(key.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())
	keys, err := ParseJWKS([]byte(`{"keys":[{"kty":"RSA","kid":"` + testKid + `","n":"` + n + `","e":"` + e + `"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := keys[testKid]; got == nil || got.N.Cmp(key.N) != 0 || got.E != key.E {
		t.Fatal("the key did not round-trip")
	}
}
