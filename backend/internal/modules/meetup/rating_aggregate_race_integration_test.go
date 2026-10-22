package meetup_test

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup"
)

// TestSubmitRating_ConcurrentRatersOfOnePersonAgreeOnTheCount is review
// finding N-B4 (tracker #86): two people rating the SAME person at the
// same time, from two different meetups.
//
// Each rater's transaction inserts its own row and then computes that
// person's aggregate. Under READ COMMITTED neither sees the other's
// uncommitted row, so without a lock both compute a count of 1 when the
// truth after both commits is 2 — and both publish that as
// rating-updated. auth's consumer is guarded on OccurredAt, so the later
// event wins and writes the wrong number into the cached columns, where
// it stays until something else happens to that user.
//
// The assertion is therefore on the HIGHEST count published, not on each
// one: the serialised order is not fixed (either rater may go first), but
// whichever commits second must have seen the first. Before
// LockUserRatingAggregate this failed with "highest published count = 1".
//
// Repeated, because a race that fails to reproduce once has proven
// nothing.
func TestSubmitRating_ConcurrentRatersOfOnePersonAgreeOnTheCount(t *testing.T) {
	// One harness for every round: newHarness takes the package's
	// integration-test advisory lock, so a second one inside the loop
	// would block on the first until the test ended. Each round uses
	// fresh users, and the assertions below filter the bus by the rated
	// user, so rounds do not see each other.
	h := newHarness(t)
	ctx := context.Background()

	const rounds = 6
	for round := 0; round < rounds; round++ {

		// One person about to be rated twice, by two hosts who each ran
		// their own meetup with them.
		target := newUserID(t, h)
		hosts := []string{newUserID(t, h), newUserID(t, h)}
		meetups := make([]meetup.Meetup, len(hosts))

		for i, host := range hosts {
			m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
			r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
				MeetupID: m.ID, RequesterID: target, RequesterTrustLevel: 2,
			})
			if err != nil {
				t.Fatalf("round %d: request to join %s: %v", round, m.ID, err)
			}
			if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
				RequestID: r.ID, HostUserID: host, Accept: true,
			}); err != nil {
				t.Fatalf("round %d: accept: %v", round, err)
			}
			// Rating is only eligible once the meetup is over and somebody
			// confirmed it happened.
			backdateMeetup(t, h, m.ID)
			if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
				MeetupID: m.ID, HostUserID: host,
			}); err != nil {
				t.Fatalf("round %d: close: %v", round, err)
			}
			if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
				MeetupID: m.ID, UserID: host, Happened: true,
			}); err != nil {
				t.Fatalf("round %d: feedback: %v", round, err)
			}
			meetups[i] = m
		}

		results := race(t, len(hosts), func(i int) error {
			return h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
				MeetupID:    meetups[i].ID,
				RaterUserID: hosts[i],
				RatedUserID: target,
				Score:       4,
			})
		})
		for i, err := range results {
			if err != nil {
				t.Fatalf("round %d: rater %d: %v", round, i, err)
			}
		}

		// Both ratings landed, so the last word on this user must say 2.
		highest := 0
		published := 0
		for _, raw := range h.bus.payloadsOf(eventbus.TopicRatingUpdated) {
			payload, ok := raw.(eventbus.RatingUpdatedPayload)
			if !ok || payload.UserID != target {
				continue
			}
			published++
			if payload.RatingCount > highest {
				highest = payload.RatingCount
			}
		}
		if published != len(hosts) {
			t.Fatalf("round %d: %d rating-updated events for the rated user, want %d",
				round, published, len(hosts))
		}
		if highest != len(hosts) {
			t.Fatalf("round %d: highest published count = %d, want %d — "+
				"the second rater computed an aggregate that did not include the first",
				round, highest, len(hosts))
		}
	}
}
