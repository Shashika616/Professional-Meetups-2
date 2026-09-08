package jwt

import (
	"crypto/rsa"
	"fmt"
	"os"

	jwtlib "github.com/golang-jwt/jwt/v5"
)

// Verifier checks access tokens using only public keys — it can never mint
// a token. The gateway constructs one of these alongside a Signer
// (ADR-001 §6): it verifies the bearer token on every authenticated route,
// and signs a new one whenever the monolith reports a successful
// authentication.
//
// # WHY A SET OF KEYS, NOT ONE (§A3)
//
// A Verifier holds the CURRENT public key plus any number of PREVIOUS ones,
// indexed by the `kid` derived from each key's own bytes (see kid.go). This
// is what makes rotating the JWT signing key a routine deploy instead of a
// forced logout of every signed-in user:
//
//  1. Deploy the gateway with the new key as JWT_PRIVATE_KEY_PATH/
//     JWT_PUBLIC_KEY_PATH and the OLD public key listed in
//     JWT_PREVIOUS_PUBLIC_KEY_PATHS. New tokens are signed with the new key;
//     tokens already in users' hands still verify against the old one.
//  2. Wait out AccessTokenTTL (15 minutes) plus a margin. Every token signed
//     by the old key has now expired on its own.
//  3. Deploy again with JWT_PREVIOUS_PUBLIC_KEY_PATHS removed. The old key
//     is fully retired.
//
// Refresh tokens are unaffected by any of this: they were never JWTs
// (ADR-001's §6 correction) — they are opaque, DB-backed, and carry no
// signature to verify.
type Verifier struct {
	// byKID routes a token to the key that signed it. Populated for every
	// configured key, current and previous.
	byKID map[string]*rsa.PublicKey
	// current is the key a token WITHOUT a `kid` header is checked against.
	// See the keyfunc below for why that fallback exists and why it is safe.
	current *rsa.PublicKey
}

// NewVerifier loads the current public key from publicKeyPath, plus any
// previous public keys still inside their overlap window, and fails fast if
// any of them can't be read or parsed. A key that won't parse should crash
// the process at startup, not surface as an authentication failure on the
// first request.
func NewVerifier(publicKeyPath string, previousPublicKeyPaths ...string) (*Verifier, error) {
	current, err := loadPublicKey(publicKeyPath)
	if err != nil {
		return nil, err
	}

	v := &Verifier{byKID: make(map[string]*rsa.PublicKey), current: current}
	if err := v.add(publicKeyPath, current); err != nil {
		return nil, err
	}

	for _, path := range previousPublicKeyPaths {
		key, err := loadPublicKey(path)
		if err != nil {
			return nil, err
		}
		if err := v.add(path, key); err != nil {
			return nil, err
		}
	}

	return v, nil
}

func (v *Verifier) add(path string, key *rsa.PublicKey) error {
	kid, err := KeyID(key)
	if err != nil {
		return fmt.Errorf("jwt: derive key id for %q: %w", path, err)
	}
	// A duplicate kid means the same key was configured twice — most likely
	// a previous-key path that was never actually rotated away from. Harmless
	// to the verification result, but it means an operator believes a
	// rotation happened that didn't, so say so rather than absorbing it.
	if _, exists := v.byKID[kid]; exists {
		return fmt.Errorf("jwt: public key %q is already configured under the same key id — the current and previous keys are identical, so no rotation has actually taken place", path)
	}
	v.byKID[kid] = key
	return nil
}

func loadPublicKey(path string) (*rsa.PublicKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("jwt: read public key %q: %w", path, err)
	}
	key, err := jwtlib.ParseRSAPublicKeyFromPEM(raw)
	if err != nil {
		return nil, fmt.Errorf("jwt: parse public key %q: %w", path, err)
	}
	return key, nil
}

// KeyIDs reports every key id this verifier accepts. Logged at startup so a
// rotation can be confirmed from the logs rather than inferred.
func (v *Verifier) KeyIDs() []string {
	ids := make([]string, 0, len(v.byKID))
	for kid := range v.byKID {
		ids = append(ids, kid)
	}
	return ids
}

// Verify parses token and returns its claims if the signature, expiry, and
// issuer all check out. Only RS256-signed tokens are accepted — an
// algorithm mismatch (e.g. a forged "none" or HS256 token) is rejected
// before the signature is even checked.
func (v *Verifier) Verify(token string) (Claims, error) {
	var claims Claims
	parsed, err := jwtlib.ParseWithClaims(token, &claims, v.keyfunc,
		jwtlib.WithValidMethods([]string{jwtlib.SigningMethodRS256.Alg()}),
		jwtlib.WithIssuer(issuer))
	if err != nil {
		return Claims{}, fmt.Errorf("jwt: verify: %w", err)
	}
	if !parsed.Valid {
		return Claims{}, fmt.Errorf("jwt: token invalid")
	}

	return claims, nil
}

// keyfunc selects the public key to check a token's signature against.
//
// A `kid` the verifier doesn't know is an ERROR, not a fallback to trying
// every key: a token signed by a retired or foreign key should be rejected
// as such, and silently searching the whole set would make "the old key was
// removed" indistinguishable from "the token was fine."
//
// A token with NO `kid` at all falls back to the current key. That is the
// upgrade path, not a loophole: access tokens minted by the version of this
// code that predates kid.go carry no header, and they stay valid for up to
// AccessTokenTTL after the deploy that introduces it. Signature verification
// is unchanged either way — the fallback only chooses which key to check
// against, and a token that wasn't signed by that key still fails. The
// clause can be deleted once no pre-rotation token can still be alive.
func (v *Verifier) keyfunc(t *jwtlib.Token) (any, error) {
	raw, present := t.Header["kid"]
	if !present {
		return v.current, nil
	}

	kid, ok := raw.(string)
	if !ok {
		return nil, fmt.Errorf("jwt: token kid header is not a string")
	}
	key, known := v.byKID[kid]
	if !known {
		return nil, fmt.Errorf("jwt: token signed by unknown key id")
	}
	return key, nil
}
