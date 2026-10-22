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

// TestTwilioErrorCode is tracker #92 (review finding N-A9): Twilio's
// error payloads echo the request, which for this endpoint means the
// destination number and often the message body — an OTP, or an SOS
// alert naming a real person and their location. The error this sender
// returns is logged by every caller, so none of that may be in it.
func TestTwilioErrorCode(t *testing.T) {
	t.Run("keeps the code", func(t *testing.T) {
		body := strings.NewReader(
			`{"code":21211,"message":"The 'To' number +94771234567 is not a valid phone number.",` +
				`"more_info":"https://www.twilio.com/docs/errors/21211","status":400}`)
		if got := twilioErrorCode(body); got != 21211 {
			t.Errorf("twilioErrorCode() = %d, want 21211", got)
		}
	})

	t.Run("unparseable payloads report nothing rather than failing", func(t *testing.T) {
		for _, body := range []string{"", "<html>502 Bad Gateway</html>", "null"} {
			if got := twilioErrorCode(strings.NewReader(body)); got != 0 {
				t.Errorf("twilioErrorCode(%q) = %d, want 0", body, got)
			}
		}
	})
}

// The error text itself must carry neither the number nor the body.
func TestTwilioSendError_CarriesNoRecipientOrMessage(t *testing.T) {
	const (
		number  = "+94771234567"
		message = "Your code is 428913"
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(
			`{"code":21211,"message":"The 'To' number ` + number + ` is not valid. Body: ` +
				message + `","status":400}`))
	}))
	defer server.Close()

	sender := NewTwilioSmsSender("AC123", "token", "+15550000000", WithBaseURL(server.URL))
	err := sender.SendVerificationCode(context.Background(), number, "428913")
	if err == nil {
		t.Fatal("a 400 from Twilio was not reported as an error")
	}
	if strings.Contains(err.Error(), number) {
		t.Errorf("error %q contains the recipient's number", err)
	}
	if strings.Contains(err.Error(), message) || strings.Contains(err.Error(), "428913") {
		t.Errorf("error %q contains the message body", err)
	}
	if !strings.Contains(err.Error(), "21211") {
		t.Errorf("error %q dropped Twilio's error code, which is what identifies the failure", err)
	}
}
