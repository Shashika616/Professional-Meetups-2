package eventbus

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func newTestBus() *InMemoryBus {
	return New(slog.New(slog.DiscardHandler))
}

func TestPublish_DeliversToEverySubscriberOfThatTopicOnly(t *testing.T) {
	bus := newTestBus()

	var onboarded, profileUpdated, secondOnboarded int
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { onboarded++; return nil })
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { secondOnboarded++; return nil })
	bus.Subscribe(TopicUserProfileUpdated, func(context.Context, Event) error { profileUpdated++; return nil })

	if err := bus.Publish(context.Background(), TopicUserOnboarded, UserOnboardedPayload{UserID: "user-1"}); err != nil {
		t.Fatalf("Publish() error: %v", err)
	}

	if onboarded != 1 || secondOnboarded != 1 {
		t.Errorf("user-onboarded handlers ran %d/%d times, want 1/1 — every subscriber of a topic gets the event",
			onboarded, secondOnboarded)
	}
	if profileUpdated != 0 {
		t.Errorf("user-profile-updated handler ran %d times, want 0 — a subscriber must not see another topic's events", profileUpdated)
	}
}

// TestPublish_IsSynchronous pins the choice ADR-001 §4 makes explicitly: no
// goroutines, no channels. By the time Publish returns, every handler has
// already run — which is what lets a caller (and a test) reason about the
// handler's effects immediately after the business write.
func TestPublish_IsSynchronous(t *testing.T) {
	bus := newTestBus()
	ran := false
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error {
		time.Sleep(10 * time.Millisecond)
		ran = true
		return nil
	})

	_ = bus.Publish(context.Background(), TopicUserOnboarded, nil)

	if !ran {
		t.Error("handler had not finished when Publish returned — Publish must be synchronous")
	}
}

// TestPublish_HandlerFailureIsSwallowedAndDoesNotStopOtherHandlers is the
// "best-effort, never fail the request" posture: the business write has
// already committed by the time Publish is called, so a failing consumer
// must not be reported to the publisher as a failure, and must not prevent
// the other consumers of the same event from running.
func TestPublish_HandlerFailureIsSwallowedAndDoesNotStopOtherHandlers(t *testing.T) {
	bus := newTestBus()
	secondRan := false
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { return errors.New("consumer exploded") })
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error { secondRan = true; return nil })

	if err := bus.Publish(context.Background(), TopicUserOnboarded, nil); err != nil {
		t.Errorf("Publish() = %v, want nil — a handler failure must never be propagated to the publisher", err)
	}
	if !secondRan {
		t.Error("the second handler did not run — one failing consumer must not starve the others")
	}
}

func TestPublish_WithNoSubscribersIsANoOp(t *testing.T) {
	if err := newTestBus().Publish(context.Background(), TopicRatingUpdated, nil); err != nil {
		t.Errorf("Publish() to an unsubscribed topic = %v, want nil", err)
	}
}

// TestPublish_StampsOccurredAt covers why Event carries a timestamp at all:
// every consumer in this codebase guards against a stale/duplicate delivery
// by comparing the event's own time against what it has already stored, so
// the bus must stamp one rather than leaving it to each publisher.
func TestPublish_StampsOccurredAt(t *testing.T) {
	bus := newTestBus()
	var got Event
	bus.Subscribe(TopicUserLocationUpdated, func(_ context.Context, e Event) error { got = e; return nil })

	before := time.Now().UTC()
	_ = bus.Publish(context.Background(), TopicUserLocationUpdated, UserLocationUpdatedPayload{UserID: "user-1"})
	after := time.Now().UTC()

	if got.OccurredAt.IsZero() {
		t.Fatal("OccurredAt is zero — Publish must stamp it")
	}
	if got.OccurredAt.Before(before) || got.OccurredAt.After(after) {
		t.Errorf("OccurredAt = %v, want it between %v and %v", got.OccurredAt, before, after)
	}
	if got.Topic != TopicUserLocationUpdated {
		t.Errorf("Topic = %q, want %q", got.Topic, TopicUserLocationUpdated)
	}
	if _, ok := got.Payload.(UserLocationUpdatedPayload); !ok {
		t.Errorf("Payload type = %T, want UserLocationUpdatedPayload — payloads pass through untouched", got.Payload)
	}
}

// TestBus_ConcurrentPublishAndSubscribe is a race-detector target (the suite
// is also run with -race): the bus is shared by every module in one process,
// so its map has to survive concurrent use.
func TestBus_ConcurrentPublishAndSubscribe(t *testing.T) {
	bus := newTestBus()
	var mu sync.Mutex
	count := 0
	bus.Subscribe(TopicUserOnboarded, func(context.Context, Event) error {
		mu.Lock()
		defer mu.Unlock()
		count++
		return nil
	})

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _ = bus.Publish(context.Background(), TopicUserOnboarded, nil) }()
		go func() {
			defer wg.Done()
			bus.Subscribe("some-other-topic", func(context.Context, Event) error { return nil })
		}()
	}
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if count != 50 {
		t.Errorf("handler ran %d times, want 50", count)
	}
}
