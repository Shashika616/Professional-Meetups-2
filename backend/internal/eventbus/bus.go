// Package eventbus is the in-process replacement for the sibling
// microservices repo's Pub/Sub + transactional-outbox machinery (ADR-001
// §4). Same publish/subscribe programming model, zero extra infrastructure:
// deploying this system is exactly two things, the gateway and the monolith.
//
// What this deliberately does NOT have, and why:
//
//   - No outbox table, no relay poll-loop, no circuit breaker. Those existed
//     to make publish-then-network-call safe when the publish and the
//     business write could not share a transaction. In one process against
//     one database that failure mode doesn't exist: the business write
//     commits, then Publish runs synchronously in the same request.
//   - No goroutines, no channels, no retry. There is nothing to retry
//     against — a handler failure is a same-request concern, handled the way
//     the async relay's failures were: logged, never propagated back to the
//     caller (a nearby-notification handler failing must not fail the
//     signup/RPC that triggered it).
//
// What consumers still keep is the idempotent-upsert-with-timestamp-guard
// pattern, which is why Event carries OccurredAt: a handler can still run
// twice (a retry higher up), and it stays the consumer's job to notice.
//
// # ACCEPTED DATA-LOSS WINDOW — read this before debugging "why didn't this
// # user get notified"
//
// There is no durability here at all. A business write commits, and THEN
// Publish is called. If the process dies in between — SIGKILL, OOM, a
// container eviction, a panic that escapes recovery — that event is gone
// permanently. Nothing replays it: there is no outbox row, no write-ahead
// log, no broker holding an unacknowledged message. The database shows the
// write succeeded and no consumer ever saw it.
//
// This is an accepted trade-off (ADR-001 §4), not an oversight, and it is
// tolerable because every topic on this bus feeds an IDEMPOTENT CACHE
// UPSERT. Losing one leaves a cache briefly stale; it self-heals on the
// next event touching the same row, and cmd/backfill-user-display-cache /
// cmd/backfill-user-location-cache exist to rebuild those caches wholesale
// for the case where it doesn't. The cost of a lost event here is bounded
// and recoverable.
//
// ONE TOPIC IS DELIBERATELY NOT ON THIS BUS for exactly that reason.
// push-notification-requested had no such self-healing path — nothing would
// ever re-send "the host accepted your request" — so it moved to a
// Postgres-backed outbox written in the same transaction as its business
// write (ADR-001's "Correction (2026-09-04, durable notification
// delivery)", docs/plans/03-hardening-pass.md §F). See
// internal/platform/outbox and internal/modules/notification. If a future
// topic has that same profile — user-facing, one-shot, no self-heal — it
// belongs there too, not here.
package eventbus

import (
	"context"
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync"
	"time"

	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// Event is one published event. OccurredAt is stamped by Publish itself, so
// every consumer compares against a single, publisher-side notion of "when
// this happened" rather than when it happened to be processed.
type Event struct {
	Topic      string
	Payload    any
	OccurredAt time.Time
}

// Handler reacts to one event. A returned error is logged, counted, and
// swallowed by Publish — see the package comment for why that is the
// correct posture here, not a shortcut. A handler that PANICS is likewise
// contained (recovered, logged, counted) rather than taking down the
// publishing request.
type Handler func(ctx context.Context, e Event) error

// Bus is the publish/subscribe surface every module codes against. Kept as
// an interface (rather than the concrete type) so a module's Subscribe calls
// are the only thing that has to change if a module is ever re-extracted
// into its own service behind real Pub/Sub.
type Bus interface {
	Publish(ctx context.Context, topic string, payload any) error
	Subscribe(topic string, handler Handler)
}

// InMemoryBus is the only implementation. Safe for concurrent use.
type InMemoryBus struct {
	logger *slog.Logger

	// failures counts swallowed handler failures by (topic, kind). Nil is
	// valid and means "don't count" — tests construct a bus without wanting
	// to mutate the process-wide registry.
	failures failureCounter

	mu       sync.RWMutex
	handlers map[string][]Handler
}

// failureCounter is the narrow slice of the metrics package this file needs.
// An interface rather than the concrete *prometheus.CounterVec so a test can
// assert on counts without a registry, and so internal/eventbus does not
// become a package that cannot be constructed without Prometheus.
type failureCounter interface {
	Inc(topic, kind string)
}

type promFailureCounter struct{}

func (promFailureCounter) Inc(topic, kind string) {
	metrics.Default.EventHandlerFailures.WithLabelValues(topic, kind).Inc()
}

// New constructs an InMemoryBus. logger receives one line per failed
// handler; pass slog.Default() if you have nothing more specific.
func New(logger *slog.Logger) *InMemoryBus {
	if logger == nil {
		logger = slog.Default()
	}
	return &InMemoryBus{
		logger:   logger,
		failures: promFailureCounter{},
		handlers: make(map[string][]Handler),
	}
}

// newWithCounter is New with the failure counter substituted — tests only.
func newWithCounter(logger *slog.Logger, counter failureCounter) *InMemoryBus {
	b := New(logger)
	b.failures = counter
	return b
}

// Subscribe registers handler for topic. Intended to be called during
// startup wiring (cmd/monolith's main), before any Publish — it is
// mutex-guarded anyway, but a subscription registered mid-flight would
// silently miss events published before it.
func (b *InMemoryBus) Subscribe(topic string, handler Handler) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.handlers[topic] = append(b.handlers[topic], handler)
}

// Publish invokes every handler subscribed to topic, synchronously, in
// registration order, and always returns nil: a handler failing is logged
// and skipped, never propagated to the publisher. This is the same
// best-effort posture the outbox relay had — the business write has already
// committed by the time Publish is called, so failing the caller here would
// report a failure for work that actually succeeded.
//
// The error return exists so the interface can accommodate a future
// implementation where publishing itself can fail (a real broker, if a
// module is ever re-extracted). Callers should still check it.
func (b *InMemoryBus) Publish(ctx context.Context, topic string, payload any) error {
	event := Event{Topic: topic, Payload: payload, OccurredAt: time.Now().UTC()}

	b.mu.RLock()
	handlers := b.handlers[topic]
	b.mu.RUnlock()

	for _, handler := range handlers {
		b.invoke(ctx, event, handler)
	}
	return nil
}

// handlerFailureLogEvent is the fixed `event` field on every swallowed
// handler failure. Fixed and greppable on purpose: this is the one log line
// an operator can alert on by volume alone, and it has to look identical
// whether the handler returned an error or panicked, or an alert written
// against one shape silently misses the other.
const handlerFailureLogEvent = "handler_failure"

// invoke runs one handler with its own recover(), so a panicking consumer
// is contained to itself.
//
// WHY THIS MATTERS MORE HERE THAN ANYWHERE ELSE (§A1): Publish runs
// synchronously on the PUBLISHER's goroutine. Without this recover, a bug in
// the nearby-notify fan-out handler would panic the CreateMeetup request
// that triggered it — a consumer defect crashing an unrelated producer's
// request. That is a strictly worse blast radius than the microservices
// system this replaced, where the same bug could only ever affect the
// consuming service's own process. The gRPC and HTTP layers already contain
// panics exactly this way (internal/platform/logging/recovery.go,
// internal/gateway/middleware/recover.go); this is the same pattern applied
// at the third place a foreign function gets called on a request goroutine.
//
// A recovered panic is a FAILURE, not a success: it is logged at ERROR and
// counted under kind="panic", distinguishable from kind="error" so an
// operator can tell "this handler is returning errors" from "this handler is
// crashing," which usually have different causes.
func (b *InMemoryBus) invoke(ctx context.Context, event Event, handler Handler) {
	defer func() {
		if rec := recover(); rec != nil {
			b.recordFailure(event.Topic, "panic",
				"panic", fmt.Sprint(rec),
				"stack", string(debug.Stack()),
			)
		}
	}()

	if err := handler(ctx, event); err != nil {
		b.recordFailure(event.Topic, "error", "error", err)
	}
}

// recordFailure logs and counts one swallowed handler failure. Both halves
// on purpose: the counter (exposed at /metrics) is what distinguishes "once,
// weeks ago" from "on every event," and the log line is what says which
// event and why.
func (b *InMemoryBus) recordFailure(topic, kind string, detail ...any) {
	args := append([]any{
		"event", handlerFailureLogEvent,
		"topic", topic,
		"kind", kind,
	}, detail...)
	b.logger.Error("event handler failed", args...)

	if b.failures != nil {
		b.failures.Inc(topic, kind)
	}
}
