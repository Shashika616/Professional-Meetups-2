package email

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/resend/resend-go/v2"
)

// defaultTimeout bounds every Resend API call, matching sms/twilio.go's
// constant of the same name and for the same reason: one hung third-party
// dependency must not tie up a request-handling goroutine indefinitely.
//
// Unlike the Twilio sender — which builds its own zero-value http.Client and
// so genuinely had none — resend-go does set a timeout of its own, but it is
// one MINUTE (its package-level defaultHTTPClient). That is far too long for
// either call site here: an OTP send blocks a user staring at a signup
// screen, and SendAlert is on the SOS path, where the whole design is
// bounded retries plus a circuit breaker so an emergency resolves inside one
// RPC. A 60s stall per attempt would blow through both. Same 5s as Twilio,
// deliberately — these are the same class of call (a single small POST to a
// vendor API) and there is no reason for Resend to get a different budget.
const defaultTimeout = 5 * time.Second

// ResendEmailSender sends real verification emails via Resend
// (resend.com), wired up by main.go only when RESEND_API_KEY and
// RESEND_FROM_EMAIL are both non-empty (backend/PLAN.md's addendum, Step
// A). RESEND_FROM_EMAIL can be Resend's sandbox address
// (onboarding@resend.dev) before a domain is verified — that only limits
// delivery to the account's own inbox, it doesn't stop this from working
// for local testing.
type ResendEmailSender struct {
	client *resend.Client
	from   string
}

// NewResendEmailSender constructs a ResendEmailSender using apiKey for
// authentication and fromEmail as the sender address on every message.
//
// NewCustomClient rather than NewClient: that is resend-go's own injection
// point for an http.Client, and it is the only way to override the vendor's
// 1-minute default timeout (see defaultTimeout above).
func NewResendEmailSender(apiKey, fromEmail string) *ResendEmailSender {
	httpClient := &http.Client{Timeout: defaultTimeout}
	return &ResendEmailSender{client: resend.NewCustomClient(httpClient, apiKey), from: fromEmail}
}

func (s *ResendEmailSender) SendVerificationCode(ctx context.Context, to, code string, purpose Purpose) error {
	subject, body := subjectAndBodyFor(code, purpose)
	return s.send(ctx, to, subject, body)
}

// SendAlert (ADR-026 §2) reuses the exact same Resend client wiring as
// SendVerificationCode.
func (s *ResendEmailSender) SendAlert(ctx context.Context, to, message string) error {
	return s.send(ctx, to, sosAlertSubject, message)
}

func (s *ResendEmailSender) send(ctx context.Context, to, subject, body string) error {
	_, err := s.client.Emails.SendWithContext(ctx, &resend.SendEmailRequest{
		From:    s.from,
		To:      []string{to},
		Subject: subject,
		Text:    body,
	})
	if err != nil {
		return fmt.Errorf("email: resend send: %w", err)
	}
	return nil
}
