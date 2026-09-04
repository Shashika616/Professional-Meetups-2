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
package eventbus

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// Event is one published event. OccurredAt is stamped by Publish itself, so
// every consumer compares against a single, publisher-side notion of "when
// this happened" rather than when it happened to be processed.
type Event struct {
	Topic      string
	Payload    any
	OccurredAt time.Time
}

// Handler reacts to one event. A returned error is logged and swallowed by
// Publish — see the package comment for why that is the correct posture
// here, not a shortcut.
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

	mu       sync.RWMutex
	handlers map[string][]Handler
}

// New constructs an InMemoryBus. logger receives one line per failed
// handler; pass slog.Default() if you have nothing more specific.
func New(logger *slog.Logger) *InMemoryBus {
	if logger == nil {
		logger = slog.Default()
	}
	return &InMemoryBus{logger: logger, handlers: make(map[string][]Handler)}
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
		if err := handler(ctx, event); err != nil {
			b.logger.Error("event handler failed",
				"topic", topic,
				"error", err,
			)
		}
	}
	return nil
}
