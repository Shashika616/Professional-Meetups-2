package email

import (
	"context"
	"log/slog"
	"strings"
)

// LoggingEmailSender logs the code instead of sending an email — the
// default sender for local dev and every automated test (backend/PLAN.md's
// addendum, Step A/C-D), used whenever RESEND_API_KEY is empty. Never logs
// the raw target address (self-review checklist: no raw phone/email in any
// log line) — a developer testing locally already knows which address they
// just entered, the code is the only thing they need from this log line.
type LoggingEmailSender struct{}

// NewLoggingEmailSender constructs a LoggingEmailSender.
func NewLoggingEmailSender() *LoggingEmailSender {
	return &LoggingEmailSender{}
}

func (s *LoggingEmailSender) SendVerificationCode(_ context.Context, _, code string, purpose Purpose) error {
	slog.Default().Info("verification code (LoggingEmailSender — not actually sent)",
		"purpose", purpose,
		"code", code,
	)
	return nil
}

// SendAlert (ADR-026 §2) — logs a redacted summary, never the raw target
// address or the message body itself. 2026-08-31 round-2 hardening: an SOS
// alert carries a real name, free-text context, and a precise-coordinate
// maps link — materially more sensitive than the 6-digit OTP codes this
// "log instead of send" dev pattern was originally designed for, so this
// deliberately logs less than SendVerificationCode does, not the same
// amount.
func (s *LoggingEmailSender) SendAlert(_ context.Context, _, message string) error {
	slog.Default().Info("sos alert email (LoggingEmailSender — not actually sent)",
		"message_length", len(message),
		"contains_location_link", strings.Contains(message, "maps.google.com"),
	)
	return nil
}
