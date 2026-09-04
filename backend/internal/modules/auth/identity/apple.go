package identity

import "context"

const (
	appleJWKSURL = "https://appleid.apple.com/auth/keys"
	appleIssuer  = "https://appleid.apple.com"
)

// AppleProvider verifies Sign in with Apple id_tokens (ADR-014).
type AppleProvider struct{ *jwksProvider }

// NewAppleProvider constructs an AppleProvider, fetching Apple's published
// JWKS once synchronously (fails fast if unreachable) and refreshing it
// hourly thereafter — see newJWKSProvider's doc comment. servicesID is the
// configured Sign in with Apple Services ID (APPLE_SERVICES_ID) — the
// expected `aud` claim; an empty string is accepted (so the auth service
// still starts up before that credential exists) but Verify will then
// reject every token, never accept one.
func NewAppleProvider(ctx context.Context, servicesID string) (*AppleProvider, error) {
	p, err := newJWKSProvider(ctx, "apple", appleJWKSURL, servicesID, []string{appleIssuer})
	if err != nil {
		return nil, err
	}
	return &AppleProvider{p}, nil
}
