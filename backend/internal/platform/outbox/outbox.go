// Package outbox is the generic claim/retry/backoff/dead-letter machinery
// behind durable, at-least-once delivery of side effects that must not be
// lost (docs/plans/03-hardening-pass.md §F2).
//
// # WHAT THIS IS AND IS NOT
//
// It knows nothing about notifications, FCM, or device tokens. It knows how
// to claim due rows without two claimers colliding, hand them to a caller-
// supplied process function, and record what happened. The notification
// module supplies the process function; a future module wanting the same
// guarantee for one of its own topics supplies a different one, and does not
// re-derive any of this.
//
// It is deliberately NOT a general replacement for internal/eventbus. ADR-001
// §4's decision — synchronous in-process publish, no outbox, no relay — still
// holds for every topic whose loss is self-healing (the idempotent cache
// upserts). This exists for the one topic where loss is permanent and
// user-visible. See ADR-001's "Correction (2026-09-04, durable notification
// delivery)".
//
// # AT-LEAST-ONCE, NOT EXACTLY-ONCE
//
// If the process dies after the side effect succeeds but before MarkProcessed
// commits, the row is claimed again and the side effect runs twice. That is
// accepted, not overlooked: it is the trade-off every outbox-shaped system
// makes, and it is the right one HERE specifically because the side effect is
// a push notification. A duplicate "your request was accepted" is a minor
// annoyance; the alternative failure (at-most-once, losing it entirely) is
// the thing this package exists to prevent. No idempotency key is added, and
// that absence is a decision rather than an omission. A future caller whose
// side effect is NOT safely repeatable — a payment, say — must not use this
// package as-is.
package outbox

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"time"
)

// Row is one claimed unit of work. Payload is opaque here — its shape is
// entirely the caller's business, and this package never looks inside it.
type Row struct {
	ID       string
	Payload  []byte
	Attempts int
}

// Store is the persistence this poller drives. The implementation lives with
// whichever module owns the table (ADR-001 §3); for notifications that is
// internal/modules/meetup/repository.
type Store interface {
	// ClaimBatch returns up to limit unprocessed, due rows, locked
	// FOR UPDATE SKIP LOCKED for the duration of the caller's processing.
	//
	// SKIP LOCKED is doing two jobs. The obvious one: a second poller — a
	// horizontally-scaled monolith, or two ticks overlapping — gets a
	// DISJOINT set rather than the same rows, so nothing is processed twice
	// concurrently. The less obvious one: crash recovery is free. A claimer
	// that dies mid-processing never has to release anything, because
	// Postgres drops its locks when the connection ends and the rows become
	// claimable again on their own. There is no lease table, no stuck-claim
	// reaper, and no "claimed_at is older than N minutes" heuristic to get
	// wrong.
	ClaimBatch(ctx context.Context, limit int) ([]Row, error)
	// MarkProcessed records a successful delivery. Terminal.
	MarkProcessed(ctx context.Context, id string) error
	// MarkFailed records a retryable failure and schedules the next attempt.
	MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error
	// MarkDeadLettered abandons a row past its retry ceiling. Terminal, but
	// the row is kept — a permanent delivery failure is evidence.
	MarkDeadLettered(ctx context.Context, id string, lastErr string) error
	// CountPending reports how many rows are still awaiting delivery,
	// for the gauge. A best-effort read; an error here never fails a tick.
	CountPending(ctx context.Context) (int, error)
}

// Defaults. Every one is overridable per-poller; these are what the
// notification poller actually runs with.
const (
	// DefaultBatchSize bounds one tick's claim. Small enough that a tick
	// stays short and a crash loses little work; large enough that a burst
	// (a fan-out to hundreds of nearby users) drains in a few ticks rather
	// than hundreds.
	DefaultBatchSize = 50

	// DefaultTickInterval is the SAFETY NET, not the primary delivery path.
	// Common-case latency comes from Wake (see below), which fires the
	// instant a business write commits. This tick exists for the cases Wake
	// cannot cover: a nudge coalesced away under load, a backoff deadline
	// coming due with no new writes happening, and rows that piled up while
	// the process was down.
	//
	// # WHY 30s AND NOT SOMETHING TIGHTER
	//
	// This loop runs once per CONTAINER, not once per deployment. Cloud Run
	// scales horizontally and every instance runs the whole binary, so ten
	// instances mean ten of these tickers, each issuing a ClaimBatch (and a
	// CountPending, when an observer is attached) against the same table.
	// SKIP LOCKED keeps that CORRECT — the losers claim nothing — but it
	// makes them cheap, not free: each is still a real round trip to
	// Postgres. At the 2s this used to be, that is a per-instance floor of
	// roughly one query a second that no user asked for, and it grows with
	// container count rather than with load.
	//
	// 30s costs nothing in exchange. It backstops a retry ladder running
	// from DefaultBaseDelay (5s) to DefaultMaxDelay (10min), so it stays an
	// order of magnitude finer than the deadlines it exists to catch, and it
	// is not in the path of any notification a user actually waits on.
	// TestRun_WakeTriggersADrain pins exactly that: it sets this to an hour
	// and delivery still happens, because Wake is what drives it.
	DefaultTickInterval = 30 * time.Second

	// DefaultBaseDelay and DefaultMaxDelay bound exponential backoff.
	DefaultBaseDelay = 5 * time.Second
	DefaultMaxDelay  = 10 * time.Minute

	// DefaultMaxAttempts is the dead-letter ceiling. Retrying forever turns
	// one permanently-undeliverable row into an unbounded, permanent source
	// of load and log noise; giving up eventually and marking it so someone
	// can find it is the correct posture.
	DefaultMaxAttempts = 10
)

// Option configures a Poller.
type Option func(*Poller)

// WithBatchSize sets how many rows one tick claims.
func WithBatchSize(n int) Option { return func(p *Poller) { p.batchSize = n } }

// WithTickInterval sets the safety-net tick.
func WithTickInterval(d time.Duration) Option { return func(p *Poller) { p.tickInterval = d } }

// WithBackoff sets the exponential-backoff base and ceiling.
func WithBackoff(base, max time.Duration) Option {
	return func(p *Poller) { p.baseDelay, p.maxDelay = base, max }
}

// WithMaxAttempts sets the dead-letter ceiling.
func WithMaxAttempts(n int) Option { return func(p *Poller) { p.maxAttempts = n } }

// WithLogger sets the logger.
func WithLogger(l *slog.Logger) Option { return func(p *Poller) { p.logger = l } }

// WithObserver attaches delivery counters. Nil-safe; a Poller without one
// simply records nothing.
func WithObserver(o Observer) Option { return func(p *Poller) { p.observer = o } }

// WithClock substitutes the time source. Tests only — it is what lets the
// backoff schedule be asserted without sleeping through it.
func WithClock(now func() time.Time) Option { return func(p *Poller) { p.now = now } }

// Observer receives delivery outcomes. An interface rather than a direct
// dependency on internal/platform/metrics so this package stays usable (and
// testable) without a Prometheus registry.
type Observer interface {
	Delivered()
	Failed()
	DeadLettered()
	Pending(n int)
}

// ErrPermanent marks a failure that must not be retried — the side effect
// will never succeed for this row no matter how many times it is attempted.
// A process function returning an error wrapping this sends the row straight
// to the dead-letter state instead of burning its full retry budget on a
// known-hopeless payload.
var ErrPermanent = errors.New("outbox: permanent failure, do not retry")

// Poller claims due rows and drives them through process until they succeed
// or exhaust their retries.
type Poller struct {
	store   Store
	process func(ctx context.Context, r Row) error

	batchSize    int
	tickInterval time.Duration
	baseDelay    time.Duration
	maxDelay     time.Duration
	maxAttempts  int
	logger       *slog.Logger
	observer     Observer
	now          func() time.Time

	// wake is a buffered, single-slot channel. See Wake.
	wake chan struct{}
}

// New constructs a Poller over store, delivering each claimed row via
// process.
func New(store Store, process func(ctx context.Context, r Row) error, opts ...Option) *Poller {
	p := &Poller{
		store:        store,
		process:      process,
		batchSize:    DefaultBatchSize,
		tickInterval: DefaultTickInterval,
		baseDelay:    DefaultBaseDelay,
		maxDelay:     DefaultMaxDelay,
		maxAttempts:  DefaultMaxAttempts,
		logger:       slog.Default(),
		now:          time.Now,
		wake:         make(chan struct{}, 1),
	}
	for _, opt := range opts {
		opt(p)
	}
	return p
}

// Wake nudges the poller to drain now instead of waiting for the next tick.
//
// THIS IS WHY THIS DOES NOT BEHAVE LIKE POLLING. The writer (a meetup
// business method) and this poller share a process, so a commit can tell the
// poller about itself immediately — an option a separate microservice
// consumer reading the same table would not have. Common-case delivery
// latency is therefore roughly "as fast as the FCM call", not "up to one
// tick interval".
//
// Non-blocking by construction: the channel holds one slot and a send that
// would block is dropped. A dropped nudge is harmless — it can only mean a
// drain is already pending or in flight, and the safety-net tick catches
// anything that somehow falls between. Wake must never block a business
// request, which is exactly what a blocking send would eventually do.
//
// Safe to call from any goroutine, including before Run starts.
func (p *Poller) Wake() {
	select {
	case p.wake <- struct{}{}:
	default:
	}
}

// Run drains until ctx is cancelled, on both the wake signal and the
// safety-net tick. Same shape and lifecycle as every other background loop
// in this process (meetup.Poller, auth.RefreshTokenSweeper): started with
// `go p.Run(ctx)` from cmd/monolith, stops cleanly on SIGTERM.
func (p *Poller) Run(ctx context.Context) {
	ticker := time.NewTicker(p.tickInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-p.wake:
			p.DrainOnce(ctx)
		case <-ticker.C:
			p.DrainOnce(ctx)
		}
	}
}

// DrainOnce claims and processes batches until nothing is left due, or the
// context is cancelled. Exported so a test can drive one deterministic pass
// rather than racing a ticker.
//
// It loops rather than processing a single batch: a burst larger than one
// batch should drain now, not one batch per tick, which for a 500-recipient
// fan-out would otherwise take ten ticks to deliver the last recipient.
func (p *Poller) DrainOnce(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		claimed, err := p.claimAndProcess(ctx)
		if err != nil {
			p.logger.Error("outbox: claim batch", "error", err)
			return
		}
		if claimed < p.batchSize {
			// A short batch means the due set is exhausted.
			break
		}
	}

	if p.observer != nil {
		if pending, err := p.store.CountPending(ctx); err == nil {
			p.observer.Pending(pending)
		}
	}
}

// claimAndProcess handles exactly one batch and reports how many rows it
// claimed.
func (p *Poller) claimAndProcess(ctx context.Context) (int, error) {
	rows, err := p.store.ClaimBatch(ctx, p.batchSize)
	if err != nil {
		return 0, err
	}
	for _, row := range rows {
		p.deliver(ctx, row)
	}
	return len(rows), nil
}

// deliver runs one row's side effect and records the outcome.
//
// Every terminal write uses a context detached from the poller's own: if the
// process is shutting down mid-batch, a successful delivery must still be
// recorded as processed, or the row is redelivered on the next start and the
// user gets a duplicate for no reason. Losing the bookkeeping for work that
// actually happened is the one avoidable source of duplicates here.
func (p *Poller) deliver(ctx context.Context, row Row) {
	err := p.process(ctx, row)

	recordCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()

	if err == nil {
		if markErr := p.store.MarkProcessed(recordCtx, row.ID); markErr != nil {
			// The side effect DID happen; only the bookkeeping failed. The
			// row will be claimed again and delivered a second time — the
			// documented at-least-once behaviour, logged loudly because it
			// is also the only situation in which this system knowingly
			// produces a duplicate.
			p.logger.Error("outbox: delivered but failed to mark processed — this row will be redelivered",
				"row_id", row.ID, "error", markErr)
			return
		}
		if p.observer != nil {
			p.observer.Delivered()
		}
		return
	}

	attempts := row.Attempts + 1
	permanent := errors.Is(err, ErrPermanent)

	if permanent || attempts >= p.maxAttempts {
		reason := "exhausted retries"
		if permanent {
			reason = "permanent failure"
		}
		if markErr := p.store.MarkDeadLettered(recordCtx, row.ID, err.Error()); markErr != nil {
			p.logger.Error("outbox: failed to dead-letter row", "row_id", row.ID, "error", markErr)
			return
		}
		p.logger.Error("outbox: row dead-lettered",
			"row_id", row.ID, "attempts", attempts, "reason", reason, "error", err)
		if p.observer != nil {
			p.observer.DeadLettered()
		}
		return
	}

	next := p.now().Add(p.backoff(attempts))
	if markErr := p.store.MarkFailed(recordCtx, row.ID, next, err.Error()); markErr != nil {
		p.logger.Error("outbox: failed to record retry", "row_id", row.ID, "error", markErr)
		return
	}
	p.logger.Warn("outbox: delivery failed, will retry",
		"row_id", row.ID, "attempts", attempts, "next_attempt_at", next, "error", err)
	if p.observer != nil {
		p.observer.Failed()
	}
}

// backoff returns the delay before attempt number `attempts`.
//
// Plain capped exponential (base * 2^(attempts-1)), no jitter. Jitter matters
// when many independent clients retry against one dependency and would
// otherwise synchronise into a thundering herd; here a single in-process
// poller drains rows sequentially and cannot self-synchronise, so jitter
// would add a source of non-determinism to tests for no real benefit. The
// circuit breaker in the process function is what actually protects a
// struggling FCM from retry pressure.
func (p *Poller) backoff(attempts int) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	// Guard the shift before it happens: 2^63 overflows, and an attempts
	// value that large can only come from a corrupted row, which should back
	// off maximally rather than wrap around to a negative delay.
	if attempts > 32 {
		return p.maxDelay
	}
	delay := time.Duration(float64(p.baseDelay) * math.Pow(2, float64(attempts-1)))
	if delay > p.maxDelay || delay <= 0 {
		return p.maxDelay
	}
	return delay
}
