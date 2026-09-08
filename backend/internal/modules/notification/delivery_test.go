package notification

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"

	"professional-meetups-monolith/backend/internal/platform/breaker"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

func discardLogger() *slog.Logger { return slog.New(slog.DiscardHandler) }

// --- test doubles ----------------------------------------------------------

type stubSender struct {
	mu    sync.Mutex
	calls int
	err   error
	// result, when set, is returned from SendToTokensDetailed — used to
	// simulate per-token outcomes without an HTTP server.
	result *SendResult
}

func (s *stubSender) SendToTokens(context.Context, []string, string, string, map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	return s.err
}

func (s *stubSender) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

type detailedStubSender struct {
	stubSender
}

func (s *detailedStubSender) SendToTokensDetailed(context.Context, []string, string, string, map[string]string) (SendResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.result != nil {
		return *s.result, nil
	}
	if s.err != nil {
		return SendResult{LastErr: s.err}, nil
	}
	return SendResult{Delivered: 1}, nil
}

type recordingCleaner struct {
	mu      sync.Mutex
	deleted []string
	err     error
}

func (c *recordingCleaner) DeleteToken(_ context.Context, token string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return c.err
	}
	c.deleted = append(c.deleted, token)
	return nil
}

func (c *recordingCleaner) list() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.deleted...)
}

func rowFor(t *testing.T, payload Payload) outbox.Row {
	t.Helper()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return outbox.Row{ID: "row-1", Payload: encoded}
}

// --- §E2b: the circuit breaker --------------------------------------------

// TestDelivery_BreakerTripsAndStopsAttemptingSends is §E2b's requirement,
// and the assertion that matters is the LAST one: once the breaker is open,
// the sender must not be called at all.
//
// Without it, a degraded FCM costs a full 5-second timeout on every send in
// every claimed batch — the poller spends all its time waiting on a service
// already known to be down while the pending set grows behind it. Fast
// failure is what lets the backoff schedule do its job.
func TestDelivery_BreakerTripsAndStopsAttemptingSends(t *testing.T) {
	sender := &stubSender{err: errors.New("fcm is down")}
	d := NewDelivery(sender, nil, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"tok"}, Title: "T", Body: "B"})

	// Drive it to the failure threshold. Each of these should reach FCM.
	for i := 0; i < fcmBreakerFailureThreshold; i++ {
		if err := d.Process(context.Background(), row); err == nil {
			t.Fatalf("attempt %d: Process returned nil for a failing sender", i+1)
		}
	}
	if got := sender.callCount(); got != fcmBreakerFailureThreshold {
		t.Fatalf("sender was called %d times before the threshold, want %d", got, fcmBreakerFailureThreshold)
	}

	// The breaker is now open. Further attempts must fail WITHOUT calling
	// the sender — this is the cross-call memory that makes it a breaker
	// rather than a per-call retry policy.
	for i := 0; i < 3; i++ {
		err := d.Process(context.Background(), row)
		if err == nil {
			t.Fatal("Process returned nil while the breaker was open")
		}
		if !errors.Is(err, breaker.ErrOpen) {
			t.Errorf("error = %v, want it to wrap breaker.ErrOpen", err)
		}
	}
	if got := sender.callCount(); got != fcmBreakerFailureThreshold {
		t.Errorf("sender was called %d times, want it to stay at %d — the open breaker is still letting calls through to a dependency known to be down", got, fcmBreakerFailureThreshold)
	}
}

// TestDelivery_BreakerOpenErrorIsRetryable pins the interaction between the
// breaker and the outbox's retry policy: a row not attempted because the
// breaker was open must be RETRIED, never dead-lettered. Treating "we didn't
// try" as "this can never work" would discard real notifications during a
// transient FCM outage.
func TestDelivery_BreakerOpenErrorIsRetryable(t *testing.T) {
	sender := &stubSender{err: errors.New("fcm is down")}
	d := NewDelivery(sender, nil, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"tok"}, Title: "T", Body: "B"})

	for i := 0; i < fcmBreakerFailureThreshold; i++ {
		_ = d.Process(context.Background(), row)
	}

	err := d.Process(context.Background(), row)
	if errors.Is(err, outbox.ErrPermanent) {
		t.Fatal("a row skipped because the breaker was open was classified as permanently undeliverable — an FCM outage would silently discard notifications")
	}
}

// TestDelivery_BreakerDoesNotTripOnPartialSuccess covers the judgement call
// in what counts as a failure: if ANY token in a batch succeeded, FCM is
// evidently up, and the breaker must not open just because one device was
// unreachable.
func TestDelivery_BreakerDoesNotTripOnPartialSuccess(t *testing.T) {
	sender := &detailedStubSender{}
	sender.result = &SendResult{Delivered: 1, LastErr: errors.New("one device failed")}
	d := NewDelivery(sender, nil, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"good", "bad"}, Title: "T", Body: "B"})

	for i := 0; i < fcmBreakerFailureThreshold+3; i++ {
		if err := d.Process(context.Background(), row); err != nil {
			t.Fatalf("attempt %d: Process = %v, want nil (partial success is success)", i+1, err)
		}
	}
	if got := sender.callCount(); got != fcmBreakerFailureThreshold+3 {
		t.Errorf("sender called %d times, want every attempt to reach it — the breaker opened on batches that were actually succeeding", got)
	}
}

// --- §E2c: dead-token cleanup ---------------------------------------------

// TestDelivery_UnregisteredTokenIsDeletedExactlyOnce is §E2c's first
// required assertion.
func TestDelivery_UnregisteredTokenIsDeletedExactlyOnce(t *testing.T) {
	sender := &detailedStubSender{}
	sender.result = &SendResult{Delivered: 1, Unregistered: []string{"dead-token"}}
	cleaner := &recordingCleaner{}

	d := NewDelivery(sender, cleaner, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"live-token", "dead-token"}, Title: "T", Body: "B"})

	if err := d.Process(context.Background(), row); err != nil {
		t.Fatalf("Process: %v", err)
	}

	deleted := cleaner.list()
	if len(deleted) != 1 || deleted[0] != "dead-token" {
		t.Fatalf("deleted tokens = %v, want exactly [dead-token]", deleted)
	}
}

// TestDelivery_TransientFailureDeletesNothing is §E2c's second required
// assertion, and the one protecting real users: a rate limit or a 500 must
// never cost someone their device registration.
func TestDelivery_TransientFailureDeletesNothing(t *testing.T) {
	sender := &detailedStubSender{}
	sender.result = &SendResult{LastErr: errors.New("fcm returned 500")}
	cleaner := &recordingCleaner{}

	d := NewDelivery(sender, cleaner, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"live-token"}, Title: "T", Body: "B"})

	if err := d.Process(context.Background(), row); err == nil {
		t.Fatal("Process returned nil for a transient failure — the row would be marked delivered and never retried")
	}
	if deleted := cleaner.list(); len(deleted) != 0 {
		t.Errorf("deleted %v on a transient failure, want nothing deleted", deleted)
	}
}

// TestDelivery_DeadTokenCleanupFailureDoesNotCauseRedelivery pins the error
// posture: failing to delete a stale row must not turn into a retry, because
// the notification may well have been delivered to the user's other devices
// — producing a duplicate push to fix a bookkeeping problem.
func TestDelivery_DeadTokenCleanupFailureDoesNotCauseRedelivery(t *testing.T) {
	sender := &detailedStubSender{}
	sender.result = &SendResult{Delivered: 1, Unregistered: []string{"dead-token"}}
	cleaner := &recordingCleaner{err: errors.New("database unavailable")}

	d := NewDelivery(sender, cleaner, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"live", "dead-token"}, Title: "T", Body: "B"})

	if err := d.Process(context.Background(), row); err != nil {
		t.Errorf("Process = %v, want nil — a failed token cleanup must not cause the whole notification to be redelivered", err)
	}
}

// --- delivery outcomes -----------------------------------------------------

// TestDelivery_PartialSuccessIsSuccess pins the rule that keeps duplicates
// down: retrying a row where some devices already received it would
// re-deliver to those devices, and the ones that failed permanently will
// never succeed anyway.
func TestDelivery_PartialSuccessIsSuccess(t *testing.T) {
	sender := &detailedStubSender{}
	sender.result = &SendResult{Delivered: 1, Unregistered: []string{"dead"}, LastErr: errors.New("another failed")}
	d := NewDelivery(sender, &recordingCleaner{}, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"good", "dead", "flaky"}, Title: "T", Body: "B"})

	if err := d.Process(context.Background(), row); err != nil {
		t.Errorf("Process = %v, want nil — at least one device received it, so retrying would only duplicate", err)
	}
}

// TestDelivery_UndecodablePayloadIsPermanent asserts a corrupt row goes
// straight to the dead-letter state rather than burning ten retries on
// something that cannot possibly change.
func TestDelivery_UndecodablePayloadIsPermanent(t *testing.T) {
	d := NewDelivery(&stubSender{}, nil, discardLogger())
	err := d.Process(context.Background(), outbox.Row{ID: "row-1", Payload: []byte(`not json`)})
	if err == nil {
		t.Fatal("Process returned nil for an undecodable payload")
	}
	if !errors.Is(err, outbox.ErrPermanent) {
		t.Errorf("error = %v, want it to wrap outbox.ErrPermanent so the row dead-letters immediately", err)
	}
}

// TestDelivery_EmptyTokenListSucceeds pins the other no-op: a row with no
// recipients has nothing to retry, so leaving it pending forever would just
// grow the claimable set.
func TestDelivery_EmptyTokenListSucceeds(t *testing.T) {
	sender := &stubSender{}
	d := NewDelivery(sender, nil, discardLogger())
	if err := d.Process(context.Background(), rowFor(t, Payload{Title: "T", Body: "B"})); err != nil {
		t.Errorf("Process = %v, want nil", err)
	}
	if sender.callCount() != 0 {
		t.Error("the sender was called for a row with no tokens")
	}
}

// --- §E5: LoggingPushSender ------------------------------------------------

// TestLoggingPushSender_NeverLogsARawToken is the one assertion that makes
// the fallback safe to run anywhere. Logs are shipped, indexed and read far
// more widely than the database is, and a device token is a bearer
// credential for pushing to someone's phone.
func TestLoggingPushSender_NeverLogsARawToken(t *testing.T) {
	const secretToken = "SUPER-SECRET-DEVICE-TOKEN-abc123"

	var buf bytes.Buffer
	sender := NewLoggingPushSender(slog.New(slog.NewJSONHandler(&buf, nil)))

	err := sender.SendToTokens(context.Background(), []string{secretToken, "another-secret-token"},
		"Request accepted", "The host accepted your request", map[string]string{"meetup_id": "m-1"})
	if err != nil {
		t.Fatalf("SendToTokens: %v", err)
	}

	logged := buf.String()
	if logged == "" {
		t.Fatal("LoggingPushSender logged nothing — it is the only visibility into notifications in local dev")
	}
	for _, token := range []string{secretToken, "another-secret-token"} {
		if strings.Contains(logged, token) {
			t.Errorf("a raw device token appears in the log line: %q", logged)
		}
	}

	// It must still be USEFUL: the count and the copy are what make this a
	// workable local-development substitute for real delivery.
	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &line); err != nil {
		t.Fatalf("log line is not valid JSON: %v", err)
	}
	if line["token_count"] != float64(2) {
		t.Errorf("token_count = %v, want 2", line["token_count"])
	}
	if line["title"] != "Request accepted" {
		t.Errorf("title = %v, want the notification's title", line["title"])
	}
}

// TestLoggingPushSender_IsUsableAsTheFallback covers the path CI and every
// credential-free environment actually run on.
func TestLoggingPushSender_IsUsableAsTheFallback(t *testing.T) {
	d := NewDelivery(NewLoggingPushSender(discardLogger()), nil, discardLogger())
	row := rowFor(t, Payload{FCMTokens: []string{"t1", "t2"}, Title: "T", Body: "B"})
	if err := d.Process(context.Background(), row); err != nil {
		t.Errorf("Process with LoggingPushSender = %v, want nil", err)
	}
}

// TestFCMReason_NeverEchoesTheBody guards the error-message path that the
// source got wrong: the returned message must carry FCM's classification,
// never its raw body.
func TestFCMReason_NeverEchoesTheBody(t *testing.T) {
	const token = "LEAKY-TOKEN-xyz"
	body := fmt.Appendf(nil, `{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"bad token %s"}}`, token)

	reason := fcmReason(body)
	if strings.Contains(reason, token) {
		t.Errorf("fcmReason leaked the token: %q", reason)
	}
	if reason != "INVALID_ARGUMENT" {
		t.Errorf("reason = %q, want FCM's own status", reason)
	}

	// And an unparseable body yields a fixed string rather than the body.
	if got := fcmReason([]byte("<html>" + token + "</html>")); strings.Contains(got, token) {
		t.Errorf("fcmReason leaked an unparseable body: %q", got)
	}
}

// TestClassifyFCMError_StatusAndBodyMustAgree pins a subtle guard: an
// INVALID_ARGUMENT body arriving with a non-400 status is not trusted to mean
// a dead token.
func TestClassifyFCMError_StatusAndBodyMustAgree(t *testing.T) {
	body := []byte(`{"error":{"status":"INVALID_ARGUMENT","message":"The registration token is not valid"}}`)
	if classifyFCMError(http.StatusInternalServerError, body) {
		t.Error("a 500 carrying an INVALID_ARGUMENT body was treated as a permanently dead token")
	}
	if !classifyFCMError(http.StatusBadRequest, body) {
		t.Error("a genuine 400 INVALID_ARGUMENT about the registration token was not recognised")
	}
}
