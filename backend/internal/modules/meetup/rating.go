package meetup

import (
	"context"
	"fmt"

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
	return ratableParticipantsFromRepo(participants), nil
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
