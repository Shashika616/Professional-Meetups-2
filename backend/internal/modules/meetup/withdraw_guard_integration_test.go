package meetup_test

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestWithdraw_FullMeetupReopens is review finding N-B3 (tracker #85).
//
// A meetup goes 'full' when its last seat is taken. Nothing ever put it
// back: an accepted participant withdrawing left a meetup that still said
// 'full' with a seat nobody could take — out of browse, refusing new
// requests, and no way for the host to recover it.
func TestWithdraw_FullMeetupReopens(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	// One seat, so the first accept fills the meetup.
	m := guardCreateMeetup(t, h, host, 1)
	r := guardRequestToJoin(t, h, m.ID, requester)
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	full, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: m.ID, UserID: host, ViewerTrustLevel: 4})
	if err != nil {
		t.Fatalf("GetMeetup after accept: %v", err)
	}
	if full.Status != meetup.StatusFull {
		t.Fatalf("status after the last seat was taken = %q, want %q", full.Status, meetup.StatusFull)
	}

	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID: r.ID, RequesterID: requester,
	}); err != nil {
		t.Fatalf("withdraw: %v", err)
	}

	reopened, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: m.ID, UserID: host, ViewerTrustLevel: 4})
	if err != nil {
		t.Fatalf("GetMeetup after withdraw: %v", err)
	}
	if reopened.Status != meetup.StatusOpen {
		t.Errorf("status after the seat was freed = %q, want %q — the seat is lost and "+
			"the meetup has left browse for good", reopened.Status, meetup.StatusOpen)
	}
	if reopened.AcceptedCount != 0 {
		t.Errorf("accepted count = %d, want 0", reopened.AcceptedCount)
	}

	// And the freed seat is genuinely usable again.
	second := newUserID(t, h)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: second, RequesterTrustLevel: 2,
	}); err != nil {
		t.Errorf("request to join the reopened meetup: %v", err)
	}
}

// TestWithdraw_RefusedOnceTheMeetupIsOver is review finding N-B2
// (tracker #84): withdrawing is backing out of something that has not
// happened yet, not editing the record of something that has.
//
// Rating eligibility is keyed on being an accepted participant, so an
// attendee who withdrew after the fact took away every co-attendee's
// ability to rate them while the host kept it through the separate
// withdrawal-rating path. Attend, behave badly, withdraw, and the
// evidence cannot be written.
func TestWithdraw_RefusedOnceTheMeetupIsOver(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	accepted := func(t *testing.T) (meetupID, requestID, host, requester string) {
		t.Helper()
		host = newUserID(t, h)
		requester = newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 3)
		r := guardRequestToJoin(t, h, m.ID, requester)
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		}); err != nil {
			t.Fatalf("accept: %v", err)
		}
		return m.ID, r.ID, host, requester
	}

	t.Run("the window has passed", func(t *testing.T) {
		meetupID, requestID, _, requester := accepted(t)
		backdateMeetup(t, h, meetupID)

		err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: requestID, RequesterID: requester,
		})
		if !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("withdraw after the meetup ended: error = %v, want ErrConflict", err)
		}
	})

	t.Run("the host cancelled it", func(t *testing.T) {
		meetupID, requestID, host, requester := accepted(t)
		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
			MeetupID: meetupID, HostUserID: host, Reason: "something came up",
		}); err != nil {
			t.Fatalf("cancel: %v", err)
		}

		err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: requestID, RequesterID: requester,
		})
		if !isSentinel(err, apperror.ErrConflict) {
			t.Errorf("withdraw from a cancelled meetup: error = %v, want ErrConflict", err)
		}
	})

	t.Run("a live meetup is still withdrawable", func(t *testing.T) {
		_, requestID, _, requester := accepted(t)
		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: requestID, RequesterID: requester,
		}); err != nil {
			t.Errorf("withdraw from a live meetup: %v", err)
		}
	})
}

// TestWithdraw_SchedulesCompletedRecompute is the other half of #84.
// meetups_completed counts accepted requests on completed meetups, so
// leaving 'accepted' invalidates that total; the recompute is enqueued in
// the withdrawal's own transaction.
func TestWithdraw_SchedulesCompletedRecompute(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 3)
	r := guardRequestToJoin(t, h, m.ID, requester)
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// Drain whatever the accept queued, so what is counted below is this
	// withdrawal's own work.
	h.drainCompletedOutbox(t, ctx)
	if before := h.pendingCompletedRows(t, ctx); before != 0 {
		t.Fatalf("pending recompute rows before withdraw = %d, want 0", before)
	}

	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID: r.ID, RequesterID: requester,
	}); err != nil {
		t.Fatalf("withdraw: %v", err)
	}

	if after := h.pendingCompletedRows(t, ctx); after == 0 {
		t.Error("withdrawing an accepted request scheduled no meetups_completed recompute, " +
			"so the cached total keeps counting a seat that was given up")
	}
}
