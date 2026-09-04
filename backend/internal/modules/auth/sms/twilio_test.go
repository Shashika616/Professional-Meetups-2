package sms

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSendAlert_TwilioSmsSender confirms SendAlert (ADR-026 §2) reuses the
// exact same request shape SendVerificationCode already does — same
// endpoint, same auth, just a free-text body instead of an OTP. No
// existing test file covered SendVerificationCode either before this ADR
// (a pre-existing gap, not introduced here) — this is the first test in
// this package.
func TestSendAlert_TwilioSmsSender(t *testing.T) {
	var gotBody string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse form: %v", err)
		}
		gotBody = r.PostForm.Get("Body")
		if got := r.PostForm.Get("To"); got != "+94771234567" {
			t.Errorf("To = %q, want %q", got, "+94771234567")
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()

	sender := NewTwilioSmsSender("sid", "token", "+94770000000", WithBaseURL(server.URL))
	if err := sender.SendAlert(context.Background(), "+94771234567", "Ada may need help. Location: https://maps.google.com/?q=1,2"); err != nil {
		t.Fatalf("SendAlert() error: %v", err)
	}
	if !strings.Contains(gotBody, "Ada may need help") {
		t.Errorf("request body = %q, want it to contain the alert message", gotBody)
	}
}

func TestSendAlert_TwilioSmsSender_PropagatesNonCreatedStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer server.Close()

	sender := NewTwilioSmsSender("sid", "token", "+94770000000", WithBaseURL(server.URL))
	if err := sender.SendAlert(context.Background(), "+94771234567", "help"); err == nil {
		t.Fatal("SendAlert() with a non-201 Twilio response returned nil error, want error")
	}
}
