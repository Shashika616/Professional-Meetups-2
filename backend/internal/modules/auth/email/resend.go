package email

import (
	"context"
	"fmt"

	"github.com/resend/resend-go/v2"
)

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
func NewResendEmailSender(apiKey, fromEmail string) *ResendEmailSender {
	return &ResendEmailSender{client: resend.NewClient(apiKey), from: fromEmail}
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
