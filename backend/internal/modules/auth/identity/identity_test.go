package identity

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/MicahParks/jwkset"
	jwtlib "github.com/golang-jwt/jwt/v5"
)

const testKID = "test-kid"

// newTestJWKSServer serves a JWKS containing key's public half under
// testKID — a local, self-signed stand-in for appleid.apple.com/auth/keys
// or www.googleapis.com/oauth2/v3/certs, never the real endpoints.
func newTestJWKSServer(t *testing.T, key *rsa.PrivateKey) *httptest.Server {
	t.Helper()

	jwk, err := jwkset.NewJWKFromKey(&key.PublicKey, jwkset.JWKOptions{
		Metadata: jwkset.JWKMetadataOptions{KID: testKID, ALG: jwkset.AlgRS256, USE: jwkset.UseSig},
	})
	if err != nil {
		t.Fatalf("build test JWK: %v", err)
	}

	body, err := json.Marshal(jwkset.JWKSMarshal{Keys: []jwkset.JWKMarshal{jwk.Marshal()}})
	if err != nil {
		t.Fatalf("marshal test JWKS: %v", err)
	}

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
}

// signTestToken builds and signs an RS256 id_token with claims, keyed under
// testKID so it resolves against newTestJWKSServer's published key.
func signTestToken(t *testing.T, key *rsa.PrivateKey, claims idTokenClaims) string {
	t.Helper()

	token := jwtlib.NewWithClaims(jwtlib.SigningMethodRS256, claims)
	token.Header["kid"] = testKID

	signed, err := token.SignedString(key)
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return signed
}

func TestJWKSProvider_Verify(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate test key: %v", err)
	}
	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate second test key: %v", err)
	}

	const (
		wantIssuer   = "https://issuer.example.com"
		wantAudience = "test-client-id"
	)

	// The client generates rawNonce and hands the provider its hash, so the
	// hash is what lands in the token and the raw value is what the caller
	// presents to Verify.
	const rawNonce = "nonce-from-this-signin-attempt"
	hashedNonce := HashNonce(rawNonce)

	validClaims := func() idTokenClaims {
		return idTokenClaims{
			Email: "ada@example.com",
			Name:  "Ada Lovelace",
			Nonce: hashedNonce,
			RegisteredClaims: jwtlib.RegisteredClaims{
				Issuer:    wantIssuer,
				Subject:   "subject-123",
				Audience:  jwtlib.ClaimStrings{wantAudience},
				ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(time.Hour)),
				IssuedAt:  jwtlib.NewNumericDate(time.Now()),
			},
		}
	}

	tests := []struct {
		name       string
		signingKey *rsa.PrivateKey // which key actually signs the token
		mutate     func(*idTokenClaims)
		noExpiry   bool   // omit exp entirely, rather than an expired one
		nonce      string // the raw pre-image the CALLER presents; defaults to rawNonce
		wantErr    bool
		wantSub    string
	}{
		{
			name:       "valid token",
			signingKey: key,
			wantSub:    "subject-123",
		},
		{
			name:       "expired token",
			signingKey: key,
			mutate: func(c *idTokenClaims) {
				c.ExpiresAt = jwtlib.NewNumericDate(time.Now().Add(-time.Hour))
			},
			wantErr: true,
		},
		{
			name:       "missing exp claim entirely",
			signingKey: key,
			noExpiry:   true,
			wantErr:    true,
		},
		{
			name:       "wrong audience",
			signingKey: key,
			mutate:     func(c *idTokenClaims) { c.Audience = jwtlib.ClaimStrings{"someone-elses-client-id"} },
			wantErr:    true,
		},
		{
			name:       "wrong issuer",
			signingKey: key,
			mutate:     func(c *idTokenClaims) { c.Issuer = "https://not-the-real-issuer.example.com" },
			wantErr:    true,
		},
		{
			name:       "signed by a key not in the JWKS (forged)",
			signingKey: otherKey,
			wantErr:    true,
		},
		{
			name:       "missing subject",
			signingKey: key,
			mutate:     func(c *idTokenClaims) { c.Subject = "" },
			wantErr:    true,
		},
		// --- nonce replay protection (the security fix this port adds; the
		// source has no nonce check at all). Each of these is a token that
		// is otherwise completely valid — correct signature, issuer,
		// audience and expiry — so they fail on the nonce or not at all.
		{
			name:       "replayed token: nonce belongs to a different sign-in attempt",
			signingKey: key,
			nonce:      "a-different-attempts-nonce",
			wantErr:    true,
		},
		{
			// THE attack the pre-image design exists to stop, and the one an
			// earlier version of this check let through: a nonce claim is not
			// secret — anyone holding the id_token can base64-decode it and
			// read the claim straight out. Presenting that value back must
			// NOT authenticate, because it proves nothing the token itself
			// didn't already carry.
			name:       "attacker replays the token, presenting the claim value itself as the nonce",
			signingKey: key,
			nonce:      HashNonce("nonce-from-this-signin-attempt"), // == the claim
			wantErr:    true,
		},
		{
			name:       "token carries no nonce claim at all",
			signingKey: key,
			mutate:     func(c *idTokenClaims) { c.Nonce = "" },
			wantErr:    true,
		},
		{
			name:       "caller supplies no expected nonce (check must not be skippable)",
			signingKey: key,
			nonce:      "-", // sentinel: send "" as the expected nonce
			wantErr:    true,
		},
		{
			name:       "neither side has a nonce (both empty must still fail closed)",
			signingKey: key,
			mutate:     func(c *idTokenClaims) { c.Nonce = "" },
			nonce:      "-",
			wantErr:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := newTestJWKSServer(t, key)
			defer server.Close()

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			p, err := newJWKSProvider(ctx, "test", server.URL, wantAudience, []string{wantIssuer})
			if err != nil {
				t.Fatalf("newJWKSProvider() error: %v", err)
			}

			claims := validClaims()
			if tt.noExpiry {
				claims.ExpiresAt = nil
			}
			if tt.mutate != nil {
				tt.mutate(&claims)
			}
			idToken := signTestToken(t, tt.signingKey, claims)

			presentedNonce := rawNonce
			if tt.nonce == "-" {
				presentedNonce = ""
			} else if tt.nonce != "" {
				presentedNonce = tt.nonce
			}

			got, err := p.Verify(ctx, idToken, presentedNonce)
			if tt.wantErr {
				if err == nil {
					t.Fatal("Verify() returned nil error, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("Verify() returned error: %v", err)
			}
			if got.Subject != tt.wantSub {
				t.Errorf("Subject = %q, want %q", got.Subject, tt.wantSub)
			}
			if got.Email != "ada@example.com" {
				t.Errorf("Email = %q, want ada@example.com", got.Email)
			}
			if got.Name != "Ada Lovelace" {
				t.Errorf("Name = %q, want Ada Lovelace", got.Name)
			}
		})
	}
}

func TestJWKSProvider_Verify_MalformedToken(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate test key: %v", err)
	}
	server := newTestJWKSServer(t, key)
	defer server.Close()

	ctx := context.Background()
	p, err := newJWKSProvider(ctx, "test", server.URL, "aud", []string{"iss"})
	if err != nil {
		t.Fatalf("newJWKSProvider() error: %v", err)
	}

	if _, err := p.Verify(ctx, "not.a.jwt", "any-nonce"); err == nil {
		t.Fatal("Verify() returned nil error for a malformed token, want error")
	}
}

func TestJWKSProvider_Verify_UnconfiguredAudienceNeverPasses(t *testing.T) {
	// Regression guard for the "empty audience fails closed" claim in
	// Verify's own doc comment — a provider constructed before real
	// credentials exist (APPLE_SERVICES_ID/GOOGLE_CLIENT_ID unset) must
	// reject every token, not accept one because there was nothing to
	// compare against.
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate test key: %v", err)
	}
	server := newTestJWKSServer(t, key)
	defer server.Close()

	ctx := context.Background()
	p, err := newJWKSProvider(ctx, "test", server.URL, "", []string{"https://issuer.example.com"})
	if err != nil {
		t.Fatalf("newJWKSProvider() error: %v", err)
	}

	claims := idTokenClaims{
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    "https://issuer.example.com",
			Subject:   "subject-123",
			Audience:  jwtlib.ClaimStrings{""},
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	idToken := signTestToken(t, key, claims)

	if _, err := p.Verify(ctx, idToken, "any-nonce"); err == nil {
		t.Fatal("Verify() returned nil error for an unconfigured (empty-audience) provider, want error")
	}
}

// TestNewJWKSProvider_FetchFailureDoesNotFailConstruction guards the
// deliberate choice documented on newJWKSProvider: jwksURL is always one
// of this package's own hardcoded constants, so a failed fetch can only
// mean "Apple/Google is transiently unreachable," never "someone
// misconfigured a URL" — that must not crash the whole auth service.
// Verify still correctly rejects tokens in this state, since there's no
// key to check them against.
func TestNewJWKSProvider_FetchFailureDoesNotFailConstruction(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate test key: %v", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	p, err := newJWKSProvider(context.Background(), "test", server.URL, "aud", []string{"https://issuer.example.com"})
	if err != nil {
		t.Fatalf("newJWKSProvider() returned an error for a failing (but well-formed) JWKS endpoint, want no error: %v", err)
	}

	claims := idTokenClaims{
		RegisteredClaims: jwtlib.RegisteredClaims{
			Issuer:    "https://issuer.example.com",
			Subject:   "subject-123",
			Audience:  jwtlib.ClaimStrings{"aud"},
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	idToken := signTestToken(t, key, claims)

	if _, err := p.Verify(context.Background(), idToken, "any-nonce"); err == nil {
		t.Fatal("Verify() returned nil error with an empty JWKS cache, want error")
	}
}

func TestNewJWKSProvider_MalformedURL(t *testing.T) {
	if _, err := newJWKSProvider(context.Background(), "test", "not a url", "aud", []string{"iss"}); err == nil {
		t.Fatal("newJWKSProvider() returned nil error for a malformed URL, want error")
	}
}

// TestHashNonce_MatchesTheClientDefinition pins the raw→claim mapping to a
// known vector. Its twin lives in the Flutter app
// (frontend/test/sign_in_nonce_test.dart, same input, same expected string):
// the two implementations are in different languages and can only be kept in
// agreement by asserting the same vector on both sides. A drift here is a
// total Apple/Google sign-in outage, so it is worth one hard-coded value.
func TestHashNonce_MatchesTheClientDefinition(t *testing.T) {
	const (
		input = "abc"
		want  = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	)
	if got := HashNonce(input); got != want {
		t.Errorf("HashNonce(%q) = %q, want %q — the Flutter client hashes the same way and will stop matching", input, got, want)
	}
}

// TestHashNonce_IsLowercaseHex guards the encoding specifically: base64, or
// uppercase hex, would compare unequal against a client that produced the
// other, with no signal beyond "sign-in stopped working".
func TestHashNonce_IsLowercaseHex(t *testing.T) {
	got := HashNonce("some-raw-nonce")
	if len(got) != 64 {
		t.Errorf("HashNonce produced %d chars, want 64 (hex-encoded SHA-256)", len(got))
	}
	if got != strings.ToLower(got) {
		t.Errorf("HashNonce produced %q, want lowercase", got)
	}
}
