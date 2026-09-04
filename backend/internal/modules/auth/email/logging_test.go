package email

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// TestSendAlert_LoggingEmailSender confirms the dev/test fallback never
// errors — SendAlert on LoggingEmailSender just logs and returns nil, same
// shape as SendVerificationCode. No existing test file covered
// SendVerificationCode either before this ADR (a pre-existing gap, not
// introduced here) — this is the first test in this package.
func TestSendAlert_LoggingEmailSender(t *testing.T) {
	sender := NewLoggingEmailSender()
	if err := sender.SendAlert(context.Background(), "friend@example.com", "help"); err != nil {
		t.Fatalf("SendAlert() error: %v", err)
	}
}

// TestLoggingEmailSender_SendAlert_DoesNotLogFullMessageBody (2026-08-31
// round-2 hardening) — same finding/fix as sms.LoggingSmsSender's own
// test: confirms neither the raw target address nor the message body
// reach the log line, only a redacted length/contains-location-link
// summary.
func TestLoggingEmailSender_SendAlert_DoesNotLogFullMessageBody(t *testing.T) {
	var buf bytes.Buffer
	original := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(original) })

	sender := NewLoggingEmailSender()
	const target = "friend@example.com"
	const message = "Ada Lovelace may need help. At the meetup. Location: https://maps.google.com/?q=6.927100,79.861200"
	if err := sender.SendAlert(context.Background(), target, message); err != nil {
		t.Fatalf("SendAlert() error: %v", err)
	}

	logged := buf.String()
	if strings.Contains(logged, message) {
		t.Errorf("log line contains the full alert message body, want redacted: %s", logged)
	}
	if strings.Contains(logged, "Ada Lovelace") || strings.Contains(logged, "At the meetup") {
		t.Errorf("log line contains alert content (name/context), want redacted: %s", logged)
	}
	if strings.Contains(logged, target) {
		t.Errorf("log line contains the raw target address, want redacted: %s", logged)
	}
	if !strings.Contains(logged, "message_length") {
		t.Errorf("log line missing the redacted message_length summary field: %s", logged)
	}
}
