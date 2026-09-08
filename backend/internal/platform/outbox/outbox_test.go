package outbox

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"
)

// fakeStore is an in-memory Store. Fast unit coverage of the poller's
// decision logic — which row is retried, which is dead-lettered, when the
// next attempt is scheduled — none of which needs Postgres. The SQL-level
// guarantees (SKIP LOCKED, the visibility timeout, the partial index) are
// covered against the real database in the meetup module's own
// outbox_integration_test.go, because a fake cannot tell you anything about
// those.
type fakeStore struct {
	mu           sync.Mutex
	pending      []Row
	processed    []string
	failed       []failedCall
	deadLettered []deadLetterCall
	claimErr     error
}

type failedCall struct {
	id            string
	nextAttemptAt time.Time
	lastErr       string
}

type deadLetterCall struct {
	id      string
	lastErr string
}

func (s *fakeStore) ClaimBatch(_ context.Context, limit int) ([]Row, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.claimErr != nil {
		return nil, s.claimErr
	}
	if len(s.pending) == 0 {
		return nil, nil
	}
	n := min(limit, len(s.pending))
	claimed := s.pending[:n]
	s.pending = s.pending[n:]
	return claimed, nil
}

func (s *fakeStore) MarkProcessed(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.processed = append(s.processed, id)
	return nil
}

func (s *fakeStore) MarkFailed(_ context.Context, id string, next time.Time, lastErr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failed = append(s.failed, failedCall{id: id, nextAttemptAt: next, lastErr: lastErr})
	return nil
}

func (s *fakeStore) MarkDeadLettered(_ context.Context, id, lastErr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.deadLettered = append(s.deadLettered, deadLetterCall{id: id, lastErr: lastErr})
	return nil
}

func (s *fakeStore) CountPending(context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.pending), nil
}

func (s *fakeStore) snapshot() ([]string, []failedCall, []deadLetterCall) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.processed...),
		append([]failedCall(nil), s.failed...),
		append([]deadLetterCall(nil), s.deadLettered...)
}

func discard() *slog.Logger { return slog.New(slog.DiscardHandler) }

// TestDrainOnce_MarksSuccessfulRowsProcessed is the happy path.
func TestDrainOnce_MarksSuccessfulRowsProcessed(t *testing.T) {
	store := &fakeStore{pending: []Row{{ID: "a"}, {ID: "b"}}}
	p := New(store, func(context.Context, Row) error { return nil }, WithLogger(discard()))

	p.DrainOnce(context.Background())

	processed, failed, dead := store.snapshot()
	if len(processed) != 2 {
		t.Errorf("processed %v, want both rows", processed)
	}
	if len(failed) != 0 || len(dead) != 0 {
		t.Errorf("unexpected failures: failed=%v dead=%v", failed, dead)
	}
}

// TestDrainOnce_KeepsClaimingUntilTheDueSetIsEmpty covers the loop. A burst
// larger than one batch has to drain now, not one batch per tick — for a
// 500-recipient fan-out that would otherwise be ten ticks before the last
// person hears anything.
func TestDrainOnce_KeepsClaimingUntilTheDueSetIsEmpty(t *testing.T) {
	var pending []Row
	for i := 0; i < 25; i++ {
		pending = append(pending, Row{ID: fmt.Sprintf("row-%d", i)})
	}
	store := &fakeStore{pending: pending}
	p := New(store, func(context.Context, Row) error { return nil },
		WithBatchSize(10), WithLogger(discard()))

	p.DrainOnce(context.Background())

	processed, _, _ := store.snapshot()
	if len(processed) != 25 {
		t.Errorf("processed %d rows in one drain, want all 25 — a burst larger than one batch must not be left for the next tick", len(processed))
	}
}

// TestDeliver_FailureSchedulesExponentialBackoff pins the retry schedule.
// The clock is substituted so the curve is asserted rather than slept
// through.
func TestDeliver_FailureSchedulesExponentialBackoff(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		attemptsSoFar int
		wantDelay     time.Duration
	}{
		{attemptsSoFar: 0, wantDelay: 5 * time.Second},  // 1st failure: base
		{attemptsSoFar: 1, wantDelay: 10 * time.Second}, // 2nd: base x2
		{attemptsSoFar: 2, wantDelay: 20 * time.Second}, // 3rd: base x4
		{attemptsSoFar: 3, wantDelay: 40 * time.Second}, // 4th: base x8
		{attemptsSoFar: 8, wantDelay: 10 * time.Minute}, // capped at maxDelay
	}

	for _, tc := range tests {
		t.Run(fmt.Sprintf("after_%d_attempts", tc.attemptsSoFar), func(t *testing.T) {
			store := &fakeStore{pending: []Row{{ID: "a", Attempts: tc.attemptsSoFar}}}
			p := New(store, func(context.Context, Row) error { return errors.New("transient") },
				WithLogger(discard()), WithClock(func() time.Time { return now }))

			p.DrainOnce(context.Background())

			_, failed, dead := store.snapshot()
			if len(dead) != 0 {
				t.Fatalf("row was dead-lettered before exhausting its retries: %v", dead)
			}
			if len(failed) != 1 {
				t.Fatalf("MarkFailed calls = %d, want 1", len(failed))
			}
			if got := failed[0].nextAttemptAt.Sub(now); got != tc.wantDelay {
				t.Errorf("backoff delay = %v, want %v", got, tc.wantDelay)
			}
		})
	}
}

// TestDeliver_DeadLettersPastTheAttemptCeiling pins giving up. Retrying
// forever turns one permanently-undeliverable row into an unbounded,
// permanent source of load and log noise.
func TestDeliver_DeadLettersPastTheAttemptCeiling(t *testing.T) {
	store := &fakeStore{pending: []Row{{ID: "a", Attempts: DefaultMaxAttempts - 1}}}
	p := New(store, func(context.Context, Row) error { return errors.New("still failing") },
		WithLogger(discard()))

	p.DrainOnce(context.Background())

	_, failed, dead := store.snapshot()
	if len(failed) != 0 {
		t.Errorf("row was scheduled for another retry past the ceiling: %v", failed)
	}
	if len(dead) != 1 || dead[0].id != "a" {
		t.Fatalf("dead-lettered = %v, want exactly row a", dead)
	}
	if dead[0].lastErr == "" {
		t.Error("dead-lettered with no recorded reason — a dead-letter with no error is not evidence of anything")
	}
}

// TestDeliver_PermanentErrorSkipsTheRetryBudget covers the escape hatch: a
// row the process function knows can never succeed (a corrupt payload) must
// not burn ten attempts first.
func TestDeliver_PermanentErrorSkipsTheRetryBudget(t *testing.T) {
	store := &fakeStore{pending: []Row{{ID: "a", Attempts: 0}}}
	p := New(store, func(context.Context, Row) error {
		return fmt.Errorf("%w: payload is corrupt", ErrPermanent)
	}, WithLogger(discard()))

	p.DrainOnce(context.Background())

	_, failed, dead := store.snapshot()
	if len(failed) != 0 {
		t.Errorf("a permanently-undeliverable row was scheduled for retry: %v", failed)
	}
	if len(dead) != 1 {
		t.Fatalf("dead-lettered = %v, want the row abandoned immediately", dead)
	}
}

// TestWake_IsNonBlockingAndCoalesces pins the property that keeps Wake safe
// to call from a business request: it must never block, no matter how many
// times it is called or whether anything is listening.
func TestWake_IsNonBlockingAndCoalesces(t *testing.T) {
	p := New(&fakeStore{}, func(context.Context, Row) error { return nil }, WithLogger(discard()))

	done := make(chan struct{})
	go func() {
		// Nobody is running Run, so the channel fills after one send and
		// every subsequent Wake must drop rather than block.
		for i := 0; i < 10_000; i++ {
			p.Wake()
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Wake blocked — a business request calling it would block with it")
	}
}

// TestRun_WakeTriggersADrain proves the wake path actually drives delivery,
// with the safety-net tick set far too long to be responsible.
func TestRun_WakeTriggersADrain(t *testing.T) {
	store := &fakeStore{pending: []Row{{ID: "a"}}}
	delivered := make(chan string, 4)
	p := New(store, func(_ context.Context, r Row) error {
		delivered <- r.ID
		return nil
	}, WithTickInterval(time.Hour), WithLogger(discard()))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go p.Run(ctx)

	p.Wake()

	select {
	case id := <-delivered:
		if id != "a" {
			t.Errorf("delivered %q, want a", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("nothing was delivered within 5s while the tick was set to an hour — Wake is not driving the drain")
	}
}

// TestRun_TickDrainsWithoutAWake is the safety net: rows that piled up while
// the process was down, or a backoff coming due with no new writes
// happening, must still be delivered without anyone nudging the poller.
func TestRun_TickDrainsWithoutAWake(t *testing.T) {
	store := &fakeStore{pending: []Row{{ID: "a"}}}
	delivered := make(chan string, 4)
	p := New(store, func(_ context.Context, r Row) error {
		delivered <- r.ID
		return nil
	}, WithTickInterval(20*time.Millisecond), WithLogger(discard()))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go p.Run(ctx)

	// Deliberately no Wake call.
	select {
	case <-delivered:
	case <-time.After(5 * time.Second):
		t.Fatal("the safety-net tick never drained a pending row")
	}
}

// TestRun_StopsOnContextCancellation pins the shutdown contract every
// background loop in this process shares.
func TestRun_StopsOnContextCancellation(t *testing.T) {
	p := New(&fakeStore{}, func(context.Context, Row) error { return nil },
		WithTickInterval(10*time.Millisecond), WithLogger(discard()))

	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { p.Run(ctx); close(stopped) }()

	cancel()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after its context was cancelled — SIGTERM would hang")
	}
}

// TestDeliver_RecordsOutcomeEvenWhenTheContextIsAlreadyCancelled is the
// detached-context guarantee. If the process is shutting down mid-batch, a
// delivery that SUCCEEDED must still be recorded, or the row is redelivered
// on the next start and the user gets a duplicate for no reason — the one
// avoidable source of duplicates in an at-least-once system.
func TestDeliver_RecordsOutcomeEvenWhenTheContextIsAlreadyCancelled(t *testing.T) {
	store := &fakeStore{}
	p := New(store, func(context.Context, Row) error { return nil }, WithLogger(discard()))

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	p.deliver(ctx, Row{ID: "a"})

	processed, _, _ := store.snapshot()
	if len(processed) != 1 {
		t.Error("a successful delivery was not recorded because the poller's own context had been cancelled — the row would be delivered a second time on the next start")
	}
}

// TestClaimError_DoesNotSpin guards against a failing store turning
// DrainOnce into a hot loop.
func TestClaimError_DoesNotSpin(t *testing.T) {
	store := &fakeStore{claimErr: errors.New("database unavailable")}
	var calls int
	p := New(store, func(context.Context, Row) error { calls++; return nil }, WithLogger(discard()))

	p.DrainOnce(context.Background())

	if calls != 0 {
		t.Errorf("process was called %d times despite the claim failing", calls)
	}
}
