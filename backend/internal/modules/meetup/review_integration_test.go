package meetup_test

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// reviewFixture: a host, two accepted participants, and a meetup whose
// window has already ended.
type reviewFixture struct {
	host     string
	guestOne string
	guestTwo string
	meetupID string
}

func newReviewFixture(t *testing.T, h *harness) reviewFixture {
	t.Helper()
	ctx := context.Background()
	f := reviewFixture{
		host:     newUserID(t, h),
		guestOne: newUserID(t, h),
		guestTwo: newUserID(t, h),
	}
	seedDisplay(t, h, f.host, "Host Person")
	seedDisplay(t, h, f.guestOne, "Guest One")
	seedDisplay(t, h, f.guestTwo, "Guest Two")

	m := h.createMeetup(t, f.host, meetup.IntentCoffee, colomboLat, colomboLng)
	f.meetupID = m.ID
	for _, guest := range []string{f.guestOne, f.guestTwo} {
		r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2})
		if err != nil {
			t.Fatalf("RequestToJoin: %v", err)
		}
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: f.host, Accept: true}); err != nil {
			t.Fatalf("accept: %v", err)
		}
	}
	backdateMeetup(t, h, m.ID)
	return f
}

// A finished meetup keeps asking to be reviewed. This is the whole point of
// the feature: the prompt used to appear the instant the window passed and
// disappear on the next refresh, because the active list dropped anything
// already over.
func TestActiveMeetups_KeepsAFinishedMeetupUntilItIsReviewed_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newReviewFixture(t, h)

	for _, viewer := range []struct {
		id   string
		role string
	}{{f.host, "the host"}, {f.guestOne, "an accepted participant"}} {
		active, err := h.svc.ListActiveMeetups(ctx, viewer.id)
		if err != nil {
			t.Fatalf("ListActiveMeetups(%s): %v", viewer.role, err)
		}
		if len(active) != 1 || active[0].ID != f.meetupID {
			t.Errorf("%s saw %d meetup(s) after the window ended, want the one awaiting review", viewer.role, len(active))
		}
	}

	// Reviewing it is what takes it off Home — and only for the person who
	// reviewed it.
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5,
		Participants: []meetup.ReviewParticipantInput{
			{UserID: f.guestOne, Score: 5, Traits: []string{"cheerful"}},
			{UserID: f.guestTwo, Score: 4},
		},
	}); err != nil {
		t.Fatalf("SubmitMeetupReview: %v", err)
	}

	active, err := h.svc.ListActiveMeetups(ctx, f.host)
	if err != nil {
		t.Fatalf("ListActiveMeetups: %v", err)
	}
	if len(active) != 0 {
		t.Errorf("host still saw %d meetup(s) after reviewing, want none", len(active))
	}

	active, err = h.svc.ListActiveMeetups(ctx, f.guestOne)
	if err != nil {
		t.Fatalf("ListActiveMeetups(guest): %v", err)
	}
	if len(active) != 1 {
		t.Errorf("a guest who has not reviewed saw %d meetup(s), want theirs still waiting", len(active))
	}
}

// A live meetup outranks one merely waiting to be reviewed, so the first
// card in the Home carousel is always what is next.
func TestActiveMeetups_LiveMeetupsSortAheadOfReviews_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newReviewFixture(t, h)

	upcoming := h.createMeetup(t, f.host, meetup.IntentNetworking, colomboLat, colomboLng)

	active, err := h.svc.ListActiveMeetups(ctx, f.host)
	if err != nil {
		t.Fatalf("ListActiveMeetups: %v", err)
	}
	if len(active) != 2 {
		t.Fatalf("saw %d meetup(s), want the live one and the one awaiting review", len(active))
	}
	if active[0].ID != upcoming.ID {
		t.Errorf("first card is %s, want the live meetup %s", active[0].ID, upcoming.ID)
	}
	if active[1].ID != f.meetupID {
		t.Errorf("second card is %s, want the meetup awaiting review %s", active[1].ID, f.meetupID)
	}
}

func TestSubmitMeetupReview_Validation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	t.Run("every participant must be rated", func(t *testing.T) {
		f := newReviewFixture(t, h)
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: f.meetupID, RaterID: f.host, OverallScore: 4,
			Participants: []meetup.ReviewParticipantInput{{UserID: f.guestOne, Score: 5}},
		})
		if !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("partial review: error = %v, want ErrInvalidInput", err)
		}
		// And it wrote nothing — the meetup is still awaiting review.
		active, _ := h.svc.ListActiveMeetups(ctx, f.host)
		if len(active) != 1 {
			t.Errorf("a rejected review left the meetup off Home; it must be retryable")
		}
	})

	t.Run("an unknown trait is rejected", func(t *testing.T) {
		f := newReviewFixture(t, h)
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: f.meetupID, RaterID: f.host, OverallScore: 4,
			Participants: []meetup.ReviewParticipantInput{
				{UserID: f.guestOne, Score: 5, Traits: []string{"rude"}},
				{UserID: f.guestTwo, Score: 5},
			},
		})
		if !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("trait outside the vocabulary: error = %v, want ErrInvalidInput", err)
		}
	})

	t.Run("exactly the cap, mixing positive and negative traits, is accepted", func(t *testing.T) {
		f := newReviewFixture(t, h)
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: f.meetupID, RaterID: f.host, OverallScore: 4,
			Participants: []meetup.ReviewParticipantInput{
				{UserID: f.guestOne, Score: 2, Traits: []string{"cheerful", "arrived_late", "distracted", "left_early"}},
				{UserID: f.guestTwo, Score: 5},
			},
		})
		if err != nil {
			t.Fatalf("four traits across both lists: error = %v, want nil", err)
		}
	})

	t.Run("more traits than the cap is rejected", func(t *testing.T) {
		f := newReviewFixture(t, h)
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: f.meetupID, RaterID: f.host, OverallScore: 4,
			Participants: []meetup.ReviewParticipantInput{
				{UserID: f.guestOne, Score: 5, Traits: []string{"cheerful", "funny", "thoughtful", "inspiring", "welcoming"}},
				{UserID: f.guestTwo, Score: 5},
			},
		})
		if !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("over the trait cap: error = %v, want ErrInvalidInput", err)
		}
	})

	t.Run("a meetup that is not over yet cannot be reviewed", func(t *testing.T) {
		host := newUserID(t, h)
		guest := newUserID(t, h)
		m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
		r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2})
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
			t.Fatalf("accept: %v", err)
		}
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: m.ID, RaterID: host, OverallScore: 5,
			Participants: []meetup.ReviewParticipantInput{{UserID: guest, Score: 5}},
		})
		if !errors.Is(err, apperror.ErrConflict) {
			t.Errorf("review before the meetup ended: error = %v, want ErrConflict", err)
		}
	})

	t.Run("a non-participant cannot review", func(t *testing.T) {
		f := newReviewFixture(t, h)
		err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
			MeetupID: f.meetupID, RaterID: newUserID(t, h), OverallScore: 5,
		})
		if !errors.Is(err, apperror.ErrForbidden) {
			t.Errorf("outsider review: error = %v, want ErrForbidden", err)
		}
	})

	t.Run("reviewing twice is refused", func(t *testing.T) {
		f := newReviewFixture(t, h)
		submit := func() error {
			return h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
				MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5,
				Participants: []meetup.ReviewParticipantInput{
					{UserID: f.guestOne, Score: 5},
					{UserID: f.guestTwo, Score: 5},
				},
			})
		}
		if err := submit(); err != nil {
			t.Fatalf("first review: %v", err)
		}
		if err := submit(); !errors.Is(err, apperror.ErrConflict) {
			t.Errorf("second review: error = %v, want ErrConflict", err)
		}
	})
}

// A failed review must leave nothing behind — ratings are immutable, so a
// half-applied review could never be finished on a retry.
func TestSubmitMeetupReview_IsAtomic_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newReviewFixture(t, h)

	// guestTwo's score is out of range, and comes second — so guestOne's row
	// would already be written if this were not one transaction.
	err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5,
		Participants: []meetup.ReviewParticipantInput{
			{UserID: f.guestOne, Score: 5},
			{UserID: f.guestTwo, Score: 9},
		},
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("out-of-range score: error = %v, want ErrInvalidInput", err)
	}

	review, err := h.svc.GetMeetupReview(ctx, f.meetupID, f.host)
	if err != nil {
		t.Fatalf("GetMeetupReview: %v", err)
	}
	if review.Completed || len(review.Participants) != 0 {
		t.Errorf("a rejected review left %d rating(s) behind (completed=%v)", len(review.Participants), review.Completed)
	}

	// And the corrected submission goes through, which it could not if the
	// first attempt had written guestOne's immutable row.
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5,
		Participants: []meetup.ReviewParticipantInput{
			{UserID: f.guestOne, Score: 5},
			{UserID: f.guestTwo, Score: 4},
		},
	}); err != nil {
		t.Fatalf("retry after a rejected review: %v", err)
	}
}

// The history view: what I gave, and never what anyone else gave.
func TestGetMeetupReview_ReturnsOnlyTheViewersOwnScores_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newReviewFixture(t, h)

	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 4,
		Notes: strPtr("Good turnout."),
		Participants: []meetup.ReviewParticipantInput{
			{UserID: f.guestOne, Score: 5, Traits: []string{"cheerful", "insightful"}},
			{UserID: f.guestTwo, Score: 3},
		},
	}); err != nil {
		t.Fatalf("host review: %v", err)
	}
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.guestOne, OverallScore: 2,
		Participants: []meetup.ReviewParticipantInput{
			{UserID: f.host, Score: 1},
			{UserID: f.guestTwo, Score: 1},
		},
	}); err != nil {
		t.Fatalf("guest review: %v", err)
	}

	review, err := h.svc.GetMeetupReview(ctx, f.meetupID, f.host)
	if err != nil {
		t.Fatalf("GetMeetupReview: %v", err)
	}
	if !review.Completed || review.OverallScore != 4 {
		t.Errorf("review = %+v, want completed with overall 4", review)
	}
	if review.Notes == nil || *review.Notes != "Good turnout." {
		t.Errorf("notes = %v, want the host's own note", review.Notes)
	}
	if len(review.Participants) != 2 {
		t.Fatalf("saw %d participant(s), want 2", len(review.Participants))
	}
	byUser := map[string]meetup.ReviewedParticipant{}
	for _, p := range review.Participants {
		byUser[p.UserID] = p
	}
	// The host gave guestTwo a 3; guestOne gave them a 1. Reading back the
	// host's review must never surface the guest's score.
	if got := byUser[f.guestTwo].Score; got != 3 {
		t.Errorf("guestTwo score = %d, want the host's own 3 — not another rater's", got)
	}
	if got := byUser[f.guestOne].Traits; len(got) != 2 {
		t.Errorf("guestOne traits = %v, want the two the host chose", got)
	}
}

func strPtr(s string) *string { return &s }

// The review flow asks who to rate BEFORE the user has confirmed anything —
// SubmitMeetupReview is what writes happened=true, at the very end. So
// listing must not require that confirmation to already exist, or the flow
// opens with an empty roster.
//
// The visible symptom was the page closing on the overall step instead of
// advancing to the people step. The worse, invisible half: with nobody to
// rate, Confirm submits an EMPTY review and stamps the meetup reviewed —
// and since ratings are immutable, those people can never be rated again.
func TestListRatableParticipants_OffersParticipantsOnceTheMeetupIsOver_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newReviewFixture(t, h)

	got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: f.meetupID, ViewerID: f.host, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListRatableParticipants: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("host saw %d participant(s) to rate on a finished meetup, want 2 — the review flow has nobody to show", len(got))
	}

	// And the guests see the host plus each other.
	got, err = h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: f.meetupID, ViewerID: f.guestOne, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListRatableParticipants(guest): %v", err)
	}
	if len(got) != 2 {
		t.Errorf("a guest saw %d participant(s), want 2 (the host and the other guest)", len(got))
	}
}

// The fix must not undo the earlier one: a meetup that has NOT happened yet
// still offers nobody, so the star picker cannot appear before the event.
func TestListRatableParticipants_StillOffersNobodyBeforeTheMeetup_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	// Deliberately NOT backdated — this meetup is still in the future.

	got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: m.ID, ViewerID: host, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListRatableParticipants: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("saw %+v before the meetup happened, want none", got)
	}
}
