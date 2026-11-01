package analytics

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// stalledWriter blocks every write until released: a database that has
// stopped answering.
type stalledWriter struct {
	release chan struct{}
	writes  atomic.Int64
	events  atomic.Int64
}

func (w *stalledWriter) Write(ctx context.Context, events []repository.Event) (repository.WriteResult, error) {
	w.writes.Add(1)
	select {
	case <-w.release:
	case <-ctx.Done():
		return repository.WriteResult{}, ctx.Err()
	}
	w.events.Add(int64(len(events)))
	return repository.WriteResult{Inserted: len(events)}, nil
}

func event() repository.Event {
	return repository.Event{EventID: uuid.New(), Name: "screen_viewed", ReceivedAt: time.Now()}
}

// TestAFullBufferDropsWithoutBlocking is the plan's stalled-writer test:
// the flusher is stuck inside a write that never returns, and the producer
// keeps offering. Every Offer must return at once, the overflow must be
// dropped and counted, and nothing may wait on the database.
func TestAFullBufferDropsWithoutBlocking(t *testing.T) {
	w := &stalledWriter{release: make(chan struct{})}
	const capacity = 100
	b := NewBuffer(w, capacity, time.Hour, 10, nil)
	ctx, cancel := context.WithCancel(context.Background())
	go b.Run(ctx)
	defer func() { close(w.release); cancel(); <-b.Done() }()

	dropsBefore := testutil.ToFloat64(metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropBufferFull))

	// Fill one batch so the flusher takes it and stalls in Write.
	for i := 0; i < 10; i++ {
		b.Offer(event())
	}
	deadline := time.Now().Add(2 * time.Second)
	for w.writes.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if w.writes.Load() == 0 {
		t.Fatal("the flusher never started a write")
	}

	// Now offer far more than fits, timing every call.
	const offers = 50_000
	var slowest time.Duration
	accepted, dropped := 0, 0
	start := time.Now()
	for i := 0; i < offers; i++ {
		t0 := time.Now()
		if b.Offer(event()) {
			accepted++
		} else {
			dropped++
		}
		if d := time.Since(t0); d > slowest {
			slowest = d
		}
	}
	total := time.Since(start)

	if accepted > capacity {
		t.Errorf("accepted %d into a buffer of %d", accepted, capacity)
	}
	if dropped < offers-capacity {
		t.Errorf("dropped %d, want at least %d", dropped, offers-capacity)
	}
	if got := testutil.ToFloat64(metrics.Default.AnalyticsEventsDropped.WithLabelValues(registry.DropBufferFull)) - dropsBefore; int(got) != dropped {
		t.Errorf("counted %v drops, made %d", got, dropped)
	}
	// Generous bounds for -race on a loaded CI machine; a blocking Offer
	// would take the full hour-long flush interval.
	if slowest > 50*time.Millisecond || total > 5*time.Second {
		t.Errorf("Offer blocked: slowest %v, total %v for %d offers", slowest, total, offers)
	}
	t.Logf("%d offers in %v (slowest %v): %d accepted, %d dropped", offers, total, slowest, accepted, dropped)
}

func TestTheBufferFlushesBySizeTimeAndShutdown(t *testing.T) {
	w := &countingWriter{}
	b := NewBuffer(w, 1000, 20*time.Millisecond, 5, nil)
	ctx, cancel := context.WithCancel(context.Background())
	go b.Run(ctx)

	for i := 0; i < 5; i++ {
		b.Offer(event())
	}
	waitFor(t, func() bool { return w.total() == 5 }, "a full batch to flush")
	b.Offer(event())
	waitFor(t, func() bool { return w.total() == 6 }, "the timer to flush a partial batch")

	// On shutdown, what is queued is written before Run returns.
	b2 := NewBuffer(w, 1000, time.Hour, 500, nil)
	ctx2, cancel2 := context.WithCancel(context.Background())
	go b2.Run(ctx2)
	for i := 0; i < 7; i++ {
		b2.Offer(event())
	}
	cancel2()
	<-b2.Done()
	if w.total() != 13 {
		t.Errorf("after shutdown %d written, want 13", w.total())
	}
	cancel()
	<-b.Done()
}

func TestSyncWritesWhatIsQueued(t *testing.T) {
	w := &countingWriter{}
	b := NewBuffer(w, 1000, time.Hour, 500, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() { cancel(); <-b.Done() }()
	go b.Run(ctx)
	for i := 0; i < 3; i++ {
		b.Offer(event())
	}
	b.Sync(context.Background())
	if w.total() != 3 {
		t.Errorf("after Sync %d written, want 3", w.total())
	}
}

type countingWriter struct {
	mu sync.Mutex
	n  int
}

func (w *countingWriter) Write(_ context.Context, events []repository.Event) (repository.WriteResult, error) {
	w.mu.Lock()
	w.n += len(events)
	w.mu.Unlock()
	return repository.WriteResult{Inserted: len(events)}, nil
}

func (w *countingWriter) total() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.n
}

func waitFor(t *testing.T, ok func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
