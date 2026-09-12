package meetup_test

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Taking back a request the host has not answered is a CANCELLATION, not a
// withdrawal: the row goes away, the host is told nothing, the host's
// request list never shows it, and the requester may ask again — as many
// times as they like. Only an ACCEPTED request withdraws.
func TestWithdraw_PendingIsACancellation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 2)

	r, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	clearOutbox(t, h)

	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID: r.ID, RequesterID: f.requester,
	}); err != nil {
		t.Fatalf("cancel pending: %v", err)
	}

	// 1. Nothing queued for anyone.
	var queued int
	if err := h.pool.QueryRow(ctx, `SELECT count(*) FROM meetup.notification_outbox`).Scan(&queued); err != nil {
		t.Fatalf("count outbox: %v", err)
	}
	if queued != 0 {
		t.Errorf("a cancelled pending request queued %d notification(s); a cancellation is nobody's business", queued)
	}

	// 2. The host's list has no trace of it — not pending, not withdrawn.
	reqs, err := h.svc.ListMeetupRequests(ctx, meetup.ListMeetupRequestsRequest{
		MeetupID: f.meetupID, HostUserID: f.host,
	})
	if err != nil {
		t.Fatalf("ListMeetupRequests: %v", err)
	}
	if len(reqs) != 0 {
		t.Errorf("host still sees %d request(s) after a cancellation: %+v", len(reqs), reqs)
	}

	// 3. The requester's own view: no request on this meetup any more.
	m, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: f.meetupID, UserID: f.requester, ViewerTrustLevel: 2})
	if err != nil {
		t.Fatalf("GetMeetup: %v", err)
	}
	if m.MyRequestStatus != nil {
		t.Errorf("requester still has a request status %v after cancelling", *m.MyRequestStatus)
	}

	// 4. They can ask again — and cancel again — without tripping the
	//    (meetup, requester, status) uniqueness a 'withdrawn' row would.
	r2, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("re-request after cancel: %v", err)
	}
	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{RequestID: r2.ID, RequesterID: f.requester}); err != nil {
		t.Fatalf("second cancel: %v", err)
	}
	r3, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("third request: %v", err)
	}

	// 5. Once ACCEPTED, the same call is a withdrawal: the row stays as
	//    'withdrawn' and the host is told.
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r3.ID, HostUserID: f.host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	clearOutbox(t, h)
	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{RequestID: r3.ID, RequesterID: f.requester, Note: "sorry"}); err != nil {
		t.Fatalf("withdraw accepted: %v", err)
	}
	reqs, err = h.svc.ListMeetupRequests(ctx, meetup.ListMeetupRequestsRequest{MeetupID: f.meetupID, HostUserID: f.host})
	if err != nil {
		t.Fatalf("ListMeetupRequests: %v", err)
	}
	if len(reqs) != 1 || reqs[0].Status != meetup.RequestStatusWithdrawn {
		t.Errorf("after withdrawing an accepted request the host should see one withdrawn row, got %+v", reqs)
	}
	assertNotified(t, h, "Request withdrawn", map[string]string{f.host: "the host"})

	// 6. A withdrawn request cannot be "cancelled" or withdrawn again.
	err = h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{RequestID: r3.ID, RequesterID: f.requester})
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("second withdrawal: want ErrConflict, got %v", err)
	}
}
