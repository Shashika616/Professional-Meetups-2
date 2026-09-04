package sms

import (
	"context"
	"log/slog"
	"strings"
)

// LoggingSmsSender logs the code instead of sending an SMS — the default
// sender for local dev and every automated test, used whenever Twilio's
// env vars are empty. Never logs the raw target number (self-review
// checklist: no raw phone/email in any log line) — a developer testing
// locally already knows which number they just entered, the code is the
// only thing they need from this log line.
type LoggingSmsSender struct{}

// NewLoggingSmsSender constructs a LoggingSmsSender.
func NewLoggingSmsSender() *LoggingSmsSender {
	return &LoggingSmsSender{}
}

func (s *LoggingSmsSender) SendVerificationCode(_ context.Context, _, code string) error {
	slog.Default().Info("verification code (LoggingSmsSender — not actually sent)",
		"purpose", "phone",
		"code", code,
	)
	return nil
}

// SendAlert (ADR-026 §2) — logs a redacted summary, never the raw target
// number or the message body itself. 2026-08-31 round-2 hardening: an SOS
// alert carries a real name, free-text context, and a precise-coordinate
// maps link — materially more sensitive than the 6-digit OTP codes this
// "log instead of send" dev pattern was originally designed for, so this
// deliberately logs less than SendVerificationCode does, not the same
// amount.
func (s *LoggingSmsSender) SendAlert(_ context.Context, _, message string) error {
	slog.Default().Info("sos alert sms (LoggingSmsSender — not actually sent)",
		"message_length", len(message),
		"contains_location_link", strings.Contains(message, "maps.google.com"),
	)
	return nil
}
