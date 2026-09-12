package meetup_test

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The cancellation review: a host cancels a meetup that has accepted
// participants, and each of those participants is asked — through the
// ordinary review flow, right away — how that went, rating the host and
// nobody else. The host is never asked. Once reviewed, the meetup leaves
// the participant's active list like any other.
func TestCancelledMeetup_ParticipantReviewsHost_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h) // host, accepted, pending, outsider

	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID: f.meetupID, HostUserID: f.host, Reason: "Came down with something, so sorry.",
	}); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	// 1. The accepted participant sees it on their active list, flagged
	//    cancelled; the host and the merely-pending requester do not.
	active, err := h.svc.ListActiveMeetups(ctx, f.accepted)
	if err != nil {
		t.Fatalf("ListActiveMeetups(accepted): %v", err)
	}
	var found *meetup.Meetup
	for i := range active {
		if active[i].ID == f.meetupID {
			found = &active[i]
		}
	}
	if found == nil {
		t.Fatalf("accepted participant's active list does not carry the cancelled meetup: %+v", active)
	}
	if found.Status != meetup.StatusCancelled {
		t.Errorf("status = %v, want cancelled", found.Status)
	}
	if found.CancellationReason == nil || *found.CancellationReason != "Came down with something, so sorry." {
		t.Errorf("cancellation reason not carried: %v", found.CancellationReason)
	}
	for _, viewer := range []struct{ role, id string }{{"host", f.host}, {"pending", f.pending}} {
		list, err := h.svc.ListActiveMeetups(ctx, viewer.id)
		if err != nil {
			t.Fatalf("ListActiveMeetups(%s): %v", viewer.role, err)
		}
		for _, m := range list {
			if m.ID == f.meetupID {
				t.Errorf("%s should not be asked to review a cancelled meetup, but it is on their active list", viewer.role)
			}
		}
	}

	// 2. The only person offerable to rate is the host.
	ratable, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: f.meetupID, ViewerID: f.accepted, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListRatableParticipants: %v", err)
	}
	if len(ratable) != 1 || ratable[0].UserID != f.host {
		t.Fatalf("ratable = %+v, want exactly the host", ratable)
	}

	// 3. The host cannot review their own cancellation.
	err = h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5,
	})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("host review: want ErrForbidden, got %v", err)
	}

	// 4. The participant reviews immediately — the window is still in the
	//    future, which would refuse an ordinary review.
	note := "Cancelled the morning of. At least they said why."
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.accepted, OverallScore: 2, Notes: &note,
		Participants: []meetup.ReviewParticipantInput{{UserID: f.host, Score: 2}},
	}); err != nil {
		t.Fatalf("participant review of a cancelled meetup: %v", err)
	}

	// 5. It records that the meetup did NOT happen, and leaves Home.
	var happened bool
	if err := h.pool.QueryRow(ctx,
		`SELECT happened FROM meetup.meetup_feedback WHERE meetup_id = $1 AND user_id = $2`,
		f.meetupID, f.accepted,
	).Scan(&happened); err != nil {
		t.Fatalf("read feedback: %v", err)
	}
	if happened {
		t.Error("a cancelled meetup's review recorded happened=true")
	}
	active, err = h.svc.ListActiveMeetups(ctx, f.accepted)
	if err != nil {
		t.Fatalf("ListActiveMeetups after review: %v", err)
	}
	for _, m := range active {
		if m.ID == f.meetupID {
			t.Error("reviewed cancelled meetup still on the active list")
		}
	}

	// 6. An ordinary future meetup is still refused — the relaxation is
	//    for cancellation only.
	m2 := h.createMeetup(t, f.host, meetup.IntentCoffee, colomboLat, colomboLng)
	err = h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: m2.ID, RaterID: f.host, OverallScore: 5,
	})
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("future meetup review: want ErrConflict (not over yet), got %v", err)
	}
}
