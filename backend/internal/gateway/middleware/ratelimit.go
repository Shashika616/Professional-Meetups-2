package middleware

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"strconv"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"

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

// pathLimits raise the per-IP limit for routes a normal device calls more
// often than 20 times a minute from one address. Analytics batches: many
// phones share one carrier or office NAT, and each may send up to 30
// batches a minute (its own per-user or per-install limit, in
// handlers/analytics.go), so the IP budget is a coarse ceiling above that.
//
// The store webhooks (security review 2026-11-01, S-2) are authenticated by
// signature and arrive in bursts from Apple's and Google's few addresses;
// throttling them at 20 would delay renewals and refunds by the stores'
// retry backoff.
var pathLimits = map[string]int{
	"/v1/analytics/events":        300,
	"/v1/billing/webhooks/apple":  600,
	"/v1/billing/webhooks/google": 600,
}

// patternLimits are pathLimits for a route with an id in it. A screen of
// avatars is one photo request each, all from one phone on first load (they
// are cached for a day after), and many phones share a carrier address.
var patternLimits = map[string]int{
	"GET /v1/users/{id}/photo": 300,
}

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

// accountCreationPaths are routes that mint a fully usable account with NO
// verification step of any kind. Today that is exactly one: guest signup
// (ADR-002 §3).
//
// # WHY THE BLANKET LIMIT IS THE WRONG SHAPE HERE
//
// Every other unauthenticated route is bounded by something outside the
// attacker's control before it can do damage: the email/OTP paths need a
// real inbox, the federated paths need a valid provider id_token. Guest
// signup needs nothing — one HTTP call with a single boolean produces a real
// auth.users row and a real session. At the shared 20/min it would allow
// ~28,800 accounts per IP per day, which is a database-filling primitive
// rather than a signup flow.
//
// # WHY THIS NUMBER
//
// A real device calls this ONCE, ever — the session is persisted and a guest
// who returns is already signed in. Five allows for a reinstall, a cleared
// app, a shared NAT with a couple of genuine new users, and a retry or two,
// while making bulk creation useless. A daily window rather than hourly
// because the legitimate rate is "once", so there is no burst to accommodate.
//
// # WHAT THIS DOES NOT CLAIM
//
// It is IP-keyed, so it is defeated by a proxy pool, and it is deliberately
// not the only thing standing between an attacker and a mass of guest
// accounts — it is the cheap bound that makes casual abuse pointless. A
// determined attacker needs a server-side answer (proof-of-work, device
// attestation, or dropping anonymous accounts entirely), which is a product
// decision, not a middleware one.
var accountCreationPaths = map[string]bool{
	"/v1/auth/guest/signup": true,
}

const (
	accountCreationLimit  = 5
	accountCreationWindow = 24 * time.Hour
)

// RateLimit is the blanket, per-(IP, path) fixed-window limiter applied to
// the whole mux, plus the two additional keyed checks above where the IP key
// alone is the wrong shape of protection. Both must pass; either can reject.
//
// Deliberately the simplest correct algorithm (fixed window), not a token
// bucket or sliding window — upgrade later only if the fixed-window edge
// effect (bursts at window boundaries) actually becomes a measured problem.
func RateLimit(limiter ratelimit.Limiter, opts ...RateLimitOption) func(http.Handler) http.Handler {
	var cfg rateLimitConfig
	for _, opt := range opts {
		opt(&cfg)
	}
	clientIP := func(r *http.Request) string { return clientIPFor(r, cfg.trustedProxyHops) }

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ipKey := fmt.Sprintf("ratelimit:%s:%s", clientIP(r), cfg.routeKey(r))
			limit := requestsPerMinute
			if l, ok := pathLimits[r.URL.Path]; ok {
				limit = l
			} else if l, ok := patternLimits[cfg.routeKey(r)]; ok {
				limit = l
			}
			if !limiter.Allow(ipKey, limit, time.Minute) {
				writeRateLimited(w, time.Minute)
				return
			}

			// Checked before the body-keyed limiters below because it needs
			// nothing from the body at all — an account-creation route is
			// rejected on the IP key alone, without paying for a body read.
			if accountCreationPaths[r.URL.Path] {
				key := fmt.Sprintf("ratelimit:accountcreate:%s:%s", r.URL.Path, clientIP(r))
				if !limiter.Allow(key, accountCreationLimit, accountCreationWindow) {
					writeRateLimited(w, accountCreationWindow)
					return
				}
			}

			if emailKeyedPaths[r.URL.Path] {
				email, ok, ambiguous := peekRequestField(r, "email")
				if ambiguous {
					writeAmbiguousBody(w)
					return
				}
				if ok && email != "" {
					// Normalised, or the bucket is per-spelling (#82).
					emailKey := fmt.Sprintf("ratelimit:email:%s:%s", r.URL.Path, identity.NormalizeEmail(email))
					if !limiter.Allow(emailKey, requestsPerMinute, time.Minute) {
						writeRateLimited(w, time.Minute)
						return
					}
				}
			}

			if field, ok := targetKeyedPaths[r.URL.Path]; ok {
				target, ok, ambiguous := peekRequestField(r, field)
				if ambiguous {
					writeAmbiguousBody(w)
					return
				}
				if ok && target != "" {
					targetKey := fmt.Sprintf("ratelimit:target:%s:%s", r.URL.Path,
						normalizeLimiterTarget(field, target))
					if !limiter.Allow(targetKey, targetKeyedLimit, targetKeyedWindow) {
						writeRateLimited(w, targetKeyedWindow)
						return
					}
				}
			}

			next.ServeHTTP(w, r)
		})
	}
}

// normalizeLimiterTarget keys the per-target limiter on the canonical form
// of the address or number, not on how it happened to be typed (tracker
// #82, review finding N-A1).
//
// Five sends per hour per target is only a limit if the two spellings of
// one target share a bucket. `Victim@x.com` and `victim@x.com` reach the
// same inbox; `+94 77 123 4567` and `+94771234567` reach the same handset.
// Without this, each spelling bought another five.
//
// Keyed off the FIELD NAME the route reads rather than a purpose enum,
// because that is all this layer knows — it has peeked at one JSON field
// and has not parsed the request. phone_number is the only phone-shaped
// field in targetKeyedPaths, and a new route adding another has to be
// added here too; the service layer normalises again regardless, so the
// worst case of forgetting is a limiter that is too generous, never a
// mismatch with what gets stored.
func normalizeLimiterTarget(field, target string) string {
	if field == "phone_number" {
		return identity.NormalizePhone(target)
	}
	return identity.NormalizeEmail(target)
}

// UserKeyedRateLimit limits by the authenticated caller's own user_id rather
// than a request-body field — used where the key needs identity established
// by JWT verification, not something present in the request body (the SOS
// trigger's own request body carries no user_id; it is sourced server-side
// from the token). Unlike RateLimit, which wraps the whole mux before Auth
// ever runs, this must be chained AFTER the per-route Auth middleware so the
// context actually carries a verified identity by the time it runs.
func UserKeyedRateLimit(limiter ratelimit.Limiter, routePath string, limit int, window time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			userID := UserIDFromContext(r.Context())
			if userID != "" {
				key := fmt.Sprintf("ratelimit:user:%s:%s", routePath, userID)
				if !limiter.Allow(key, limit, window) {
					writeRateLimited(w, window)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// writeRateLimited rejects with 429 and an honest Retry-After.
//
// The header takes the WINDOW that was actually exceeded rather than a fixed
// 60. That was harmless while every limiter here used a one-minute window,
// but the account-creation limit's window is a day: telling a well-behaved
// client to retry in 60 seconds when the real answer is "tomorrow" makes it
// retry 1,440 times to discover that, which is worse for both sides than
// being told the truth once.
//
// Retry-After is an upper bound on the wait, not an exact one — these are
// fixed windows, so the caller may be admitted sooner when the window rolls.
// Over-stating is the safe direction: a client that waits too long costs
// itself latency, one that waits too little costs the server another
// rejected request.
func writeRateLimited(w http.ResponseWriter, window time.Duration) {
	seconds := int(window.Seconds())
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusTooManyRequests)
	_, _ = w.Write([]byte(`{"error":"Too many attempts. Please wait a moment and try again."}`))
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
//
// # KEYS ARE MATCHED WITHOUT REGARD TO CASE (#107)
//
// encoding/json, which the handlers decode with, matches a key to a struct
// field case-insensitively. A peek that read only parsed["email"] therefore
// let {"EMAIL": ...} or {"Email": ...} past every keyed limit while the
// handler still read the address. The field is found the way the handler
// will find it.
//
// And a body that names any top-level key twice, exactly or in another
// case, is ambiguous: which value the limiter and the handler each take
// depends on rules nobody should rely on. ambiguous reports that, and the
// caller refuses the request.
func peekRequestField(r *http.Request, field string) (value string, ok, ambiguous bool) {
	buffered, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodyBytes+1))
	// Deliberately no r.Body.Close() before reassigning: the remainder of the
	// original stream is still needed below, and net/http closes the request
	// body itself once the handler returns.
	r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(buffered), r.Body))
	if err != nil || len(buffered) > maxRequestBodyBytes {
		return "", false, false
	}

	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(buffered, &parsed); err != nil {
		return "", false, false
	}
	keys, err := topLevelKeys(buffered)
	if err != nil {
		return "", false, false
	}
	seen := make(map[string]bool, len(keys))
	for _, k := range keys {
		folded := strings.ToLower(k)
		if seen[folded] {
			return "", false, true
		}
		seen[folded] = true
	}
	for k, raw := range parsed {
		if strings.EqualFold(k, field) {
			if err := json.Unmarshal(raw, &value); err != nil {
				return "", false, false
			}
			return value, true, false
		}
	}
	return "", false, false
}

// topLevelKeys lists an object's keys in order, duplicates included (a map
// would have kept only one of each).
func topLevelKeys(body []byte) ([]string, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, fmt.Errorf("not an object")
	}
	var keys []string
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := t.(string)
		if !ok {
			return nil, fmt.Errorf("not a key")
		}
		keys = append(keys, key)
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			return nil, err
		}
	}
	return keys, nil
}

// writeAmbiguousBody refuses a body whose keys repeat (#107), in the same
// words the handlers use for any body they cannot read.
func writeAmbiguousBody(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_, _ = w.Write([]byte(`{"error":"That didn't go through. Please try again."}`))
}

// RateLimitOption configures RateLimit.
type RateLimitOption func(*rateLimitConfig)

type rateLimitConfig struct {
	trustedProxyHops int
	routes           RouteMatcher
}

// RouteMatcher is the slice of *http.ServeMux the limiter needs: which
// registered pattern a request will be routed to.
type RouteMatcher interface {
	Handler(r *http.Request) (h http.Handler, pattern string)
}

// routeKey is the per-route part of the IP key. With a mux, the pattern the
// request matches ("GET /v1/meetups/{id}"), so every id shares one bucket
// and every unknown path shares "unmatched" (#81). Without one, the raw
// path, as before.
func (c rateLimitConfig) routeKey(r *http.Request) string {
	if c.routes == nil {
		return r.URL.Path
	}
	if _, pattern := c.routes.Handler(r); pattern != "" {
		return pattern
	}
	return "unmatched"
}

// WithRoutePatterns keys the blanket per-IP limit on the route pattern the
// mux will pick rather than on the raw path (#81): keyed on the raw path,
// a caller cycling meetup ids or 404 paths got a fresh bucket for each.
func WithRoutePatterns(mux RouteMatcher) RateLimitOption {
	return func(c *rateLimitConfig) { c.routes = mux }
}

// WithTrustedProxyHops says how many proxies in front of this process append
// to X-Forwarded-For, and so which entry is the real client (#81).
//
// Zero, the default, ignores the header and uses the TCP peer — right for
// local and test stacks, where nothing sits in front and the header is
// whatever the caller chose to send.
//
// On Cloud Run it must be 1. The container is reached through Google's own
// proxy, so RemoteAddr is that proxy and the same for every user: keyed on
// it, the 20/min per-IP limit was one bucket shared by the entire user base
// per route. Cloud Run appends the real client address to X-Forwarded-For,
// so with one trusted hop the client is the LAST entry.
func WithTrustedProxyHops(n int) RateLimitOption {
	return func(c *rateLimitConfig) {
		if n > 0 {
			c.trustedProxyHops = n
		}
	}
}

// clientIPFor picks the address to key the limiter on.
//
// It counts from the RIGHT, and that is the whole defence against spoofing.
// A caller can put anything at the left of X-Forwarded-For, and every proxy
// in the chain only appends, so the entries a client cannot forge are the
// last `hops` of them. Taking the first entry — the common mistake — would
// let anyone pick their own rate-limit bucket by sending the header.
//
// If the header has fewer entries than there are trusted hops, or the entry
// is not an IP, the request did not come through the expected proxy chain
// and the header is not evidence of anything; the TCP peer is used instead.
func clientIPFor(r *http.Request, hops int) string {
	return resolveClientIP(r, hops)
}

// Requester records who is calling, hashed, for the OTP budgets (#133): one
// caller must not be able to spend another person's allowance.
func Requester(hops int) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := clientinfo.WithRequester(r.Context(), resolveClientIP(r, hops))
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func resolveClientIP(r *http.Request, hops int) string {
	if hops > 0 {
		var entries []string
		for _, header := range r.Header.Values("X-Forwarded-For") {
			for _, part := range strings.Split(header, ",") {
				if part = strings.TrimSpace(part); part != "" {
					entries = append(entries, part)
				}
			}
		}
		if len(entries) >= hops {
			if ip := net.ParseIP(entries[len(entries)-hops]); ip != nil {
				return ip.String()
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
