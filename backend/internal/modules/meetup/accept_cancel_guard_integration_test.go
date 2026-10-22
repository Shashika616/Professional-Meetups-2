package meetup_test

import (
	"context"
	"sync"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// V-2 and V-10, against real Postgres. Both are ordering and predicate bugs
// in SQL, so a fake repository cannot see either of them.

// createMeetupWithCapacity is h.createMeetup with the capacity under test:
// V-2's damage is proportional to how little headroom a meetup has, and the
// shared helper hard-codes 5.
func guardCreateMeetup(t *testing.T, h *harness, host string, capacity int) meetup.Meetup {
	t.Helper()
	windowStart, windowEnd := h.nextWindow()
	m, err := h.svc.CreateMeetup(context.Background(), meetup.CreateMeetupRequest{
		HostUserID:     host,
		HostTrustLevel: 4,
		Intent:         meetup.IntentCoffee,
		WindowStart:    windowStart,
		WindowEnd:      windowEnd,
		LocationLat:    colomboLat,
		LocationLng:    colomboLng,
		LocationLabel:  "Test Cafe",
		Capacity:       capacity,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	return m
}

func guardRequestToJoin(t *testing.T, h *harness, meetupID, requester string) meetup.MeetupRequest {
	t.Helper()
	r, err := h.svc.RequestToJoin(context.Background(), meetup.RequestToJoinRequest{
		MeetupID: meetupID, RequesterID: requester, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	return r
}

func guardMeetupStatus(t *testing.T, h *harness, meetupID string) string {
	t.Helper()
	var status string
	if err := h.pool.QueryRow(context.Background(),
		`SELECT status::text FROM meetup.meetups WHERE id = $1`, meetupID).Scan(&status); err != nil {
		t.Fatalf("read meetup status: %v", err)
	}
	return status
}

func guardAcceptedCount(t *testing.T, h *harness, meetupID string) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM meetup.meetup_requests WHERE meetup_id = $1 AND status = 'accepted'`,
		meetupID).Scan(&n); err != nil {
		t.Fatalf("count accepted: %v", err)
	}
	return n
}

// THE DOUBLE-TAP. A host taps ACCEPT twice and two RPCs land together.
//
// Before the fix: both read the request as pending BEFORE taking the
// meetup's lock, both then ran an UPDATE with no status predicate, and
// `acceptedCount + 1` counted the one seat twice. On a capacity-2 meetup
// with a single real acceptance that was enough to flip the meetup to
// `full` and auto-reject every other pending request, each with a push.
func TestAccept_ConcurrentDoubleAccept_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 2)
	target := guardRequestToJoin(t, h, m.ID, newUserID(t, h))
	bystander := guardRequestToJoin(t, h, m.ID, newUserID(t, h))

	// Both accepts released at once, so the second really does arrive while
	// the first holds the meetup lock.
	var (
		gate sync.WaitGroup
		done sync.WaitGroup
		mu   sync.Mutex
		errs []error
	)
	gate.Add(1)
	for i := 0; i < 2; i++ {
		done.Add(1)
		go func() {
			defer done.Done()
			gate.Wait()
			_, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
				RequestID: target.ID, HostUserID: host, Accept: true,
			})
			mu.Lock()
			defer mu.Unlock()
			errs = append(errs, err)
		}()
	}
	gate.Done()
	done.Wait()

	succeeded, conflicted := 0, 0
	for _, err := range errs {
		switch {
		case err == nil:
			succeeded++
		case isSentinel(err, apperror.ErrConflict):
			conflicted++
		default:
			t.Errorf("unexpected error from a concurrent accept: %v", err)
		}
	}
	if succeeded != 1 || conflicted != 1 {
		t.Errorf("concurrent accepts: %d succeeded and %d conflicted, want exactly 1 and 1", succeeded, conflicted)
	}

	// One seat taken, not two.
	if got := guardAcceptedCount(t, h, m.ID); got != 1 {
		t.Errorf("accepted requests = %d, want 1 — the seat was counted twice", got)
	}
	// So the meetup still has room and stays open.
	if got := guardMeetupStatus(t, h, m.ID); got != "open" {
		t.Errorf("meetup status = %q, want open — it was closed early on a miscounted seat", got)
	}
	// And the other person is still waiting rather than auto-rejected.
	var bystanderStatus string
	if err := h.pool.QueryRow(ctx,
		`SELECT status::text FROM meetup.meetup_requests WHERE id = $1`, bystander.ID).Scan(&bystanderStatus); err != nil {
		t.Fatalf("read the bystander's request: %v", err)
	}
	if bystanderStatus != "pending" {
		t.Errorf("the other pending request is %q, want pending — it was auto-rejected by a phantom seat", bystanderStatus)
	}
}

// An accept must never resurrect a request somebody already resolved.
func TestAccept_AfterResolution_Integration(t *testing.T) {
	ctx := context.Background()

	t.Run("after the host rejected it", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)
		r := guardRequestToJoin(t, h, m.ID, newUserID(t, h))

		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: false,
		}); err != nil {
			t.Fatalf("reject: %v", err)
		}
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		}); !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("accept after reject: error = %v, want ErrConflict", err)
		}
		if got := guardAcceptedCount(t, h, m.ID); got != 0 {
			t.Errorf("accepted requests = %d, want 0 — a rejected request was resurrected", got)
		}
	})

	// Withdrawing takes two different shapes, and the distinction is in
	// WithdrawRequest, not here: a PENDING request is deleted outright
	// (CancelPending — the "cancel my request" feature), while an ACCEPTED
	// one is kept and marked `withdrawn` so the host can be told. Both must
	// refuse a later accept; only the second can report a conflict, because
	// in the first there is genuinely no row left.
	t.Run("after the requester cancelled it while pending", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		requester := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)
		r := guardRequestToJoin(t, h, m.ID, requester)

		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: r.ID, RequesterID: requester,
		}); err != nil {
			t.Fatalf("withdraw: %v", err)
		}
		_, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		})
		if err == nil {
			t.Fatal("a cancelled request was accepted")
		}
		if !isSentinel(err, apperror.ErrNotFound) {
			t.Errorf("accept after cancel: error = %v, want ErrNotFound (the row is deleted, not resolved)", err)
		}
		if got := guardAcceptedCount(t, h, m.ID); got != 0 {
			t.Errorf("accepted requests = %d, want 0", got)
		}
	})

	t.Run("after the requester withdrew an accepted place", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		requester := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)
		r := guardRequestToJoin(t, h, m.ID, requester)

		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		}); err != nil {
			t.Fatalf("accept: %v", err)
		}
		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: r.ID, RequesterID: requester, Note: "sorry",
		}); err != nil {
			t.Fatalf("withdraw: %v", err)
		}

		// THE RESURRECTION CASE. Before the status predicate this re-accepted
		// a withdrawn row and silently put the person back in the meetup.
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		}); !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("accept after withdraw: error = %v, want ErrConflict", err)
		}
		if got := guardAcceptedCount(t, h, m.ID); got != 0 {
			t.Errorf("accepted requests = %d, want 0 — a withdrawn request was resurrected", got)
		}
	})
}

// V-10: a host could cancel a meetup that had already finished, which erased
// it from their public history, re-notified everyone, and opened the
// cancellation-review path on an event nobody was wronged by.
func TestCancelMeetup_StatusGuard_Integration(t *testing.T) {
	ctx := context.Background()

	t.Run("a completed meetup cannot be cancelled", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)
		guardRequestToJoin(t, h, m.ID, newUserID(t, h))

		// Straight to completed, the way the auto-close sweep leaves it.
		if _, err := h.pool.Exec(ctx,
			`UPDATE meetup.meetups SET status = 'completed', closed_at = now() WHERE id = $1`, m.ID); err != nil {
			t.Fatalf("mark completed: %v", err)
		}
		before := h.countOutboxRows(t)

		err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: m.ID, HostUserID: host, Reason: "changed my mind",
		})
		if !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("cancel a completed meetup: error = %v, want ErrConflict", err)
		}
		if got := guardMeetupStatus(t, h, m.ID); got != "completed" {
			t.Errorf("status = %q, want it left at completed", got)
		}
		// Nobody is told about a cancellation that did not happen.
		if after := h.countOutboxRows(t); after != before {
			t.Errorf("outbox rows %d -> %d: a rejected cancel queued notifications", before, after)
		}
	})

	t.Run("an already-cancelled meetup cannot be cancelled again", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)
		guardRequestToJoin(t, h, m.ID, newUserID(t, h))

		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: m.ID, HostUserID: host, Reason: "first time",
		}); err != nil {
			t.Fatalf("the first cancel must work: %v", err)
		}
		before := h.countOutboxRows(t)

		err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: m.ID, HostUserID: host, Reason: "again",
		})
		if !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("second cancel: error = %v, want ErrConflict", err)
		}
		if after := h.countOutboxRows(t); after != before {
			t.Errorf("outbox rows %d -> %d: a second cancel re-notified everyone", before, after)
		}
	})

	t.Run("an open meetup still cancels, and a full one too", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)

		open := guardCreateMeetup(t, h, host, 2)
		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: open.ID, HostUserID: host, Reason: "cannot make it",
		}); err != nil {
			t.Errorf("cancelling an open meetup: %v", err)
		}

		full := guardCreateMeetup(t, h, host, 1)
		if _, err := h.pool.Exec(ctx,
			`UPDATE meetup.meetups SET status = 'full' WHERE id = $1`, full.ID); err != nil {
			t.Fatalf("mark full: %v", err)
		}
		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: full.ID, HostUserID: host, Reason: "cannot make it",
		}); err != nil {
			t.Errorf("cancelling a full meetup: %v", err)
		}
	})

	t.Run("somebody else's meetup is not found, not forbidden", func(t *testing.T) {
		h := newHarness(t)
		host := newUserID(t, h)
		stranger := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 2)

		// A stranger guessing ids must not learn whether the meetup exists.
		err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: m.ID, HostUserID: stranger, Reason: "not mine",
		})
		if err == nil {
			t.Fatal("a stranger cancelled somebody else's meetup")
		}
		if isSentinel(err, apperror.ErrConflict) {
			t.Errorf("error = %v, want not-found or forbidden rather than a conflict (which would confirm the meetup exists and is cancellable)", err)
		}
		if got := guardMeetupStatus(t, h, m.ID); got != "open" {
			t.Errorf("status = %q, want open", got)
		}
	})
}
