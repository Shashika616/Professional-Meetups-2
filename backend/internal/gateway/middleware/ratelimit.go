package middleware

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// The four key shapes, their limits and their windows are copied verbatim
// from
// ../Professional-Meetups/backend/services/gateway/internal/middleware/ratelimit.go
// — same routes, same numbers, same key strings, only the backing store
// changed (ADR-001 §5; see internal/platform/ratelimit for the
// single-instance trade-off that comes with that).

// requestsPerMinute is the fixed-window limit applied per key.
const requestsPerMinute = 20

// emailKeyedPaths are the two email auth routes where a rotating set of IPs
// hammering ONE account would sail past the IP-keyed limit below — an
// extension of that limiter, not a second subsystem. Every other
// /v1/auth/* route stays IP+path-keyed only.
var emailKeyedPaths = map[string]bool{
	"/v1/auth/email/login":  true,
	"/v1/auth/email/signup": true,
}

// targetKeyedPaths are the three OTP-send routes where a distributed set of
// caller accounts could each target the same victim phone/email — sailing
// past the IP-keyed limit, which only catches one IP hammering many targets,
// not many IPs each hammering one target once. Same mechanism as
// emailKeyedPaths, generalized to a route-specific body field name and a
// longer, hourly window: this is meant to catch sustained targeting, not
// normal single-attempt usage.
var targetKeyedPaths = map[string]string{
	"/v1/verification/phone/start":           "phone_number",
	"/v1/verification/personal-email/start":  "email",
	"/v1/verification/corporate-email/start": "email",
}

const (
	targetKeyedLimit  = 5
	targetKeyedWindow = time.Hour
)

// RateLimit is the blanket, per-(IP, path) fixed-window limiter applied to
// the whole mux, plus the two additional keyed checks above where the IP key
// alone is the wrong shape of protection. Both must pass; either can reject.
//
// Deliberately the simplest correct algorithm (fixed window), not a token
// bucket or sliding window — upgrade later only if the fixed-window edge
// effect (bursts at window boundaries) actually becomes a measured problem.
func RateLimit(limiter *ratelimit.Limiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ipKey := fmt.Sprintf("ratelimit:%s:%s", clientIP(r), r.URL.Path)
			if !limiter.Allow(ipKey, requestsPerMinute, time.Minute) {
				writeRateLimited(w)
				return
			}

			if emailKeyedPaths[r.URL.Path] {
				if email, ok := peekRequestField(r, "email"); ok && email != "" {
					emailKey := fmt.Sprintf("ratelimit:email:%s:%s", r.URL.Path, email)
					if !limiter.Allow(emailKey, requestsPerMinute, time.Minute) {
						writeRateLimited(w)
						return
					}
				}
			}

			if field, ok := targetKeyedPaths[r.URL.Path]; ok {
				if target, ok := peekRequestField(r, field); ok && target != "" {
					targetKey := fmt.Sprintf("ratelimit:target:%s:%s", r.URL.Path, target)
					if !limiter.Allow(targetKey, targetKeyedLimit, targetKeyedWindow) {
						writeRateLimited(w)
						return
					}
				}
			}

			next.ServeHTTP(w, r)
		})
	}
}

// UserKeyedRateLimit limits by the authenticated caller's own user_id rather
// than a request-body field — used where the key needs identity established
// by JWT verification, not something present in the request body (the SOS
// trigger's own request body carries no user_id; it is sourced server-side
// from the token). Unlike RateLimit, which wraps the whole mux before Auth
// ever runs, this must be chained AFTER the per-route Auth middleware so the
// context actually carries a verified identity by the time it runs.
func UserKeyedRateLimit(limiter *ratelimit.Limiter, routePath string, limit int, window time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			userID := UserIDFromContext(r.Context())
			if userID != "" {
				key := fmt.Sprintf("ratelimit:user:%s:%s", routePath, userID)
				if !limiter.Allow(key, limit, window) {
					writeRateLimited(w)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

func writeRateLimited(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "60")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusTooManyRequests)
	_, _ = w.Write([]byte(`{"error":"rate limited"}`))
}

// peekRequestField reads r.Body to extract a named top-level string field
// (e.g. "email", or "phone_number" — whatever wire shape internal/gateway/
// handlers actually decodes), then restores r.Body so the downstream handler
// can still decode the full request normally: this middleware runs before
// any handler-level json.Decode, and a request body can only be read once.
//
// One hardening over the source's version, which called a plain
// io.ReadAll(r.Body) here: this middleware runs BEFORE MaxBytes in the chain
// (Recover -> request-id -> RequestLogging -> RateLimit -> MaxBytes, the
// order the phase plan specifies and the source uses), so that ReadAll was
// the one unbounded read in the whole gateway — a caller could stream an
// arbitrarily large body at any of the five keyed paths and have all of it
// buffered here before the 1 MiB cap was ever applied. The read is bounded
// to the same cap now; anything larger is left for MaxBytes to reject, with
// the buffered prefix stitched back in front of the unread remainder so the
// downstream handler still sees the exact original stream.
func peekRequestField(r *http.Request, field string) (string, bool) {
	buffered, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodyBytes+1))
	// Deliberately no r.Body.Close() before reassigning: the remainder of the
	// original stream is still needed below, and net/http closes the request
	// body itself once the handler returns.
	r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(buffered), r.Body))
	if err != nil || len(buffered) > maxRequestBodyBytes {
		return "", false
	}

	var parsed map[string]any
	if err := json.Unmarshal(buffered, &parsed); err != nil {
		return "", false
	}
	value, ok := parsed[field].(string)
	return value, ok
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
