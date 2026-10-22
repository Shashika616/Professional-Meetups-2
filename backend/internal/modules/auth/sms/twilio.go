package sms

import (
	"bytes"
	"context"
	"encoding/json"
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
		// # THE BODY IS NOT IN THE ERROR (tracker #92, finding N-A9)
		//
		// Twilio's error payloads echo the request back, which for this
		// endpoint means the destination phone number and, on some
		// failures, the message body — an OTP, or an SOS alert naming a
		// real person and their location. This error gets wrapped and
		// logged by every caller, so putting that payload in it writes
		// exactly the data this service is careful about everywhere else
		// into logs that a wider set of people can read.
		//
		// The status code and Twilio's own error CODE (a stable integer,
		// no personal data) are what anyone debugging actually needs:
		// 21211 is a malformed number, 21608 an unverified trial
		// recipient, 20003 bad credentials. The body adds nothing but
		// exposure.
		//
		// Still drained before closing, so the connection is reusable.
		code := twilioErrorCode(resp.Body)
		if code != 0 {
			return fmt.Errorf("sms: twilio send failed with status %d (twilio error %d)",
				resp.StatusCode, code)
		}
		return fmt.Errorf("sms: twilio send failed with status %d", resp.StatusCode)
	}

	return nil
}

// twilioErrorCode pulls the numeric `code` out of a Twilio error payload
// and discards everything else (#92).
//
// Twilio replies to a failure with JSON that echoes the request,
// including the destination number and often the message body. Only the
// code crosses back out of this function: it identifies the failure
// precisely (21211 malformed number, 21608 unverified trial recipient,
// 20003 bad credentials) and contains nothing about the recipient.
//
// Returns 0 when the payload is missing, unreadable or not JSON, which
// the caller reports as a bare status code. A redaction helper that
// errored would be worse than one that says less.
func twilioErrorCode(body io.Reader) int {
	var payload struct {
		Code int `json:"code"`
	}
	// Bounded: an error payload is small, and this must not become a way
	// to make the service read an unbounded response.
	limited := io.LimitReader(body, 8<<10)
	if err := json.NewDecoder(limited).Decode(&payload); err != nil {
		return 0
	}
	return payload.Code
}
