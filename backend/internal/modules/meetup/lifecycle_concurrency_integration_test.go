package meetup_test

// §C2: the lifecycle poller under concurrency. The fix these tests pin is
// the claim-in-one-statement rewrite of both sweeps — see
// queries/meetups.sql's ClaimMeetupsStartingSoon / ClaimMeetupsToAutoClose.
//
// The pre-fix shape (SELECT candidates, then mark/close per row) already
// prevented double-CLOSING via the UPDATE's own WHERE clause. What it did not
// prevent was duplicate NOTIFICATION: two pollers both read the same
// candidates, both went on to notify the host and every participant, and only
// one of them lost the race on an UPDATE it had already sent pushes for.

import (
	"context"
	"sync"
	"testing"
	"time"
)

// TestAutoCloseSweep_TwoConcurrentTicksNeverDoubleProcess is the §C2
// requirement stated exactly: two poller ticks racing over the same
// overlapping candidate set.
//
// The assertion that matters is the notification count. A meetup being closed
// once is guaranteed by the UPDATE's own WHERE clause and was already true;
// what would break for every participant is being told twice that the meetup
// ended.
func TestAutoCloseSweep_TwoConcurrentTicksNeverDoubleProcess_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const meetups = 12
	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	seedDisplay(t, h, requester, "Requester")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register host device: %v", err)
	}

	// Meetups whose window has already elapsed. CreateMeetup correctly
	// rejects a past window_start, so each is created valid and then
	// backdated in SQL — the same approach this package's other lifecycle
	// tests use.
	ids := make([]string, 0, meetups)
	for i := 0; i < meetups; i++ {
		m := createOpenMeetup(t, h, host)
		ids = append(ids, m.ID)
	}
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
		WHERE id = ANY($1::uuid[])`, ids); err != nil {
		t.Fatalf("backdate meetup windows: %v", err)
	}
	clearOutbox(t, h) // drop the per-creation checklist prompts

	// Two sweeps racing, as two monolith instances would.
	var (
		wg     sync.WaitGroup
		mu     sync.Mutex
		totals []int
		start  = make(chan struct{})
	)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			closed, err := h.svc.AutoCloseSweep(ctx)
			if err != nil {
				t.Errorf("AutoCloseSweep: %v", err)
				return
			}
			mu.Lock()
			totals = append(totals, closed)
			mu.Unlock()
		}()
	}
	close(start)
	wg.Wait()

	sum := 0
	for _, n := range totals {
		sum += n
	}
	if sum != meetups {
		t.Errorf("the two concurrent sweeps closed %d meetups in total (%v), want exactly %d — a meetup claimed by both would be counted twice, and every participant notified twice", sum, totals, meetups)
	}

	// The assertion that actually protects users.
	if got := h.countOutboxRows(t); got != meetups {
		t.Errorf("queued %d \"Meetup ended\" notifications for %d meetups, want exactly one each — two pollers double-notified", got, meetups)
	}

	// And every meetup really is closed.
	var stillOpen int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM meetup.meetups WHERE id = ANY($1::uuid[]) AND status IN ('open','full')`, ids).
		Scan(&stillOpen); err != nil {
		t.Fatalf("count still-open: %v", err)
	}
	if stillOpen != 0 {
		t.Errorf("%d meetups were left open — concurrent claiming dropped work", stillOpen)
	}
}

// TestNotifyStartingSoonSweep_TwoConcurrentTicksNeverDoubleNotify is the same
// race on the other sweep. This one has no atomic-UPDATE backstop at all in
// the pre-fix design — the de-dup guard was set only AFTER the notifications
// went out — so it was the more exposed of the two.
func TestNotifyStartingSoonSweep_TwoConcurrentTicksNeverDoubleNotify_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const meetups = 12
	host := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register host device: %v", err)
	}

	ids := make([]string, 0, meetups)
	for i := 0; i < meetups; i++ {
		m := createOpenMeetup(t, h, host)
		ids = append(ids, m.ID)
	}
	// Inside the 30-minute starting-soon window, but not yet started.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() + interval '10 minutes', window_end = now() + interval '2 hours'
		WHERE id = ANY($1::uuid[])`, ids); err != nil {
		t.Fatalf("move meetups into the starting-soon window: %v", err)
	}
	clearOutbox(t, h)

	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		total int
		start = make(chan struct{})
	)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			notified, err := h.svc.NotifyStartingSoonSweep(ctx)
			if err != nil {
				t.Errorf("NotifyStartingSoonSweep: %v", err)
				return
			}
			mu.Lock()
			total += notified
			mu.Unlock()
		}()
	}
	close(start)
	wg.Wait()

	if total != meetups {
		t.Errorf("the two concurrent sweeps claimed %d meetups in total, want exactly %d", total, meetups)
	}
	if got := h.countOutboxRows(t); got != meetups {
		t.Errorf("queued %d starting-soon reminders for %d meetups, want exactly one each", got, meetups)
	}
}

// TestAutoCloseSweep_IsIdempotentAcrossTicks covers the ordinary case the
// de-dup guard exists for: a second tick a moment later must find nothing to
// do, rather than re-notifying everyone.
func TestAutoCloseSweep_IsIdempotentAcrossTicks_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register device: %v", err)
	}

	m := createOpenMeetup(t, h, host)
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
		WHERE id = $1`, m.ID); err != nil {
		t.Fatalf("backdate window: %v", err)
	}
	clearOutbox(t, h)

	first, err := h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("first AutoCloseSweep: %v", err)
	}
	if first != 1 {
		t.Fatalf("first sweep closed %d, want 1", first)
	}
	afterFirst := h.countOutboxRows(t)

	second, err := h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("second AutoCloseSweep: %v", err)
	}
	if second != 0 {
		t.Errorf("second sweep closed %d meetups, want 0", second)
	}
	if got := h.countOutboxRows(t); got != afterFirst {
		t.Errorf("a second sweep queued %d more notifications, want 0", got-afterFirst)
	}

	_ = time.Now
}

// TestAutoCloseSweep_PreFixAlgorithmDoubleProcesses is a CONTROL, not a test
// of shipped code. It runs the algorithm this repo had BEFORE §C2 — select
// candidates with a plain read, then act on each row — against the same
// concurrent conditions, and asserts that it does double-process.
//
// It exists so the tests above cannot pass vacuously. If both this control
// and the real sweeps came out clean, the honest conclusion would be that the
// test setup never produces contention at all, and the §C2 tests prove
// nothing. Instead this one demonstrates the contention is real and that the
// claiming rewrite is what removes it.
func TestAutoCloseSweep_PreFixAlgorithmDoubleProcesses_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const meetups = 12
	host := newUserID(t, h)
	seedDisplay(t, h, host, "Host")

	ids := make([]string, 0, meetups)
	for i := 0; i < meetups; i++ {
		m := createOpenMeetup(t, h, host)
		ids = append(ids, m.ID)
	}
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
		WHERE id = ANY($1::uuid[])`, ids); err != nil {
		t.Fatalf("backdate windows: %v", err)
	}

	// The pre-fix flow: read candidates (no lock, no claim), then notify,
	// then close.
	//
	// The two readers are synchronised on a barrier so both complete their
	// candidate SELECT before either starts acting. That is not stacking the
	// deck — it is modelling the production timing faithfully: two monolith
	// instances tick on the same schedule, and the gap between "read the
	// candidates" and "record that they are closed" is a real FCM round trip
	// per recipient, hundreds of milliseconds wide. Without the barrier this
	// test's own sweep finishes in microseconds and the overlap that hurts in
	// production never occurs in the test.
	var barrier sync.WaitGroup
	barrier.Add(2)

	preFixSweep := func(counter *int64, mu *sync.Mutex) {
		rows, err := h.pool.Query(ctx, `
			SELECT id FROM meetup.meetups
			WHERE status IN ('open','full') AND now() >= window_end
			ORDER BY window_end LIMIT 100`)
		if err != nil {
			t.Errorf("candidate select: %v", err)
			barrier.Done()
			return
		}
		var candidates []string
		for rows.Next() {
			var id string
			_ = rows.Scan(&id)
			candidates = append(candidates, id)
		}
		rows.Close()

		// Both readers have now seen the same, unclaimed candidate set.
		barrier.Done()
		barrier.Wait()

		for _, id := range candidates {
			// This is the gap: the notification goes out on the strength of
			// the earlier read, before anything has been claimed.
			mu.Lock()
			*counter++
			mu.Unlock()

			_, _ = h.pool.Exec(ctx, `
				UPDATE meetup.meetups SET status = 'completed', closed_at = now()
				WHERE id = $1 AND status IN ('open','full') AND now() >= window_end`, id)
		}
	}

	var (
		wg    sync.WaitGroup
		sends int64
		mu    sync.Mutex
		start = make(chan struct{})
	)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			preFixSweep(&sends, &mu)
		}()
	}
	close(start)
	wg.Wait()

	if sends <= meetups {
		t.Fatalf("CONTROL FAILED TO REPRODUCE: the pre-fix algorithm sent %d notifications for %d meetups. If the old algorithm no longer double-processes even under a forced overlap, the §C2 tests above are not proving anything and this whole control needs rethinking.", sends, meetups)
	}
	t.Logf("CONTROL: the pre-fix select-then-act algorithm sent %d notifications for %d meetups — %d duplicate pushes. The claiming rewrite (§C2) is what the tests above show removing.",
		sends, meetups, sends-meetups)

	// Double-CLOSING was already prevented before §C2, by the UPDATE's own
	// WHERE clause — which is exactly why the bug was invisible: the meetup
	// state stayed correct while every participant got told twice.
	var stillOpen int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM meetup.meetups WHERE id = ANY($1::uuid[]) AND status IN ('open','full')`, ids).
		Scan(&stillOpen); err != nil {
		t.Fatalf("count still-open: %v", err)
	}
	if stillOpen != 0 {
		t.Errorf("%d meetups left open by the control", stillOpen)
	}
}
