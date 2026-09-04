package identity

import "context"

const googleJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"

// googleIssuers: Google legitimately signs id_tokens with either form —
// confirmed against Google's own OpenID configuration
// (accounts.google.com/.well-known/openid-configuration lists
// "https://accounts.google.com" as issuer, but Google's tokens have
// historically also used the bare host form; both are treated as valid by
// Google's own tokeninfo endpoint).
var googleIssuers = []string{"accounts.google.com", "https://accounts.google.com"}

// GoogleProvider verifies Google Sign-In id_tokens (ADR-014).
type GoogleProvider struct{ *jwksProvider }

// NewGoogleProvider constructs a GoogleProvider — see NewAppleProvider's
// doc comment for the construction-time JWKS fetch/refresh behavior.
// clientID is the configured Google OAuth 2.0 client ID
// (GOOGLE_CLIENT_ID) — the expected `aud` claim; an empty string is
// accepted (so the auth service still starts up before that credential
// exists) but Verify will then reject every token, never accept one.
func NewGoogleProvider(ctx context.Context, clientID string) (*GoogleProvider, error) {
	p, err := newJWKSProvider(ctx, "google", googleJWKSURL, clientID, googleIssuers)
	if err != nil {
		return nil, err
	}
	return &GoogleProvider{p}, nil
}
