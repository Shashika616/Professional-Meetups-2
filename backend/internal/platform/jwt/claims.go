// Package jwt implements RS256 signing and verification of session tokens.
// Ported essentially unchanged from
// ../Professional-Meetups/backend/shared/jwt; what changed is WHO holds it
// (ADR-001 §6): in the sibling repo only the auth service constructed a
// Signer and everyone else a Verifier, whereas here this package is
// imported by the gateway process alone — which constructs BOTH, because it
// now issues tokens as well as verifying them. cmd/monolith never imports
// this package at all, and the monolith binary never holds the private key.
package jwt

import (
	jwtlib "github.com/golang-jwt/jwt/v5"
)

// Claims are the JWT claims issued for an authenticated session. UserID and
// TrustLevel are this project's own claims; RegisteredClaims carries the
// standard exp/iat/iss/sub claims (RFC 7519).
type Claims struct {
	UserID     string `json:"user_id"`
	TrustLevel int    `json:"trust_level"`
	jwtlib.RegisteredClaims
}
