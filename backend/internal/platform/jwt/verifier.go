package jwt

import (
	"crypto/rsa"
	"fmt"
	"os"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

// Verifier checks access tokens using only the public key — it can never
// mint a token. The gateway constructs one of these alongside a Signer
// (ADR-001 §6): it verifies the bearer token on every authenticated route,
// and signs a new one whenever the monolith reports a successful
// authentication.
type Verifier struct {
	publicKey *rsa.PublicKey
}

// NewVerifier loads an RSA public key from publicKeyPath and fails fast if
// it can't be read or parsed.
func NewVerifier(publicKeyPath string) (*Verifier, error) {
	raw, err := os.ReadFile(publicKeyPath)
	if err != nil {
		return nil, fmt.Errorf("jwt: read public key %q: %w", publicKeyPath, err)
	}

	key, err := jwtlib.ParseRSAPublicKeyFromPEM(raw)
	if err != nil {
		return nil, fmt.Errorf("jwt: parse public key %q: %w", publicKeyPath, err)
	}

	return &Verifier{publicKey: key}, nil
}

// Verify parses token and returns its claims if the signature, expiry, and
// issuer all check out. Only RS256-signed tokens are accepted — an
// algorithm mismatch (e.g. a forged "none" or HS256 token) is rejected
// before the signature is even checked.
func (v *Verifier) Verify(token string) (Claims, error) {
	var claims Claims
	parsed, err := jwtlib.ParseWithClaims(token, &claims, func(t *jwtlib.Token) (any, error) {
		return v.publicKey, nil
	}, jwtlib.WithValidMethods([]string{jwtlib.SigningMethodRS256.Alg()}), jwtlib.WithIssuer(issuer))
	if err != nil {
		return Claims{}, fmt.Errorf("jwt: verify: %w", err)
	}
	if !parsed.Valid {
		return Claims{}, fmt.Errorf("jwt: token invalid")
	}

	return claims, nil
}
