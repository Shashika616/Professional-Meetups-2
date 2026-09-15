package meetup_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
)

// TestScheduleConflict_ConcurrentCallsSerialize is the race the rule has to
// survive (docs/plans/19-schedule-conflict-race-fix.md): two requests from
// the same person arriving together. A check that is not held under a lock
// lets both read "no conflict" before either writes, and both succeed. Two
// goroutines are released on one barrier against the real pool; exactly
// one may win. Repeated, because a race that fails to reproduce once has
// proven nothing.
func TestScheduleConflict_ConcurrentCallsSerialize(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const rounds = 6
	for round := 0; round < rounds; round++ {
		t.Run("host twice at once", func(t *testing.T) {
			host := newUserID(t, h)
			start := time.Now().Add(time.Duration(2+round*3) * time.Hour)
			results := race(t, 2, func(i int) error {
				_, err := h.createMeetupAt(t, host, start, start.Add(time.Hour))
				return err
			})
			assertExactlyOneWins(t, results)
		})

		t.Run("request two overlapping meetups at once", func(t *testing.T) {
			hostA, hostB := newUserID(t, h), newUserID(t, h)
			requester := newUserID(t, h)
			start := time.Now().Add(time.Duration(30+round*3) * time.Hour)
			a, err := h.createMeetupAt(t, hostA, start, start.Add(time.Hour))
			if err != nil {
				t.Fatalf("meetup A: %v", err)
			}
			b, err := h.createMeetupAt(t, hostB, start.Add(30*time.Minute), start.Add(90*time.Minute))
			if err != nil {
				t.Fatalf("meetup B: %v", err)
			}
			targets := []string{a.ID, b.ID}
			results := race(t, 2, func(i int) error {
				_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
					MeetupID: targets[i], RequesterID: requester, RequesterTrustLevel: 4,
				})
				return err
			})
			assertExactlyOneWins(t, results)
		})
	}
}

// race runs fn n times concurrently, all released together, and returns
// each call's error in order.
func race(t *testing.T, n int, fn func(i int) error) []error {
	t.Helper()
	results := make([]error, n)
	var (
		ready sync.WaitGroup
		done  sync.WaitGroup
		go_   = make(chan struct{})
	)
	for i := 0; i < n; i++ {
		ready.Add(1)
		done.Add(1)
		go func(i int) {
			defer done.Done()
			ready.Done()
			<-go_
			results[i] = fn(i)
		}(i)
	}
	ready.Wait()
	close(go_)
	done.Wait()
	return results
}

func assertExactlyOneWins(t *testing.T, results []error) {
	t.Helper()
	wins := 0
	for _, err := range results {
		if err == nil {
			wins++
			continue
		}
		var conflict *meetup.ScheduleConflictError
		if !errors.As(err, &conflict) {
			t.Errorf("unexpected error: %v", err)
		}
	}
	if wins != 1 {
		t.Errorf("%d of %d concurrent calls succeeded, want exactly 1 (results: %v)", wins, len(results), results)
	}
}
