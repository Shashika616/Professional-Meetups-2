package ratelimit

import (
	"sync"
	"testing"
	"time"
)

// fakeClock lets the window-expiry tests assert real behavior without
// sleeping through an hour-long window.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func newTestLimiter(t *testing.T, clock *fakeClock) *Limiter {
	t.Helper()
	l := newWithClock(clock.Now)
	t.Cleanup(l.Close)
	return l
}

// TestAllow_BoundaryIsInclusive is the exact-limit case: with a limit of N,
// the Nth request in a window must be allowed and the (N+1)th rejected. An
// off-by-one here is the difference between the ported "20 per minute" and a
// silently tighter 19.
func TestAllow_BoundaryIsInclusive(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	const limit = 20
	for i := 1; i <= limit; i++ {
		if !l.Allow("k", limit, time.Minute) {
			t.Fatalf("request %d of %d was rejected, want allowed", i, limit)
		}
	}
	if l.Allow("k", limit, time.Minute) {
		t.Errorf("request %d was allowed, want rejected (limit is %d)", limit+1, limit)
	}
}

func TestAllow_KeysAreIndependent(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	if !l.Allow("a", 1, time.Minute) || l.Allow("a", 1, time.Minute) {
		t.Fatal("key a did not behave as a 1-per-window key")
	}
	if !l.Allow("b", 1, time.Minute) {
		t.Error("key b was rejected — exhausting one key must not affect another (this is what makes the IP+path key per-route)")
	}
}

// TestAllow_WindowResets covers the fixed-window semantics: the window opens
// on the first request for a key and lasts exactly `window`; once it lapses,
// the key starts fresh.
func TestAllow_WindowResets(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	if !l.Allow("k", 1, time.Minute) {
		t.Fatal("first request rejected")
	}
	if l.Allow("k", 1, time.Minute) {
		t.Fatal("second request in the same window allowed")
	}

	// One tick before expiry: still the same window.
	clock.advance(time.Minute - time.Nanosecond)
	if l.Allow("k", 1, time.Minute) {
		t.Error("request just before the window expired was allowed, want rejected")
	}

	// Exactly at expiry: resetAt has been reached, so a new window opens.
	clock.advance(time.Nanosecond)
	if !l.Allow("k", 1, time.Minute) {
		t.Error("request at window expiry was rejected, want allowed (fixed window has reset)")
	}
}

// TestAllow_HourWindow exercises the target-keyed shape (5/hour) at its own
// boundary, since that limit's window is long enough that a bug in it would
// otherwise only show up in production.
func TestAllow_HourWindow(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	for i := 1; i <= 5; i++ {
		if !l.Allow("target", 5, time.Hour) {
			t.Fatalf("OTP-send %d of 5 rejected, want allowed", i)
		}
	}
	if l.Allow("target", 5, time.Hour) {
		t.Error("6th OTP-send in the hour was allowed, want rejected")
	}

	clock.advance(59 * time.Minute)
	if l.Allow("target", 5, time.Hour) {
		t.Error("send at 59 minutes was allowed, want rejected — the window is an hour")
	}
	clock.advance(time.Minute)
	if !l.Allow("target", 5, time.Hour) {
		t.Error("send after the hour elapsed was rejected, want allowed")
	}
}

// TestSweep_DropsOnlyExpiredBuckets guards the reason the sweeper exists: one
// entry per distinct IP/email/phone/user ever seen, kept forever, is an
// attacker-controlled memory leak on a public endpoint. Redis did this via
// key TTLs; here it's explicit.
func TestSweep_DropsOnlyExpiredBuckets(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	l.Allow("short", 1, time.Minute)
	l.Allow("long", 1, time.Hour)

	clock.advance(2 * time.Minute)
	l.sweep()

	l.mu.Lock()
	_, shortPresent := l.buckets["short"]
	_, longPresent := l.buckets["long"]
	l.mu.Unlock()

	if shortPresent {
		t.Error("expired bucket survived the sweep — the map would grow unbounded")
	}
	if !longPresent {
		t.Error("live bucket was swept away — that would silently reset an in-flight window")
	}
}

// TestAllow_ConcurrentCallersCountExactlyOnce is a race-detector target and a
// correctness check: N concurrent requests against a limit of N/2 must yield
// exactly N/2 allowances, never more (double-counting would under-enforce).
func TestAllow_ConcurrentCallersCountExactlyOnce(t *testing.T) {
	clock := &fakeClock{now: time.Now()}
	l := newTestLimiter(t, clock)

	const attempts, limit = 100, 50
	var mu sync.Mutex
	allowed := 0
	var wg sync.WaitGroup
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Allow("k", limit, time.Minute) {
				mu.Lock()
				allowed++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if allowed != limit {
		t.Errorf("allowed %d of %d concurrent requests, want exactly %d", allowed, attempts, limit)
	}
}
