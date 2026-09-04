package middleware

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

func newLimiter(t *testing.T) *ratelimit.Limiter {
	t.Helper()
	l := ratelimit.New()
	t.Cleanup(l.Close)
	return l
}

// countingHandler records how many requests actually made it past the limiter.
type countingHandler struct{ calls int }

func (h *countingHandler) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	h.calls++
	w.WriteHeader(http.StatusOK)
}

func postJSON(path, body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	r.RemoteAddr = "203.0.113.10:54321"
	return r
}

// TestRateLimit_IPPathBoundary is the blanket limit's boundary: 20 requests
// per minute per (IP, path) allowed, the 21st rejected with the exact 429
// shape the source returns.
func TestRateLimit_IPPathBoundary(t *testing.T) {
	next := &countingHandler{}
	h := RateLimit(newLimiter(t))(next)

	for i := 1; i <= requestsPerMinute; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, postJSON("/v1/auth/refresh", `{}`))
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: status = %d, want 200", i, rec.Code)
		}
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, postJSON("/v1/auth/refresh", `{}`))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("request %d: status = %d, want 429", requestsPerMinute+1, rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "60" {
		t.Errorf("Retry-After = %q, want %q", got, "60")
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != `{"error":"rate limited"}` {
		t.Errorf("body = %q, want %q", got, `{"error":"rate limited"}`)
	}
	if next.calls != requestsPerMinute {
		t.Errorf("handler ran %d times, want %d — the rejected request must not reach it", next.calls, requestsPerMinute)
	}
}

// TestRateLimit_IPKeyIsPerPath: the key is (IP, path), not IP alone, so
// exhausting one route's budget must not lock a caller out of every route.
func TestRateLimit_IPKeyIsPerPath(t *testing.T) {
	next := &countingHandler{}
	h := RateLimit(newLimiter(t))(next)

	for i := 0; i <= requestsPerMinute; i++ {
		h.ServeHTTP(httptest.NewRecorder(), postJSON("/v1/auth/refresh", `{}`))
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, postJSON("/v1/auth/logout", `{}`))
	if rec.Code != http.StatusOK {
		t.Errorf("a different path returned %d, want 200 — the limit is keyed per (IP, path)", rec.Code)
	}
}

// TestRateLimit_EmailKeyedCatchesRotatingIPs is the reason the email-keyed
// check exists: many IPs each hammering ONE account sail past the IP key.
func TestRateLimit_EmailKeyedCatchesRotatingIPs(t *testing.T) {
	h := RateLimit(newLimiter(t))(&countingHandler{})

	send := func(ip, email string) int {
		r := httptest.NewRequest(http.MethodPost, "/v1/auth/email/login", strings.NewReader(fmt.Sprintf(`{"email":%q}`, email)))
		r.RemoteAddr = ip + ":1234"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		return rec.Code
	}

	// Every request from a different IP — the IP+path key never trips.
	for i := 1; i <= requestsPerMinute; i++ {
		if code := send(fmt.Sprintf("198.51.100.%d", i), "victim@example.com"); code != http.StatusOK {
			t.Fatalf("attempt %d from a fresh IP: status = %d, want 200", i, code)
		}
	}
	if code := send("198.51.100.200", "victim@example.com"); code != http.StatusTooManyRequests {
		t.Errorf("attempt %d against the same email from yet another IP: status = %d, want 429",
			requestsPerMinute+1, code)
	}
	// A different account is unaffected.
	if code := send("198.51.100.201", "someone-else@example.com"); code != http.StatusOK {
		t.Errorf("a different email returned %d, want 200 — the email key is per-account", code)
	}
}

// TestRateLimit_TargetKeyedOTPRoutes covers the three OTP-send routes: 5 per
// HOUR per target, keyed on that route's own body field.
func TestRateLimit_TargetKeyedOTPRoutes(t *testing.T) {
	for path, field := range targetKeyedPaths {
		t.Run(path, func(t *testing.T) {
			h := RateLimit(newLimiter(t))(&countingHandler{})
			body := fmt.Sprintf(`{%q:"+94771234567"}`, field)

			for i := 1; i <= targetKeyedLimit; i++ {
				rec := httptest.NewRecorder()
				// A fresh IP each time, so only the target key can reject.
				r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
				r.RemoteAddr = fmt.Sprintf("192.0.2.%d:999", i)
				h.ServeHTTP(rec, r)
				if rec.Code != http.StatusOK {
					t.Fatalf("send %d of %d: status = %d, want 200", i, targetKeyedLimit, rec.Code)
				}
			}

			rec := httptest.NewRecorder()
			r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
			r.RemoteAddr = "192.0.2.99:999"
			h.ServeHTTP(rec, r)
			if rec.Code != http.StatusTooManyRequests {
				t.Errorf("send %d against the same target: status = %d, want 429", targetKeyedLimit+1, rec.Code)
			}
		})
	}
}

// TestRateLimit_RestoresBodyForTheHandler: the limiter peeks at the body to
// read its key field, and the handler downstream still has to be able to
// decode the whole request.
func TestRateLimit_RestoresBodyForTheHandler(t *testing.T) {
	var seen map[string]any
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&seen)
	})
	h := RateLimit(newLimiter(t))(next)

	h.ServeHTTP(httptest.NewRecorder(), postJSON("/v1/auth/email/login", `{"email":"ada@example.com","code":"123456"}`))

	if seen["email"] != "ada@example.com" || seen["code"] != "123456" {
		t.Errorf("handler decoded %+v, want the full original body — peeking must not consume it", seen)
	}
}

// TestRateLimit_OversizedBodyIsNotBufferedWhole is the hardening over the
// source's unbounded io.ReadAll in this middleware (which runs BEFORE
// MaxBytes). The oversized body must not be swallowed here, and the request
// must still arrive downstream intact for MaxBytes to reject.
func TestRateLimit_OversizedBodyIsNotBufferedWhole(t *testing.T) {
	oversized := fmt.Sprintf(`{"email":%q}`, strings.Repeat("a", maxRequestBodyBytes+1024))

	var downstreamRead int
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		downstreamRead = int(n)
	})
	h := RateLimit(newLimiter(t))(next)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, postJSON("/v1/auth/email/login", oversized))

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 — an oversized body is MaxBytes's job to reject, not the limiter's", rec.Code)
	}
	if downstreamRead != len(oversized) {
		t.Errorf("handler saw %d body bytes, want %d — the peeked prefix must be stitched back in front of the remainder",
			downstreamRead, len(oversized))
	}
}

func TestRateLimit_MalformedBodySkipsTheKeyedCheckWithoutFailing(t *testing.T) {
	next := &countingHandler{}
	h := RateLimit(newLimiter(t))(next)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, postJSON("/v1/auth/email/login", `not json at all`))

	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 — an unparseable body is the handler's error to report, not a 429", rec.Code)
	}
	if next.calls != 1 {
		t.Error("handler did not run")
	}
}

// TestUserKeyedRateLimit_BoundaryAndScoping covers the SOS-trigger limit's
// shape: 5/hour keyed on the VERIFIED caller id from the context (not a body
// field), and one user's budget can't be spent by another.
func TestUserKeyedRateLimit_BoundaryAndScoping(t *testing.T) {
	next := &countingHandler{}
	h := UserKeyedRateLimit(newLimiter(t), "/v1/sos/trigger", 5, time.Hour)(next)

	call := func(userID string) int {
		r := httptest.NewRequest(http.MethodPost, "/v1/sos/trigger", bytes.NewReader(nil))
		r = r.WithContext(WithUserID(r.Context(), userID))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		return rec.Code
	}

	for i := 1; i <= 5; i++ {
		if code := call("user-1"); code != http.StatusOK {
			t.Fatalf("trigger %d of 5: status = %d, want 200", i, code)
		}
	}
	if code := call("user-1"); code != http.StatusTooManyRequests {
		t.Errorf("trigger 6: status = %d, want 429", code)
	}
	if code := call("user-2"); code != http.StatusOK {
		t.Errorf("a different user got %d, want 200 — the key is per-user", code)
	}
}
