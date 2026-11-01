package handlers

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

type analyticsRecorder struct {
	batches    int
	gotUserID  string
	gotBatch   monolithclient.AnalyticsBatch
	consentFor string
	optedOut   bool
}

func (f *fakeMonolith) IngestAnalytics(_ context.Context, userID string, b monolithclient.AnalyticsBatch) (monolithclient.AnalyticsResult, error) {
	f.analytics.batches++
	f.analytics.gotUserID, f.analytics.gotBatch = userID, b
	return monolithclient.AnalyticsResult{Accepted: int32(len(b.Events))}, f.err
}

func (f *fakeMonolith) SetAnalyticsConsent(_ context.Context, userID string, optedOut bool) error {
	f.analytics.consentFor, f.analytics.optedOut = userID, optedOut
	return f.err
}

const testInstall = "4b0c8a1e-3f2d-4c5b-9a8e-7d6c5b4a3f21"

func batchJSON(events int, pad int) string {
	var b strings.Builder
	fmt.Fprintf(&b, `{"install_id":%q,"app_version":"1.1.0+7","events":[`, testInstall)
	for i := 0; i < events; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"event_id":"0192f0a4-7b1c-7d3e-8f00-%012d","event_name":"screen_viewed","schema_version":1,"occurred_at":"2026-10-25T10:00:00Z","screen":"home","attributes":{}}`, i)
	}
	b.WriteString(`]`)
	if pad > 0 {
		fmt.Fprintf(&b, `,"locale":"%s"`, strings.Repeat("x", pad))
	}
	b.WriteString(`}`)
	return b.String()
}

func postAnalytics(s *testServer, body []byte, gz bool, bearer string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/v1/analytics/events", bytes.NewReader(body))
	if gz {
		r.Header.Set("Content-Encoding", "gzip")
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	return rec
}

func gzipped(t *testing.T, s string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write([]byte(s))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestAnalyticsIngestAcceptsAnonymousAndSignedIn(t *testing.T) {
	s := newTestServerWithLimiter(t)
	rec := postAnalytics(s, []byte(batchJSON(2, 0)), false, "")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("anonymous: %d %s", rec.Code, rec.Body.String())
	}
	if s.monolith.analytics.gotUserID != "" || s.monolith.analytics.gotBatch.InstallID != testInstall || len(s.monolith.analytics.gotBatch.Events) != 2 {
		t.Errorf("forwarded %+v", s.monolith.analytics)
	}
	if got := decodeBody(t, rec); got["accepted"] != float64(2) {
		t.Errorf("body = %v", got)
	}

	token := s.tokenFor(t, "alice", 1)
	if rec := postAnalytics(s, gzipped(t, batchJSON(3, 0)), true, token); rec.Code != http.StatusAccepted {
		t.Fatalf("gzip, signed in: %d %s", rec.Code, rec.Body.String())
	}
	if s.monolith.analytics.gotUserID != "alice" || len(s.monolith.analytics.gotBatch.Events) != 3 {
		t.Errorf("forwarded %+v", s.monolith.analytics)
	}
	if string(s.monolith.analytics.gotBatch.Events[0].Attributes) != "{}" {
		t.Errorf("attributes forwarded as %s", s.monolith.analytics.gotBatch.Events[0].Attributes)
	}
}

func TestAnalyticsIngestLimits(t *testing.T) {
	s := newTestServerWithLimiter(t)
	if rec := postAnalytics(s, []byte(batchJSON(50, 0)), false, ""); rec.Code != http.StatusAccepted {
		t.Fatalf("50 events: %d", rec.Code)
	}
	if rec := postAnalytics(s, []byte(batchJSON(51, 0)), false, ""); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("51 events: %d, want 413", rec.Code)
	}
	big := batchJSON(1, 65<<10)
	if rec := postAnalytics(s, []byte(big), false, ""); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("65 KB: %d, want 413", rec.Code)
	}
	// A small gzip body that expands past the cap is refused just the same.
	bomb := gzipped(t, big)
	if len(bomb) > 4<<10 {
		t.Fatalf("test bomb is %d bytes compressed", len(bomb))
	}
	if rec := postAnalytics(s, bomb, true, ""); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("65 KB gzipped to %d bytes: %d, want 413", len(bomb), rec.Code)
	}
	for _, bad := range []string{
		`{"install_id":"x","events":[],"email":"a@b.c"}`, // unknown field
		`not json`,
		`{"install_id":"x","events":[]} {"again":1}`,
	} {
		if rec := postAnalytics(s, []byte(bad), false, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("%q: %d, want 400", bad, rec.Code)
		}
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/analytics/events", strings.NewReader(batchJSON(1, 0)))
	r.Header.Set("Content-Encoding", "br")
	rec := httptest.NewRecorder()
	s.mux.ServeHTTP(rec, r)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("unsupported encoding: %d", rec.Code)
	}
}

func TestAnalyticsIngestIsRateLimitedPerUserOrInstall(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "bob", 1)
	for i := 0; i < 30; i++ {
		if rec := postAnalytics(s, []byte(batchJSON(1, 0)), false, token); rec.Code != http.StatusAccepted {
			t.Fatalf("batch %d: %d", i+1, rec.Code)
		}
	}
	rec := postAnalytics(s, []byte(batchJSON(1, 0)), false, token)
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" {
		t.Errorf("31st batch: %d (Retry-After %q), want 429", rec.Code, rec.Header().Get("Retry-After"))
	}
	if s.monolith.analytics.batches != 30 {
		t.Errorf("forwarded %d batches, want 30", s.monolith.analytics.batches)
	}
	// Another account, and the same install signed out, have their own
	// budgets.
	if rec := postAnalytics(s, []byte(batchJSON(1, 0)), false, s.tokenFor(t, "carol", 1)); rec.Code != http.StatusAccepted {
		t.Errorf("another user: %d", rec.Code)
	}
	for i := 0; i < 30; i++ {
		postAnalytics(s, []byte(batchJSON(1, 0)), false, "")
	}
	if rec := postAnalytics(s, []byte(batchJSON(1, 0)), false, ""); rec.Code != http.StatusTooManyRequests {
		t.Errorf("31st anonymous batch from one install: %d", rec.Code)
	}
}

func TestAnalyticsConsent(t *testing.T) {
	s := newTestServer(t)
	if rec := s.do(http.MethodPut, "/v1/analytics/consent", `{"opted_out":true}`, ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("signed out: %d, want 401", rec.Code)
	}
	token := s.tokenFor(t, "dave", 1)
	rec := s.do(http.MethodPut, "/v1/analytics/consent", `{"opted_out":true}`, token)
	if rec.Code != http.StatusOK || s.monolith.analytics.consentFor != "dave" || !s.monolith.analytics.optedOut {
		t.Errorf("opt out: %d, recorded %+v", rec.Code, s.monolith.analytics)
	}
	for _, bad := range []string{`{}`, `{"opted_out":"yes"}`, `{"opted_out":true,"user_id":"eve"}`} {
		if rec := s.do(http.MethodPut, "/v1/analytics/consent", bad, token); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, rec.Code)
		}
	}
}

// Security review 2026-11-01, S-5: opting out deletes the account's
// analytics, so the route has its own per-user budget, not only the IP one.
func TestAnalyticsConsentIsRateLimitedPerUser(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "erin", 1)
	for i := 0; i < consentPerMinute; i++ {
		if rec := s.do(http.MethodPut, "/v1/analytics/consent", `{"opted_out":true}`, token); rec.Code != http.StatusOK {
			t.Fatalf("call %d: %d", i+1, rec.Code)
		}
	}
	if rec := s.do(http.MethodPut, "/v1/analytics/consent", `{"opted_out":false}`, token); rec.Code != http.StatusTooManyRequests {
		t.Errorf("call %d: %d, want 429", consentPerMinute+1, rec.Code)
	}
}
