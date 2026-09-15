package notification

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// newTestSender points an FCMPushSender at a stub server instead of Google's,
// bypassing the credential path (which needs a real service account) while
// exercising every line of request building, response classification and
// concurrency that actually matters here.
func newTestSender(t *testing.T, handler http.Handler) *FCMPushSender {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return &FCMPushSender{
		projectID:  "test-project",
		httpClient: server.Client(),
		baseURL:    server.URL,
	}
}

// TestSendToTokens_OneBadTokenDoesNotStopTheOthers is the fault-tolerance
// contract carried over from the source: a user's expired tablet token must
// not cost them the notification on their phone.
func TestSendToTokens_OneBadTokenDoesNotStopTheOthers(t *testing.T) {
	var attempted sync.Map
	sender := newTestSender(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var msg fcmMessage
		_ = json.NewDecoder(r.Body).Decode(&msg)
		attempted.Store(msg.Message.Token, true)

		if msg.Message.Token == "bad-token" {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"code":500,"status":"INTERNAL"}}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))

	tokens := []string{"good-1", "bad-token", "good-2"}
	if err := sender.SendToTokens(context.Background(), tokens, "Title", "Body", nil); err != nil {
		t.Fatalf("SendToTokens returned an error even though two tokens succeeded: %v", err)
	}

	for _, token := range tokens {
		if _, ok := attempted.Load(token); !ok {
			t.Errorf("token %q was never attempted — a failure on one token stopped the others", token)
		}
	}
}

// TestSendToTokens_ErrorNeverContainsARawToken guards the discipline the
// whole module is written around. The source's version returned FCM's raw
// response body on a non-200, and FCM echoes the offending registration
// token back inside an INVALID_ARGUMENT message — so the source's error
// could carry a live device token into any log that recorded it.
func TestSendToTokens_ErrorNeverContainsARawToken(t *testing.T) {
	const secretToken = "SUPER-SECRET-DEVICE-TOKEN-abc123"

	sender := newTestSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		// FCM echoing the token back, exactly as it does in real
		// INVALID_ARGUMENT responses.
		_, _ = fmt.Fprintf(w, `{"error":{"code":500,"status":"INTERNAL","message":"failed for token %s"}}`, secretToken)
	}))

	err := sender.SendToTokens(context.Background(), []string{secretToken}, "Title", "Body", nil)
	if err == nil {
		t.Fatal("expected an error when every token failed")
	}
	if strings.Contains(err.Error(), secretToken) {
		t.Fatalf("the returned error contains a raw device token: %q", err)
	}

	// The same guarantee for the typed per-token error, which DOES carry the
	// token as a field so the caller can delete it, but must never render it.
	tokenErr := &TokenError{Token: secretToken, Err: ErrTokenUnregistered}
	if strings.Contains(tokenErr.Error(), secretToken) {
		t.Fatalf("TokenError.Error() renders the raw token: %q", tokenErr)
	}
}

// TestSendToTokensDetailed_ClassifiesUnregisteredTokens is §E2c's core
// distinction. Getting the direction wrong in one of these two cases
// silently deletes a live user's device.
func TestSendToTokensDetailed_ClassifiesUnregisteredTokens(t *testing.T) {
	tests := []struct {
		name           string
		status         int
		body           string
		wantPermanent  bool
		wantReasonNote string
	}{
		{
			name:          "UNREGISTERED in details is permanent",
			status:        http.StatusNotFound,
			body:          `{"error":{"code":404,"status":"NOT_FOUND","message":"Requested entity was not found.","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}`,
			wantPermanent: true,
		},
		{
			name:          "NOT_FOUND status alone is permanent",
			status:        http.StatusNotFound,
			body:          `{"error":{"code":404,"status":"NOT_FOUND","message":"Requested entity was not found."}}`,
			wantPermanent: true,
		},
		{
			name:          "INVALID_ARGUMENT naming the registration token is permanent",
			status:        http.StatusBadRequest,
			body:          `{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"The registration token is not a valid FCM registration token"}}`,
			wantPermanent: true,
		},
		{
			// The case that would be a self-inflicted outage if misread:
			// FCM returns INVALID_ARGUMENT for a malformed MESSAGE too, and
			// deleting every recipient's token because the notification body
			// was wrong would unsubscribe the whole user base at once.
			name:           "INVALID_ARGUMENT about the message body is NOT permanent",
			status:         http.StatusBadRequest,
			body:           `{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Invalid value at 'message.notification.title'"}}`,
			wantPermanent:  false,
			wantReasonNote: "a malformed message must never delete anyone's device token",
		},
		{
			name:           "429 rate limiting is transient",
			status:         http.StatusTooManyRequests,
			body:           `{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}`,
			wantPermanent:  false,
			wantReasonNote: "rate limiting is temporary by definition",
		},
		{
			name:           "500 is transient",
			status:         http.StatusInternalServerError,
			body:           `{"error":{"code":500,"status":"INTERNAL"}}`,
			wantPermanent:  false,
			wantReasonNote: "FCM having a bad day must not cost users their registrations",
		},
		{
			name:           "503 is transient",
			status:         http.StatusServiceUnavailable,
			body:           `{"error":{"code":503,"status":"UNAVAILABLE"}}`,
			wantPermanent:  false,
			wantReasonNote: "an unavailable dependency is the definition of retryable",
		},
		{
			name:           "an unparseable body is treated as transient",
			status:         http.StatusBadGateway,
			body:           `<html>502 Bad Gateway</html>`,
			wantPermanent:  false,
			wantReasonNote: "a response we cannot interpret justifies nothing, least of all a deletion",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			sender := newTestSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))

			result, err := sender.SendToTokensDetailed(context.Background(), []string{"a-token"}, "T", "B", nil)
			if err != nil {
				t.Fatalf("SendToTokensDetailed: %v", err)
			}

			gotPermanent := len(result.Unregistered) == 1
			if gotPermanent != tc.wantPermanent {
				note := tc.wantReasonNote
				if note == "" {
					note = "this response means the token will never work again"
				}
				t.Errorf("classified as permanently-dead = %v, want %v — %s", gotPermanent, tc.wantPermanent, note)
			}
			if !tc.wantPermanent && result.LastErr == nil {
				t.Error("a transient failure produced no error to retry on")
			}
		})
	}
}

// TestSendToTokens_BoundedConcurrency is §E2b's requirement: a large fan-out
// must not take (recipients x per-call latency).
//
// 500 recipients is the nearby-notify cap, and 20ms is a modest stand-in for
// a real FCM round trip. Sequentially that is 10 seconds; with the bounded
// worker pool it should be roughly 500/10 x 20ms = 1s. The assertion is
// deliberately loose (under 4s) so it fails only on a genuine regression to
// serial sending, not on a slow CI machine.
func TestSendToTokens_BoundedConcurrency(t *testing.T) {
	const (
		recipients  = 500
		perCall     = 20 * time.Millisecond
		sequential  = recipients * perCall // 10s
		generousCap = 4 * time.Second
	)

	var inFlight, maxInFlight int64
	sender := newTestSender(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		cur := atomic.AddInt64(&inFlight, 1)
		for {
			observed := atomic.LoadInt64(&maxInFlight)
			if cur <= observed || atomic.CompareAndSwapInt64(&maxInFlight, observed, cur) {
				break
			}
		}
		time.Sleep(perCall)
		atomic.AddInt64(&inFlight, -1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))

	tokens := make([]string, recipients)
	for i := range tokens {
		tokens[i] = fmt.Sprintf("token-%d", i)
	}

	start := time.Now()
	if err := sender.SendToTokens(context.Background(), tokens, "Title", "Body", nil); err != nil {
		t.Fatalf("SendToTokens: %v", err)
	}
	elapsed := time.Since(start)

	if elapsed > generousCap {
		t.Errorf("a %d-recipient batch took %v (sequential would be ~%v) — sends are not being parallelised", recipients, elapsed, sequential)
	}
	// The other half of "bounded": concurrency must be capped, not unbounded.
	// 500 simultaneous outbound requests to one third party is its own
	// problem, and would also mean 500 goroutines per outbox row.
	if got := atomic.LoadInt64(&maxInFlight); got > maxConcurrentSends {
		t.Errorf("peak concurrent sends = %d, want at most %d — the worker pool is not bounding fan-out", got, maxConcurrentSends)
	}
	t.Logf("500 recipients delivered in %v with peak concurrency %d (sequential would be ~%v)",
		elapsed, atomic.LoadInt64(&maxInFlight), sequential)
}

// TestSendToTokens_EmptyTokenListIsNotAnError pins the documented no-op.
func TestSendToTokens_EmptyTokenListIsNotAnError(t *testing.T) {
	sender := newTestSender(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("no HTTP request should be made for an empty token list")
	}))
	if err := sender.SendToTokens(context.Background(), nil, "T", "B", nil); err != nil {
		t.Errorf("SendToTokens(nil) = %v, want nil", err)
	}
}

// TestSendToTokens_RequestShapeMatchesFCMHTTPv1 pins the wire format. A
// silently malformed request would fail identically to a credentials problem
// and be diagnosed as one.
func TestSendToTokens_RequestShapeMatchesFCMHTTPv1(t *testing.T) {
	var gotPath, gotContentType string
	var gotBody fcmMessage

	sender := newTestSender(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotContentType = r.Header.Get("Content-Type")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))

	data := map[string]string{"meetup_id": "m-1"}
	if err := sender.SendToTokens(context.Background(), []string{"tok"}, "Title", "Body", data); err != nil {
		t.Fatalf("SendToTokens: %v", err)
	}

	if want := "/v1/projects/test-project/messages:send"; gotPath != want {
		t.Errorf("path = %q, want %q", gotPath, want)
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotContentType)
	}
	if gotBody.Message.Token != "tok" {
		t.Errorf("token = %q, want tok", gotBody.Message.Token)
	}
	if gotBody.Message.Notification.Title != "Title" || gotBody.Message.Notification.Body != "Body" {
		t.Errorf("notification = %+v, want Title/Body", gotBody.Message.Notification)
	}
	// The Android icon and accent ride on every message, so a notification
	// rendered by the system shows the app's mark, not a grey square.
	if got := gotBody.Message.Android.Notification; got.Icon != "ic_stat_notification" || got.Color != "#34C24C" {
		t.Errorf("android.notification = %+v, want icon ic_stat_notification and colour #34C24C", got)
	}
	if gotBody.Message.Data["meetup_id"] != "m-1" {
		t.Errorf("data = %v, want meetup_id=m-1", gotBody.Message.Data)
	}
}
