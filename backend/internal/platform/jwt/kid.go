package jwt

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"fmt"
)

// KeyID computes the stable `kid` for an RSA public key: a truncated
// SHA-256 over its PKIX DER encoding, base64url-encoded without padding.
//
// DERIVED, NOT CONFIGURED — this is the design decision that makes rotation
// operationally cheap (§A3). The alternative, an operator-assigned key id
// carried in its own environment variable, means every key has a name that
// has to be kept in sync across two processes and a deploy pipeline, and a
// mismatched name fails exactly like a wrong key while looking like a
// working config. Deriving the id from the key material means the signer and
// the verifier cannot disagree about which key is which: both compute it
// from the same bytes. Adding a previous key to the verifier is then one
// more file path and nothing else.
//
// Truncated to 16 bytes because a `kid` is a lookup key, not a security
// boundary — the signature is what authenticates the token. 128 bits is far
// past any accidental-collision concern for a set that holds two or three
// keys.
func KeyID(pub *rsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", fmt.Errorf("jwt: marshal public key for kid: %w", err)
	}
	sum := sha256.Sum256(der)
	return base64.RawURLEncoding.EncodeToString(sum[:16]), nil
}
