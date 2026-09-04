// Package breaker is a minimal circuit breaker — hand-rolled rather than a
// dependency (e.g. sony/gobreaker), matching this codebase's existing
// preference for small, self-contained utilities over new third-party
// dependencies (the gateway's own rate limiter, the auth module's OTP/JWT
// code). Ported essentially unchanged from
// ../Professional-Meetups/backend/shared/breaker.
//
// It has exactly ONE call site here, and that is the point of ADR-001's
// 2026-09-04 correction: the source used this in two unrelated places, and
// only one of them was meant to go away.
//
//   - GONE, correctly (ADR-001 §4): the outbox relay's breaker around a
//     Pub/Sub publish. That failure mode — a network publish failing
//     independently of the DB commit it was paired with — does not exist for
//     an in-process event bus, so neither the outbox, the relay, nor its
//     breaker is carried over.
//   - KEPT, and restored here: the SOS-alert send path's per-channel breaker
//     (internal/modules/auth/sos). That one protects a synchronous call to a
//     third-party vendor (Twilio, Resend) on an EMERGENCY path, which has
//     nothing to do with events or outboxes and is identical in this repo —
//     those are still real external HTTP calls made the same way. Without it,
//     every TriggerSOS during a Twilio outage pays the full
//     retry-and-timeout cost per contact against a channel already known to
//     be down.
package breaker

import (
	"errors"
	"sync"
	"time"
)

// ErrOpen is returned by Execute without running fn when the breaker is
// open (too many recent consecutive failures) and the reset timeout
// hasn't elapsed yet.
var ErrOpen = errors.New("breaker: circuit open")

type state int

const (
	closed state = iota
	open
	halfOpen
)

// Breaker is safe for concurrent use.
type Breaker struct {
	failureThreshold int
	resetTimeout     time.Duration

	mu       sync.Mutex
	state    state
	failures int
	openedAt time.Time
}

// New returns a Breaker that opens after failureThreshold consecutive
// failures and, after resetTimeout has elapsed, allows exactly one trial
// call through (half-open) — a success there closes it again, a failure
// re-opens it and restarts the timeout.
func New(failureThreshold int, resetTimeout time.Duration) *Breaker {
	return &Breaker{failureThreshold: failureThreshold, resetTimeout: resetTimeout}
}

// Execute runs fn if the breaker allows it, and records the outcome.
// Returns ErrOpen (fn not called at all) if the breaker is open and the
// reset timeout hasn't elapsed.
func (b *Breaker) Execute(fn func() error) error {
	if !b.allow() {
		return ErrOpen
	}

	err := fn()
	b.record(err)
	return err
}

func (b *Breaker) allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	switch b.state {
	case open:
		if time.Since(b.openedAt) < b.resetTimeout {
			return false
		}
		// Reset timeout elapsed — allow exactly one trial call through
		// (half-open) without fully closing yet.
		b.state = halfOpen
		return true
	default: // closed, halfOpen
		return true
	}
}

func (b *Breaker) record(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if err == nil {
		b.failures = 0
		b.state = closed
		return
	}

	b.failures++
	if b.state == halfOpen || b.failures >= b.failureThreshold {
		b.state = open
		b.openedAt = time.Now()
	}
}
