package meetup_test

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The four sequences review finding N-B1 (tracker #79) named, each of
// which the old UNIQUE (meetup_id, requester_id, status) broke.
//
// That key put the STATUS inside the uniqueness, which permits two LIVE
// rows in different states and forbids two DEAD rows in the same one —
// both wrong, and both reachable from the app. A requester rejected once
// and re-requesting held a 'rejected' row and a 'pending' row at the same
// time, and from there the host could neither reject nor fill the last
// seat: every write collided with the stale rejected row and surfaced as
// a 500.
//
// Migration 0019 replaces it with a partial unique index over the live
// states only. Decision D1 — a rejected user may not ask again, a
// withdrawn user may — is enforced by the conditional INSERT, because an
// index covering 'rejected' would reintroduce exactly the collision.

// Sequence 1: the host rejects after a re-request.
func TestRequestUniqueness_RejectAfterReRequest(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 3)
	first := guardRequestToJoin(t, h, m.ID, requester)
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: first.ID, HostUserID: host, Accept: false,
	}); err != nil {
		t.Fatalf("first reject: %v", err)
	}

	// D1: having been told no, they cannot ask again. Under the old key
	// this insert succeeded and set the trap for everything below.
	_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Fatalf("re-request after a rejection: error = %v, want ErrConflict", err)
	}

	// And the host's earlier rejection is still the final word: a second
	// reject of the resolved request is a conflict, never a 500.
	_, err = h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: first.ID, HostUserID: host, Accept: false,
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("re-rejecting a resolved request: error = %v, want ErrConflict", err)
	}
}

// Sequence 2: the final seat is accepted while a previously rejected
// person has a pending row. This is the griefing path — the host could
// not fill the last seat at all, because auto-rejecting the other pending
// requests collided with a stale 'rejected' row and rolled the accept
// back.
//
// With D1 in force the rejected user can no longer hold a second pending
// row, so the sequence is built the only way it still can be: one
// rejected requester, and two others whose pending rows must be
// auto-rejected when the seat goes.
func TestRequestUniqueness_FinalSeatAcceptWithARejectedRequesterPresent(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 1) // one seat
	rejected := newUserID(t, h)
	winner := newUserID(t, h)
	alsoPending := newUserID(t, h)

	first := guardRequestToJoin(t, h, m.ID, rejected)
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: first.ID, HostUserID: host, Accept: false,
	}); err != nil {
		t.Fatalf("reject: %v", err)
	}

	winnerReq := guardRequestToJoin(t, h, m.ID, winner)
	guardRequestToJoin(t, h, m.ID, alsoPending)

	// The accept that used to 500.
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: winnerReq.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accepting the final seat with a rejected requester present: %v", err)
	}

	got, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{
		MeetupID: m.ID, UserID: host, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("GetMeetup: %v", err)
	}
	if got.Status != meetup.StatusFull {
		t.Errorf("status after the last seat went = %q, want %q", got.Status, meetup.StatusFull)
	}
	if got.AcceptedCount != 1 {
		t.Errorf("accepted count = %d, want 1", got.AcceptedCount)
	}
}

// Sequence 3: a second acceptance is withdrawn. Under the old key the
// second withdrawal collided with the first 'withdrawn' row.
func TestRequestUniqueness_WithdrawASecondAcceptance(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 3)

	acceptAndWithdraw := func(t *testing.T, label string) {
		t.Helper()
		r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
			MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
		})
		if err != nil {
			t.Fatalf("%s request: %v", label, err)
		}
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
			RequestID: r.ID, HostUserID: host, Accept: true,
		}); err != nil {
			t.Fatalf("%s accept: %v", label, err)
		}
		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
			RequestID: r.ID, RequesterID: requester,
		}); err != nil {
			t.Fatalf("%s withdraw: %v", label, err)
		}
	}

	acceptAndWithdraw(t, "first")
	// The one that used to collide. Withdrawing is not misconduct, so D1
	// lets them come back — and the second withdrawal must work too.
	acceptAndWithdraw(t, "second")
}

// Sequence 4: an accepted user asking again. The partial index is what
// refuses this, and it has to refuse at the database rather than in Go,
// because two concurrent inserts can both pass an application check.
func TestRequestUniqueness_AcceptedUserCannotOpenASecondRequest(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := guardCreateMeetup(t, h, host, 5)
	r := guardRequestToJoin(t, h, m.ID, requester)
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("second request while accepted: error = %v, want ErrConflict", err)
	}

	// A pending requester likewise cannot stack a second live row.
	other := newUserID(t, h)
	guardRequestToJoin(t, h, m.ID, other)
	_, err = h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: other, RequesterTrustLevel: 2,
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("second request while pending: error = %v, want ErrConflict", err)
	}
}

// Concurrency: two requests from one person arriving together. Only the
// index can decide this — both goroutines pass any application-level
// "have you already asked?" check before either inserts.
func TestRequestUniqueness_ConcurrentFirstRequestsSerialize(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const rounds = 5
	for round := 0; round < rounds; round++ {
		host := newUserID(t, h)
		requester := newUserID(t, h)
		m := guardCreateMeetup(t, h, host, 5)

		results := race(t, 2, func(int) error {
			_, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
				MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
			})
			return err
		})

		wins := 0
		for _, err := range results {
			switch {
			case err == nil:
				wins++
			case isSentinel(err, apperror.ErrConflict):
			default:
				t.Errorf("round %d: unexpected error: %v", round, err)
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d of 2 concurrent first requests succeeded, want exactly 1", round, wins)
		}
	}
}
