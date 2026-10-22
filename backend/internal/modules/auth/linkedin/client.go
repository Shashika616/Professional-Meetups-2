// Package linkedin implements this backend's half of the LinkedIn OIDC flow
// (ADR-011, PLAN.md Step 4): exchanging an authorization code for a
// LinkedIn access token, then fetching basic profile info. The LinkedIn
// access token returned by ExchangeCode must never be persisted — callers
// call FetchUserInfo once and discard it immediately after (ADR-003's
// minimal-retention principle, applied here to LinkedIn tokens too).
package linkedin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"time"
)

const (
	defaultTokenURL    = "https://www.linkedin.com/oauth/v2/accessToken" // #nosec G101 -- LinkedIn's public endpoint URL
	defaultUserInfoURL = "https://api.linkedin.com/v2/userinfo"

	// defaultTimeout is deliberately explicit — the zero-value http.Client
	// has no timeout at all, which would let a hung LinkedIn request block a
	// request-handling goroutine indefinitely.
	defaultTimeout = 5 * time.Second
)

// Config holds the confidential-client credentials this backend uses for
// its own exchange with LinkedIn (LINKEDIN_CLIENT_ID/SECRET) — see
// ExchangeCode's doc comment for why this alone (no PKCE) is the design.
type Config struct {
	ClientID     string
	ClientSecret string
}

// Client exchanges LinkedIn OIDC authorization codes for tokens and fetches
// basic profile info.
type Client struct {
	clientID     string
	clientSecret string
	httpClient   *http.Client
	tokenURL     string
	userInfoURL  string
}

// Option customizes a Client — currently only used by tests to point at an
// httptest.Server instead of LinkedIn's real endpoints.
type Option func(*Client)

// WithTokenURL overrides the OAuth token endpoint. Test-only.
func WithTokenURL(u string) Option { return func(c *Client) { c.tokenURL = u } }

// WithUserInfoURL overrides the OIDC userinfo endpoint. Test-only.
func WithUserInfoURL(u string) Option { return func(c *Client) { c.userInfoURL = u } }

// New constructs a Client with a timeout-bounded HTTP client.
func New(cfg Config, opts ...Option) *Client {
	c := &Client{
		clientID:     cfg.ClientID,
		clientSecret: cfg.ClientSecret,
		httpClient:   &http.Client{Timeout: defaultTimeout},
		tokenURL:     defaultTokenURL,
		userInfoURL:  defaultUserInfoURL,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// Token is LinkedIn's OAuth token response. It is never persisted — callers
// must discard it immediately after calling FetchUserInfo.
type Token struct {
	AccessToken string
	ExpiresIn   int
}

// UserInfo is the subset of LinkedIn's OIDC userinfo response this backend
// needs. Everything else in LinkedIn's response is discarded, consistent
// with the data-minimization principle applied throughout this project.
type UserInfo struct {
	Sub     string
	Name    string
	Picture string
	// Email is LinkedIn's verified address for this member, or "" when
	// LinkedIn did not return one or marked it unverified.
	//
	// This WAS discarded. The app has always asked for the `email` scope,
	// so members were consenting to share it on LinkedIn's own screen and
	// the backend dropped it at decode — paying the consent cost for
	// nothing, and leaving LinkedIn as the one provider that could not
	// recognise a returning member by their address.
	Email string
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
}

// ExchangeCode exchanges an authorization code (obtained by the mobile app)
// for a LinkedIn access token, using this backend's own client_secret for
// its confidential-client exchange.
//
// Deliberately no PKCE code_verifier: LinkedIn's Sign In with LinkedIn /
// OpenID Connect product rejects the exchange outright (401 invalid_client)
// when a code_challenge/code_verifier pair is present — confirmed via
// direct testing against LinkedIn's real endpoint, and consistent with
// LinkedIn's own /oauth/v2/accessToken docs not listing code_verifier as a
// supported parameter for this product. Security is still sound: this is a
// confidential client (the secret never leaves this service), which is
// exactly the property PKCE exists to substitute for on a public client.
func (c *Client) ExchangeCode(ctx context.Context, code, redirectURI string) (Token, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {redirectURI},
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
	}

	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost, c.tokenURL, bytes.NewBufferString(form.Encode()),
	)
	if err != nil {
		return Token{}, fmt.Errorf("linkedin: build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return Token{}, fmt.Errorf("linkedin: token exchange request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return Token{}, fmt.Errorf("linkedin: read token response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return Token{}, fmt.Errorf("linkedin: token exchange failed with status %d: %s", resp.StatusCode, body)
	}

	var parsed tokenResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return Token{}, fmt.Errorf("linkedin: parse token response: %w", err)
	}

	return Token(parsed), nil
}

type userInfoResponse struct {
	Sub     string `json:"sub"`
	Name    string `json:"name"`
	Picture string `json:"picture"`
	Email   string `json:"email"`
	// LinkedIn documents this as a JSON boolean. It is read through the
	// same tolerant decoder the Apple/Google path uses, because the cost of
	// being wrong is asymmetric: a provider that changes shape would
	// silently stop yielding emails, and silence is the failure mode this
	// whole feature exists to remove.
	EmailVerified identity.FlexibleBool `json:"email_verified"`
}

// FetchUserInfo calls LinkedIn's OIDC userinfo endpoint with token. Callers
// must discard token immediately after this call returns — it is never
// persisted.
func (c *Client) FetchUserInfo(ctx context.Context, token Token) (UserInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.userInfoURL, nil)
	if err != nil {
		return UserInfo{}, fmt.Errorf("linkedin: build userinfo request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return UserInfo{}, fmt.Errorf("linkedin: userinfo request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return UserInfo{}, fmt.Errorf("linkedin: read userinfo response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return UserInfo{}, fmt.Errorf("linkedin: userinfo request failed with status %d: %s", resp.StatusCode, body)
	}

	var parsed userInfoResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return UserInfo{}, fmt.Errorf("linkedin: parse userinfo response: %w", err)
	}

	// No longer a straight conversion: the two structs have deliberately
	// stopped matching field for field, because email is only carried
	// across when LinkedIn says it verified it. An address LinkedIn has not
	// verified is about to become an account's identity anchor if we let
	// it through, and an unverified one is just a string on a profile.
	info := UserInfo{
		Sub:     parsed.Sub,
		Name:    parsed.Name,
		Picture: parsed.Picture,
	}
	if bool(parsed.EmailVerified) {
		info.Email = identity.NormalizeEmail(parsed.Email)
	}
	return info, nil
}
