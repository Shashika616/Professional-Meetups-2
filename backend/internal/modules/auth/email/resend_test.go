package email

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

// TestResendEmailSender_HasAnExplicitTimeout is a regression guard for the
// timeout fix: resend-go's own default is one MINUTE, which is far too long
// for an OTP send (a user is waiting on a signup screen) and much too long
// for SendAlert, which sits on the SOS path behind bounded retries and a
// circuit breaker that all assume a send resolves quickly.
//
// It asserts behavior, not a field: a server that never responds must fail
// the call in about defaultTimeout, not hang for a minute.
func TestResendEmailSender_HasAnExplicitTimeout(t *testing.T) {
	blocked := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		<-blocked // never responds until the test tears down
	}))
	// Defer order matters and is LIFO: close(blocked) must run BEFORE
	// server.Close(), because Close waits for in-flight handlers to return
	// and this one is parked on that channel.
	defer server.Close()
	defer close(blocked)

	sender := NewResendEmailSender("test-api-key", "noreply@example.com")
	// resend-go reads its base URL from the env at package init, so point the
	// constructed client at the test server directly instead.
	sender.client.BaseURL = mustParseURL(t, server.URL)

	start := time.Now()
	err := sender.SendVerificationCode(context.Background(), "ada@example.com", "123456", PurposePersonalEmail)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("SendVerificationCode() against an unresponsive server returned nil error, want a timeout error")
	}
	// Generous upper bound: the point is "seconds, not the vendor's 60".
	if elapsed > 15*time.Second {
		t.Errorf("call took %v before failing — the vendor's default 1-minute timeout is still in effect", elapsed)
	}
	if elapsed < defaultTimeout/2 {
		t.Errorf("call failed after only %v, before the %v timeout could have elapsed — this test is not exercising the timeout",
			elapsed, defaultTimeout)
	}
}

// TestResendEmailSender_AlertPathSharesTheSameTimeout: SendAlert is the SOS
// path and goes through the same client, so it must inherit the same bound.
func TestResendEmailSender_AlertPathSharesTheSameTimeout(t *testing.T) {
	blocked := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		<-blocked
	}))
	defer server.Close()
	defer close(blocked)

	sender := NewResendEmailSender("test-api-key", "noreply@example.com")
	sender.client.BaseURL = mustParseURL(t, server.URL)

	start := time.Now()
	err := sender.SendAlert(context.Background(), "contact@example.com", "Ada may need help.")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("SendAlert() against an unresponsive server returned nil error, want a timeout error")
	}
	if elapsed > 15*time.Second {
		t.Errorf("SOS alert send took %v before failing — an emergency path must not wait on a vendor for a minute", elapsed)
	}
}

func mustParseURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	return parsed
}
