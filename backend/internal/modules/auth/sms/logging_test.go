package sms

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// TestSendAlert_LoggingSmsSender confirms the dev/test fallback never
// errors — SendAlert on LoggingSmsSender just logs and returns nil, same
// shape as SendVerificationCode.
func TestSendAlert_LoggingSmsSender(t *testing.T) {
	sender := NewLoggingSmsSender()
	if err := sender.SendAlert(context.Background(), "+94771234567", "help"); err != nil {
		t.Fatalf("SendAlert() error: %v", err)
	}
}

// TestLoggingSmsSender_SendAlert_DoesNotLogFullMessageBody (2026-08-31
// round-2 hardening) — an SOS alert body carries a real name, free-text
// context, and a precise-coordinate maps link, materially more sensitive
// than the OTP codes this dev-fallback pattern was designed for; confirms
// neither the raw target number nor the message body reach the log line,
// only a redacted length/contains-location-link summary.
func TestLoggingSmsSender_SendAlert_DoesNotLogFullMessageBody(t *testing.T) {
	var buf bytes.Buffer
	original := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(original) })

	sender := NewLoggingSmsSender()
	const target = "+94771234567"
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
		t.Errorf("log line contains the raw target number, want redacted: %s", logged)
	}
	if !strings.Contains(logged, "message_length") {
		t.Errorf("log line missing the redacted message_length summary field: %s", logged)
	}
}
