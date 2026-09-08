package eventbus

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
)

// countingFailures is a test double for the Prometheus counter, so these
// tests assert on real counts without touching the process-wide registry.
type countingFailures struct {
	mu     sync.Mutex
	counts map[string]int
}

func newCountingFailures() *countingFailures {
	return &countingFailures{counts: map[string]int{}}
}

func (c *countingFailures) Inc(topic, kind string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[topic+"/"+kind]++
}

func (c *countingFailures) get(topic, kind string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.counts[topic+"/"+kind]
}

// TestPublish_PanickingHandlerDoesNotReachThePublisher is the specific
// failure §A1 closes. Before the fix, a handler panic propagated up through
// Publish onto the PUBLISHING request's goroutine — so a bug in the
// nearby-notify consumer would crash the CreateMeetup request that
// triggered it. The publisher must survive, and the panic must be recorded
// rather than silently absorbed.
func TestPublish_PanickingHandlerDoesNotReachThePublisher(t *testing.T) {
	failures := newCountingFailures()
	bus := newWithCounter(slog.New(slog.DiscardHandler), failures)

	bus.Subscribe(TopicMeetupCreated, func(context.Context, Event) error {
		panic("nearby-notify consumer dereferenced something nil")
	})

	// Publish must return normally. If the panic escaped, this test binary
	// crashes here instead of failing — which is itself the regression
	// signal, but the explicit recover below makes the failure legible.
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				t.Fatalf("a handler panic escaped Publish and reached the publisher: %v", rec)
			}
		}()
		if err := bus.Publish(context.Background(), TopicMeetupCreated, MeetupCreatedPayload{MeetupID: "m-1"}); err != nil {
			t.Fatalf("Publish() error: %v", err)
		}
	}()

	if got := failures.get(TopicMeetupCreated, "panic"); got != 1 {
		t.Errorf("panic counter = %d, want 1 — a recovered panic is a failure and must be counted, not silently absorbed", got)
	}
	if got := failures.get(TopicMeetupCreated, "error"); got != 0 {
		t.Errorf("error counter = %d, want 0 — a panic must be distinguishable from a returned error", got)
	}
}

// TestPublish_PanickingHandlerDoesNotStopLaterHandlers pins containment at
// the per-handler level, not the per-publish level: one broken consumer must
// not deprive every other consumer of the same topic.
func TestPublish_PanickingHandlerDoesNotStopLaterHandlers(t *testing.T) {
	bus := newWithCounter(slog.New(slog.DiscardHandler), newCountingFailures())

	var ranBefore, ranAfter bool
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { ranBefore = true; return nil })
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { panic("boom") })
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { ranAfter = true; return nil })

	if err := bus.Publish(context.Background(), TopicUserOnboarded, UserOnboardedPayload{UserID: "u-1"}); err != nil {
		t.Fatalf("Publish() error: %v", err)
	}

	if !ranBefore {
		t.Error("the handler registered before the panicking one did not run")
	}
	if !ranAfter {
		t.Error("the handler registered after the panicking one did not run — a panic must be contained to its own handler")
	}
}

// TestPublish_SwallowedErrorIsCountedAndGreppable covers the other half of
// §A1: a returned error was already logged, but with nothing an operator
// could alert on. The counter is the durable signal; the fixed
// `event=handler_failure` field is the pre-metrics fallback the hardening
// pass asked for by name, so a log-volume alert can be written against a
// stable shape.
func TestPublish_SwallowedErrorIsCountedAndGreppable(t *testing.T) {
	var logBuf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logBuf, &slog.HandlerOptions{Level: slog.LevelError}))
	failures := newCountingFailures()
	bus := newWithCounter(logger, failures)

	bus.Subscribe(TopicRatingUpdated, func(context.Context, Event) error {
		return errors.New("rating cache upsert failed")
	})

	if err := bus.Publish(context.Background(), TopicRatingUpdated, RatingUpdatedPayload{UserID: "u-1"}); err != nil {
		t.Fatalf("Publish() error: %v", err)
	}

	if got := failures.get(TopicRatingUpdated, "error"); got != 1 {
		t.Errorf("error counter = %d, want 1", got)
	}

	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(logBuf.Bytes()), &line); err != nil {
		t.Fatalf("failure log line is not valid JSON (%v): %q", err, logBuf.String())
	}
	if line["level"] != "ERROR" {
		t.Errorf("level = %v, want ERROR", line["level"])
	}
	if line["event"] != handlerFailureLogEvent {
		t.Errorf("event field = %v, want %q — the alertable field must be present and fixed", line["event"], handlerFailureLogEvent)
	}
	if line["topic"] != TopicRatingUpdated {
		t.Errorf("topic field = %v, want %q", line["topic"], TopicRatingUpdated)
	}
	if line["kind"] != "error" {
		t.Errorf("kind field = %v, want \"error\"", line["kind"])
	}
}

// TestPublish_PanicLogCarriesAStack asserts the recovered panic is
// debuggable — a contained panic with no stack trace just relocates the
// problem from "it crashed" to "something failed, no idea where."
func TestPublish_PanicLogCarriesAStack(t *testing.T) {
	var logBuf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logBuf, &slog.HandlerOptions{Level: slog.LevelError}))
	bus := newWithCounter(logger, newCountingFailures())

	bus.Subscribe(TopicUserLocationUpdated, func(context.Context, Event) error { panic("boom") })
	_ = bus.Publish(context.Background(), TopicUserLocationUpdated, UserLocationUpdatedPayload{UserID: "u-1"})

	var line map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(logBuf.Bytes()), &line); err != nil {
		t.Fatalf("panic log line is not valid JSON (%v): %q", err, logBuf.String())
	}
	if line["panic"] != "boom" {
		t.Errorf("panic field = %v, want \"boom\"", line["panic"])
	}
	stack, _ := line["stack"].(string)
	if !strings.Contains(stack, "eventbus") {
		t.Errorf("stack field does not point at the bus: %q", stack)
	}
}
