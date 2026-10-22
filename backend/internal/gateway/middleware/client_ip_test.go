package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// #81. On Cloud Run every request reaches the container through Google's
// own proxy, so RemoteAddr is the same for every user. Keyed on it, the
// blanket 20/min limit was one bucket per route for the whole user base.
//
// cloudRunRequest models that: a fixed proxy peer, and the real client
// appended to X-Forwarded-For after anything the caller sent itself.
func cloudRunRequest(clientSent, realClient string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", nil)
	r.RemoteAddr = "169.254.1.1:41000" // the proxy, identical for everyone
	xff := realClient
	if clientSent != "" {
		xff = clientSent + ", " + realClient
	}
	r.Header.Set("X-Forwarded-For", xff)
	return r
}

// Two different people behind Cloud Run must get two different buckets.
// Before the fix both keyed on the proxy, so one person exhausting the limit
// locked the other one out.
func TestRateLimit_DistinctClientsBehindTheProxyHaveSeparateBuckets(t *testing.T) {
	h := RateLimit(newLimiter(t), WithTrustedProxyHops(1))(&countingHandler{})

	for i := 0; i < requestsPerMinute; i++ {
		h.ServeHTTP(httptest.NewRecorder(), cloudRunRequest("", "198.51.100.7"))
	}
	exhausted := httptest.NewRecorder()
	h.ServeHTTP(exhausted, cloudRunRequest("", "198.51.100.7"))
	if exhausted.Code != http.StatusTooManyRequests {
		t.Fatalf("the first client's %dth request: status %d, want 429",
			requestsPerMinute+1, exhausted.Code)
	}

	other := httptest.NewRecorder()
	h.ServeHTTP(other, cloudRunRequest("", "203.0.113.99"))
	if other.Code != http.StatusOK {
		t.Errorf("a DIFFERENT client was rejected with %d after the first one "+
			"used up its limit. Both are being keyed on the proxy address, so "+
			"the whole user base shares one bucket.", other.Code)
	}
}

// The defence against spoofing: the client controls the LEFT of the header,
// never the right. Varying a forged leftmost entry on every request must not
// buy a fresh bucket — the real address the proxy appended stays the key.
func TestRateLimit_AForgedForwardedForDoesNotEscapeTheLimit(t *testing.T) {
	h := RateLimit(newLimiter(t), WithTrustedProxyHops(1))(&countingHandler{})

	for i := 0; i < requestsPerMinute; i++ {
		forged := "10.0.0." + string(rune('1'+i%9))
		h.ServeHTTP(httptest.NewRecorder(), cloudRunRequest(forged, "198.51.100.7"))
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, cloudRunRequest("10.9.9.9", "198.51.100.7"))
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("status %d, want 429: a client escaped the limit by forging "+
			"the leftmost X-Forwarded-For entry. Count from the right.", rec.Code)
	}
}

// With no trusted hops configured (local and test stacks) the header is
// whatever the caller sent and is ignored entirely.
func TestClientIP_IgnoresTheHeaderWithNoTrustedHops(t *testing.T) {
	r := cloudRunRequest("10.0.0.1", "198.51.100.7")
	if got := clientIPFor(r, 0); got != "169.254.1.1" {
		t.Errorf("clientIPFor(hops=0) = %q, want the TCP peer 169.254.1.1", got)
	}
}

// A header that cannot have come through the expected chain is not
// evidence: too short, or not an address. Fall back to the TCP peer rather
// than keying on attacker-chosen text.
func TestClientIP_FallsBackWhenTheHeaderIsNotTrustworthy(t *testing.T) {
	for _, tc := range []struct {
		name, header string
		hops         int
	}{
		{"fewer entries than hops", "198.51.100.7", 2},
		{"not an address", "not-an-ip", 1},
		{"empty", "", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			r.RemoteAddr = "169.254.1.1:41000"
			if tc.header != "" {
				r.Header.Set("X-Forwarded-For", tc.header)
			}
			if got := clientIPFor(r, tc.hops); got != "169.254.1.1" {
				t.Errorf("clientIPFor = %q, want the TCP peer", got)
			}
		})
	}
}

// IPv6 clients are normalised, so two spellings of one address are one key.
func TestClientIP_NormalisesIPv6(t *testing.T) {
	r := cloudRunRequest("", "2001:DB8:0:0:0:0:0:1")
	if got := clientIPFor(r, 1); got != "2001:db8::1" {
		t.Errorf("clientIPFor = %q, want the canonical 2001:db8::1", got)
	}
}
