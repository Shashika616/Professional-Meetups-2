package jwt

import (
	"crypto/rsa"
	"fmt"
	"os"
	"time"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

// AccessTokenTTL is the lifetime of an issued access token. This is a
// security parameter, not a deployment parameter — it is a hardcoded
// constant, deliberately not read from the environment. It is also what the
// gateway reports as `expires_in` on every session response now, since the
// monolith no longer computes that field (ADR-001 §6).
const AccessTokenTTL = 15 * time.Minute

// issuer is carried over verbatim from the sibling repo rather than renamed
// — it is a claim value the frontend never inspects, and changing it would
// be an invented divergence with no behavioral payoff. It does NOT make
// tokens interchangeable between the two backends: they are separate systems
// with separate keypairs (backend/secrets/README.md), and verification is by
// signature, not by issuer string.
const issuer = "professional-connections-auth"

// audience is the `aud` every access token carries and the verifier
// requires (tracker #93, review finding N-A7).
//
// # WHY A TOKEN NEEDS TO SAY WHAT IT IS FOR
//
// Without `aud`, nothing in a token distinguishes "an access token for
// this API" from any other RS256 token this issuer ever signs. Today that
// set has one member, so the gap is latent rather than exploited — but it
// is the gap that makes token confusion possible the moment a second
// purpose appears (a push-registration token, a short-lived download
// token, a token minted for a partner), because each would verify
// anywhere the others do. Adding it now is a one-line check; adding it
// after the second purpose exists is a migration.
//
// Verification is strict, not advisory: a token without this audience
// does not authenticate a request.
const audience = "professional-connections-api"

// Signer issues signed access tokens. Per ADR-001 §6 the GATEWAY holds the
// private key and constructs this — the monolith authenticates the request
// and returns identity facts (user_id, trust_level), and the gateway turns
// those into a token here. The blast radius if the monolith binary is ever
// compromised is smaller for it: that binary can't mint a token at all.
type Signer struct {
	privateKey *rsa.PrivateKey
	// kid is derived from this key's own public half (see kid.go) and
	// stamped into every token's header, so a Verifier holding several
	// public keys knows which one to check against without trial
	// verification.
	kid string
}

// NewSigner loads an RSA private key from privateKeyPath and fails fast if
// it can't be read or parsed — a key that won't parse should crash the
// process at startup, not surface as an error on the first request that
// needs to sign a token.
func NewSigner(privateKeyPath string) (*Signer, error) {
	raw, err := os.ReadFile(privateKeyPath) // #nosec G304 -- operator-configured key path (JWT_PRIVATE_KEY_PATH), never request input
	if err != nil {
		return nil, fmt.Errorf("jwt: read private key %q: %w", privateKeyPath, err)
	}

	key, err := jwtlib.ParseRSAPrivateKeyFromPEM(raw)
	if err != nil {
		return nil, fmt.Errorf("jwt: parse private key %q: %w", privateKeyPath, err)
	}

	kid, err := KeyID(&key.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("jwt: derive key id for %q: %w", privateKeyPath, err)
	}

	return &Signer{privateKey: key, kid: kid}, nil
}

// KeyID reports the `kid` this signer stamps into the tokens it issues.
// Logged once at startup so an operator mid-rotation can confirm which key
// is actually in use without decoding a token by hand.
func (s *Signer) KeyID() string { return s.kid }

// Sign issues a signed access token for claims. IssuedAt, ExpiresAt,
// Issuer and Audience are set here and override anything the caller
// supplied — callers are only responsible for UserID, TrustLevel, and
// optionally Subject.
func (s *Signer) Sign(claims Claims) (string, error) {
	now := time.Now()
	claims.IssuedAt = jwtlib.NewNumericDate(now)
	claims.ExpiresAt = jwtlib.NewNumericDate(now.Add(AccessTokenTTL))
	claims.Issuer = issuer
	claims.Audience = jwtlib.ClaimStrings{audience}
	if claims.Subject == "" {
		claims.Subject = claims.UserID
	}

	token := jwtlib.NewWithClaims(jwtlib.SigningMethodRS256, claims)
	// The `kid` header is what gives a key rotation an overlap window: the
	// verifier can hold the previous public key alongside the current one
	// and route each token to the key that actually signed it, so tokens
	// issued before the rotation keep working until they expire on their own
	// (§A3). Without it, the moment a new signing key deploys, every
	// outstanding access token is unverifiable.
	token.Header["kid"] = s.kid
	signed, err := token.SignedString(s.privateKey)
	if err != nil {
		return "", fmt.Errorf("jwt: sign: %w", err)
	}
	return signed, nil
}
