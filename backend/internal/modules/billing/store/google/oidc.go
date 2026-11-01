package google

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// certsURL is Google's published JWKS for OIDC ID tokens. Hard-coded.
const certsURL = "https://www.googleapis.com/oauth2/v3/certs"

// Google ID tokens carry either issuer spelling.
var issuers = map[string]bool{
	"https://accounts.google.com": true,
	"accounts.google.com":         true,
}

// jwksTTL is how long fetched keys are reused. Google rotates them over
// days; an unknown kid forces a refetch sooner.
const jwksTTL = time.Hour

// ErrBadToken is a push request whose OIDC token does not verify. The
// caller answers 401 and writes nothing.
var ErrBadToken = errors.New("google: push authorization does not verify")

// OIDCVerifier verifies the OIDC ID token Pub/Sub puts on a push request's
// Authorization header (RTDN). Ported from the source's
// webhookauth.GoogleOIDCVerifier, with the keys cached (the source fetched
// them on every request) and the audience required.
type OIDCVerifier struct {
	// Audience is the audience set on the push subscription. Required.
	Audience string
	// ServiceAccount, when set, must be the token's verified email: the
	// service account the push subscription authenticates as.
	ServiceAccount string
	// JWKS overrides where keys come from (tests). Nil means Google's.
	JWKS func(ctx context.Context) (map[string]*rsa.PublicKey, error)

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

// Verify checks authorization ("Bearer <token>") and returns the claims.
func (v *OIDCVerifier) Verify(ctx context.Context, authorization string) (jwt.MapClaims, error) {
	if v.Audience == "" {
		return nil, fmt.Errorf("%w: no audience configured", ErrBadToken)
	}
	raw, ok := strings.CutPrefix(authorization, "Bearer ")
	if !ok || raw == "" {
		return nil, fmt.Errorf("%w: missing or malformed Authorization header", ErrBadToken)
	}
	var claims jwt.MapClaims
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithAudience(v.Audience),
		jwt.WithExpirationRequired(),
	)
	token, err := parser.ParseWithClaims(raw, &claims, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("token header has no kid")
		}
		return v.key(ctx, kid)
	})
	if err != nil || !token.Valid {
		return nil, fmt.Errorf("%w: %v", ErrBadToken, err)
	}
	if iss, _ := claims["iss"].(string); !issuers[iss] {
		return nil, fmt.Errorf("%w: unexpected issuer %q", ErrBadToken, iss)
	}
	if v.ServiceAccount != "" {
		email, _ := claims["email"].(string)
		verified, _ := claims["email_verified"].(bool)
		if email != v.ServiceAccount || !verified {
			return nil, fmt.Errorf("%w: unexpected or unverified service account", ErrBadToken)
		}
	}
	return claims, nil
}

// key returns the signing key for kid, refetching once when it is unknown
// or the cache is stale.
func (v *OIDCVerifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if k, ok := v.keys[kid]; ok && time.Since(v.fetchedAt) < jwksTTL {
		return k, nil
	}
	source := v.JWKS
	if source == nil {
		source = FetchJWKS
	}
	keys, err := source(ctx)
	if err != nil {
		return nil, fmt.Errorf("fetch google jwks: %w", err)
	}
	v.keys, v.fetchedAt = keys, time.Now()
	k, ok := keys[kid]
	if !ok {
		return nil, fmt.Errorf("no google signing key for kid %q", kid)
	}
	return k, nil
}

// FetchJWKS fetches Google's current OIDC signing keys.
func FetchJWKS(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, certsURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("google certs endpoint returned status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return ParseJWKS(body)
}

type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// ParseJWKS decodes a JWKS document into kid -> RSA key, skipping non-RSA
// keys and failing on a malformed RSA one.
func ParseJWKS(data []byte) (map[string]*rsa.PublicKey, error) {
	var set struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.Unmarshal(data, &set); err != nil {
		return nil, fmt.Errorf("unmarshal jwks: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey, len(set.Keys))
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		n, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil {
			return nil, fmt.Errorf("parse key %q: decode modulus: %w", k.Kid, err)
		}
		e, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			return nil, fmt.Errorf("parse key %q: decode exponent: %w", k.Kid, err)
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	return keys, nil
}
