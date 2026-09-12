package meetup

import (
	"context"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// ListRatableParticipants returns the viewer's other participants on a
// meetup (host + accepted requesters, excluding self), each flagged with
// whether the viewer already rated them. Not an error if the caller isn't a
// participant — an empty list instead.
//
// The IsParticipant check is load-bearing and is NOT redundant with the
// underlying query: that query only selects rows keyed off the meetup's
// actual host/accepted-requester set and excludes the viewer from the
// result, but it does not check that the VIEWER is a participant. Without
// this check, any authenticated user could enumerate any meetup's
// participant names, photos and trust levels just by guessing a meetup id.
//
// # WHY THE REDACTION HERE IS DELIBERATELY PARTIAL
//
// ListMeetupParticipants (participants.go) withholds id, name, photo AND
// trust level from a viewer below participantIdentityFloor. This one
// withholds only the trust level, on purpose — it is not an oversight and
// should not be "fixed" into parity.
//
// The two endpoints answer different questions for different callers.
// ListMeetupParticipants can be called by anyone who can see the meetup, so
// its redaction stops a stranger scraping a guest list. The viewer here has
// already passed the IsParticipant gate above: they were on this meetup and
// met these people in person. Redacting the name and photo would not
// protect anyone from them — it would just make the screen unusable, since
// the rating UI identifies who you are rating by name and face
// (rating_prompt.dart). There is no way to rate someone you cannot see.
//
// Trust level is different: it is a per-person reputation signal the viewer
// has no need for and did not learn by attending, and the rating UI only
// threads it into a small avatar badge that degrades to "no badge" at zero.
// So it is the one field here worth withholding, and the only one.
func (s *service) ListRatableParticipants(ctx context.Context, req ListRatableParticipantsRequest) ([]RatableParticipant, error) {
	viewerIsParticipant, err := s.ratings.IsParticipant(ctx, req.MeetupID, req.ViewerID)
	if err != nil {
		return nil, err
	}
	if !viewerIsParticipant {
		return []RatableParticipant{}, nil
	}

	participants, err := s.ratings.ListRatable(ctx, req.MeetupID, req.ViewerID)
	if err != nil {
		return nil, err
	}

	eligible, err := s.filterRatable(ctx, req, participants)
	if err != nil {
		return nil, err
	}

	// Applied to the converted slice, not to `eligible` — that is the
	// repo-layer type, and this returns the service-layer one.
	out := ratableParticipantsFromRepo(eligible)
	if req.ViewerTrustLevel < participantIdentityFloor {
		for i := range out {
			out[i].TrustLevel = 0
		}
	}
	return out, nil
}

// filterRatable keeps only the participants SubmitRating would actually
// accept a score for.
//
// # WHY THIS EXISTS
//
// The underlying query answers "who are this meetup's other participants",
// which is not the same question as "who may the viewer rate right now". It
// deliberately never filtered on the meetup's status or window — that is
// what lets an accepted requester rate the host of a CANCELLED meetup, and
// the host rate a requester who withdrew, neither of which involves the
// meetup happening at all.
//
// But nothing then applied the eligibility rules SubmitRating enforces, so
// the list also included every accepted participant of a meetup that is
// still OPEN and scheduled for a future date. The client renders that list
// as a star picker, so a host looking at a meetup days away was shown a
// tappable rating row for someone they had not met yet — and tapping it,
// past an "you won't be able to change this later" confirmation, failed
// with "not yet eligible to rate this participant". A list endpoint that
// disagrees with its own write endpoint can only produce dead controls.
//
// The three branches below are exactly SubmitRating's, in the same order
// and with the same short-circuit: a viewer who confirmed the meetup
// happened may rate everyone, so that case costs one query rather than two
// per candidate.
func (s *service) filterRatable(ctx context.Context, req ListRatableParticipantsRequest, participants []repository.RatableParticipant) ([]repository.RatableParticipant, error) {
	if len(participants) == 0 {
		return participants, nil
	}

	confirmed, err := s.ratings.HasConfirmedHappened(ctx, req.MeetupID, req.ViewerID)
	if err != nil {
		return nil, err
	}
	if confirmed {
		return participants, nil
	}

	// The meetup being OVER is its own eligibility branch, and it has to be:
	// the review flow asks who to rate BEFORE the viewer has confirmed
	// anything — SubmitMeetupReview is what writes happened=true, at the
	// very end. Requiring the confirmation to already exist made the flow
	// open with an empty roster, skip its own people step, and submit a
	// review that rated nobody. Ratings are immutable, so that was
	// unrecoverable.
	//
	// This is exactly the condition SubmitMeetupReview independently
	// enforces (it rejects a review before WindowEnd with ErrConflict), so
	// the list and the write now agree on who is offerable — which is the
	// property the earlier fix was after in the first place.
	//
	// It does NOT reopen the original bug: a meetup that has not finished is
	// still not over, so a future meetup still offers nobody.
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.ViewerID)
	if err != nil {
		return nil, err
	}
	// A cancelled meetup never takes this shortcut, whatever the clock
	// says: nobody met, so the only person offerable is the host, and only
	// to an accepted participant — which is exactly what the eligibility
	// filter below produces.
	if m.Status != repository.MeetupStatusCancelled && !time.Now().Before(m.WindowEnd) {
		return participants, nil
	}

	out := make([]repository.RatableParticipant, 0, len(participants))
	for _, p := range participants {
		// Already-rated rows survive regardless: the score exists, so the
		// client must keep showing it as "RATED" rather than dropping the
		// person off the list entirely.
		if p.AlreadyRated {
			out = append(out, p)
			continue
		}
		cancellation, err := s.ratings.IsEligibleForCancellationRating(ctx, req.MeetupID, req.ViewerID, p.UserID)
		if err != nil {
			return nil, err
		}
		if cancellation {
			out = append(out, p)
			continue
		}
		withdrawal, err := s.ratings.IsEligibleForWithdrawalRating(ctx, req.MeetupID, req.ViewerID, p.UserID)
		if err != nil {
			return nil, err
		}
		if withdrawal {
			out = append(out, p)
		}
	}
	return out, nil
}

// SubmitRating enforces every rating-eligibility guard server-side, never
// trusting the client's UI gating: rater and rated must both be legitimate
// rating targets for this meetup, they must differ, the score must be 1-5,
// and at least one of three independent eligibility branches must hold:
//
//  1. HasConfirmedHappened — the rater confirmed the meetup happened.
//  2. IsEligibleForCancellationRating — the meetup was cancelled and the
//     rater had an accepted request on it; only ever true when the rated
//     user is that meetup's host.
//  3. IsEligibleForWithdrawalRating — the rated user's request was
//     withdrawn and the rater is that meetup's host.
//
// All three branches write into the same rating pool — never a separate one
// per trigger. The DB's own constraints (UNIQUE on the triple, CHECK that
// rater <> rated) are the final backstop should any of these race past.
func (s *service) SubmitRating(ctx context.Context, req SubmitRatingRequest) error {
	if req.Score < 1 || req.Score > 5 {
		return fmt.Errorf("meetup: score must be between 1 and 5: %w", apperror.ErrInvalidInput)
	}
	if req.RaterUserID == req.RatedUserID {
		return fmt.Errorf("meetup: cannot rate yourself: %w", apperror.ErrInvalidInput)
	}

	raterIsParticipant, err := s.ratings.IsParticipant(ctx, req.MeetupID, req.RaterUserID)
	if err != nil {
		return err
	}
	if !raterIsParticipant {
		return fmt.Errorf("meetup: caller is not a participant of meetup %s: %w", req.MeetupID, apperror.ErrForbidden)
	}

	// A withdrawn requester never satisfies IsParticipant by definition (it
	// only covers the host + currently-accepted requesters) — this stands in
	// as the "is the rated user even a legitimate target" gate for that one
	// case, computed once and reused below as an eligibility branch rather
	// than stacked on top of IsParticipant.
	withdrawalEligible, err := s.ratings.IsEligibleForWithdrawalRating(ctx, req.MeetupID, req.RaterUserID, req.RatedUserID)
	if err != nil {
		return err
	}

	ratedIsParticipant, err := s.ratings.IsParticipant(ctx, req.MeetupID, req.RatedUserID)
	if err != nil {
		return err
	}
	if !ratedIsParticipant && !withdrawalEligible {
		return fmt.Errorf("meetup: rated user is not a participant of meetup %s: %w", req.MeetupID, apperror.ErrInvalidInput)
	}

	// Gated on the RATER's confirmed attendance only, for the original
	// branch — a no-show is legitimately ratable by someone who did attend
	// and confirm.
	confirmed, err := s.ratings.HasConfirmedHappened(ctx, req.MeetupID, req.RaterUserID)
	if err != nil {
		return err
	}

	cancellationEligible := false
	if !confirmed {
		cancellationEligible, err = s.ratings.IsEligibleForCancellationRating(ctx, req.MeetupID, req.RaterUserID, req.RatedUserID)
		if err != nil {
			return err
		}
	}

	if !confirmed && !cancellationEligible && !withdrawalEligible {
		return fmt.Errorf("meetup: not yet eligible to rate this participant: %w", apperror.ErrForbidden)
	}

	// Submit records the rating, recomputes the rated user's aggregate in
	// the same transaction, and publishes rating-updated after the commit —
	// the auth module's consumer applies it to auth.users' cached columns.
	return s.ratings.Submit(ctx, req.MeetupID, req.RaterUserID, req.RatedUserID, req.Score)
}
