// Package ratelimit is a fixed-window rate limiter backed by an in-memory
// map, replacing the Redis-backed one in
// ../Professional-Meetups/backend/services/gateway/internal/middleware/ratelimit.go
// (ADR-001 §5). Not a port — the algorithm is the same, the storage is not.
//
// The original was already a plain fixed-window counter (INCR + conditional
// PEXPIRE, made atomic with a Lua script). Nothing about that depends on
// Redis beyond atomicity of increment-and-expire, which a mutex-guarded map
// provides just as well within one process. Every key shape, limit, window
// and response body below is copied from that file unchanged.
//
// EXPLICIT, ACCEPTED TRADE-OFF (ADR-001 §5): this is only correct for a
// SINGLE gateway instance. Behind a load balancer, each replica would
// enforce its own independent limit, so a caller could get up to
// (replica count x limit). The Redis-backed original was correct across
// replicas; this is not. Accepted because a single-gateway-instance
// deployment is the plan — if the gateway is ever scaled out, the fix is to
// bring a shared store back for rate limiting specifically and say so, not
// to discover this silently.
//
// One posture difference worth naming: the original failed OPEN on a Redis
// error ("rate limiting is defense in depth, not the only line of defense").
// There is no third "couldn't check" state here at all — no external
// dependency can fail — so every check either succeeds or correctly 429s.
package ratelimit

import (
	"sync"
	"time"
)

// Limiter is the one-method seam every consumer codes against (§A4).
//
// WHY AN INTERFACE FOR A SINGLE IMPLEMENTATION: the in-memory limiter above
// is correct only for a SINGLE gateway instance, which is a documented,
// accepted trade-off (ADR-001 §5) and not a permanent one. When the gateway
// is eventually scaled out, the fix is a shared-store limiter — and the
// difference between that being a new type satisfying this interface and it
// being a rewrite of every call site is whether this interface exists before
// it is needed. It costs nothing now: `*InMemory` satisfies it by
// construction and no call site changes shape.
//
// Allow returns only a bool, with no error, because there is genuinely no
// third "couldn't check" state in the in-memory implementation. A future
// shared-store implementation that CAN fail should decide fail-open
// vs. fail-closed inside itself and keep this signature — the source's
// Redis-backed original made exactly that call (fail open: "rate limiting is
// defense in depth, not the only line of defense"), and pushing an error
// return out to every middleware would force each one to re-decide it.
type Limiter interface {
	// Allow records one request against key and reports whether it is
	// within limit for the current window.
	Allow(key string, limit int, window time.Duration) bool
}

// bucket is one key's fixed window: how many requests have landed in it, and
// when it expires. A bucket whose resetAt has passed is indistinguishable
// from a key that was never seen — both start a fresh window.
type bucket struct {
	count   int
	resetAt time.Time
}

// InMemory counts requests per key over a fixed window, in a mutex-guarded
// map. Safe for concurrent use. Construct with New, which also starts the
// sweeper. This is the only Limiter implementation today.
type InMemory struct {
	mu      sync.Mutex
	buckets map[string]*bucket

	// now is time.Now in production; tests substitute a clock so they can
	// assert real window-expiry behavior without sleeping through it.
	now func() time.Time

	stop chan struct{}
}

// sweepInterval is how often expired buckets are dropped. Without this the
// map grows unbounded — one entry per distinct (IP, path), email, phone
// number or user id ever seen, forever, which for an IP-keyed limiter on a
// public endpoint is an attacker-controlled memory leak rather than a
// housekeeping nicety. Redis handled this for the original via key TTLs.
const sweepInterval = time.Minute

// New constructs an InMemory limiter and starts its background sweeper. Call Close to
// stop that goroutine (cmd/gateway does, on shutdown; tests do via
// t.Cleanup).
func New() *InMemory {
	return newWithClock(time.Now)
}

func newWithClock(now func() time.Time) *InMemory {
	l := &InMemory{
		buckets: make(map[string]*bucket),
		now:     now,
		stop:    make(chan struct{}),
	}
	go l.sweepLoop()
	return l
}

// Allow records one request against key and reports whether it is within
// limit for the current window. The window starts on the first request for a
// key and lasts exactly window — the same fixed-window semantics (including
// the same burst-at-the-boundary edge effect) as the Redis original, which
// chose fixed-window deliberately as the simplest correct algorithm.
func (l *InMemory) Allow(key string, limit int, window time.Duration) bool {
	now := l.now()

	l.mu.Lock()
	defer l.mu.Unlock()

	b, ok := l.buckets[key]
	if !ok || !now.Before(b.resetAt) {
		l.buckets[key] = &bucket{count: 1, resetAt: now.Add(window)}
		return true
	}

	b.count++
	return b.count <= limit
}

// Close stops the sweeper goroutine. Idempotent-unsafe by design (a second
// call panics on the closed channel) — there is exactly one owner of a
// limiter, the process that constructed it.
//
// Deliberately NOT part of the Limiter interface: a shared-store
// implementation has a connection to close, an in-memory one has a
// goroutine, and a no-op one has neither. Lifecycle belongs to whoever
// constructed the concrete type (cmd/gateway), not to every middleware that
// merely calls Allow.
func (l *InMemory) Close() {
	close(l.stop)
}

func (l *InMemory) sweepLoop() {
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-l.stop:
			return
		case <-ticker.C:
			l.sweep()
		}
	}
}

func (l *InMemory) sweep() {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	for key, b := range l.buckets {
		if !now.Before(b.resetAt) {
			delete(l.buckets, key)
		}
	}
}

// Compile-time proof that the concrete limiter satisfies the seam. Cheap
// insurance: a signature drift on Allow should fail here, at the definition,
// rather than at whichever call site happens to be compiled first.
var _ Limiter = (*InMemory)(nil)
