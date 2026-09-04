package sms

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	defaultBaseURL = "https://api.twilio.com/2010-04-01"

	// defaultTimeout is deliberately explicit — the zero-value http.Client
	// has no timeout at all, which would let a hung Twilio request block a
	// request-handling goroutine indefinitely (same reasoning as
	// internal/linkedin/client.go's defaultTimeout).
	defaultTimeout = 5 * time.Second
)

// TwilioSmsSender sends real verification texts via Twilio's plain
// Programmable Messaging API (not Twilio Verify — ADR-012's 2026-08-17
// correction). Hand-rolled over net/http rather than pulling in Twilio's
// full SDK — this only ever needs one endpoint, matching this project's
// "standard library first" pattern already established for
// internal/linkedin/client.go.
type TwilioSmsSender struct {
	accountSID string
	authToken  string
	fromNumber string
	httpClient *http.Client
	baseURL    string
}

// Option customizes a TwilioSmsSender — currently only used by tests to
// point at an httptest.Server instead of Twilio's real endpoint.
type Option func(*TwilioSmsSender)

// WithBaseURL overrides Twilio's API base URL. Test-only.
func WithBaseURL(u string) Option { return func(s *TwilioSmsSender) { s.baseURL = u } }

// NewTwilioSmsSender constructs a TwilioSmsSender. fromNumber must be a
// Twilio number provisioned for sending, in E.164 format.
func NewTwilioSmsSender(accountSID, authToken, fromNumber string, opts ...Option) *TwilioSmsSender {
	s := &TwilioSmsSender{
		accountSID: accountSID,
		authToken:  authToken,
		fromNumber: fromNumber,
		httpClient: &http.Client{Timeout: defaultTimeout},
		baseURL:    defaultBaseURL,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *TwilioSmsSender) SendVerificationCode(ctx context.Context, to, code string) error {
	return s.send(ctx, to, bodyFor(code))
}

// SendAlert (ADR-026 §2) reuses the exact same Twilio client wiring as
// SendVerificationCode — same endpoint, same auth, just free-text body
// instead of an OTP.
func (s *TwilioSmsSender) SendAlert(ctx context.Context, to, message string) error {
	return s.send(ctx, to, message)
}

func (s *TwilioSmsSender) send(ctx context.Context, to, body string) error {
	form := url.Values{
		"To":   {to},
		"From": {s.fromNumber},
		"Body": {body},
	}

	endpoint := fmt.Sprintf("%s/Accounts/%s/Messages.json", s.baseURL, s.accountSID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewBufferString(form.Encode()))
	if err != nil {
		return fmt.Errorf("sms: build twilio request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth(s.accountSID, s.authToken)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("sms: twilio request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusCreated {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("sms: twilio send failed with status %d: %s", resp.StatusCode, respBody)
	}

	return nil
}
