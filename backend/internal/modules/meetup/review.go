package meetup

import (
	"context"
	"errors"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// SubmitMeetupReview records the whole post-meetup review at once: the
// overall score for the meetup, an optional note, and a score plus traits
// for every other participant.
//
// # WHY THIS EXISTS ALONGSIDE SubmitRating
//
// SubmitRating rates ONE person and is still the right call for the two
// out-of-band paths that have nothing to do with a meetup happening — rating
// a cancelled meetup's host, and rating a requester who withdrew. Neither
// involves an overall score, and neither completes a review.
//
// This call is the review flow: it is the only thing that writes
// review_completed_at, which is what takes the meetup off Home. It is
// deliberately all-or-nothing (see repository.SubmitReview) because ratings
// are immutable — a half-written review could never be finished.
//
// # WHY EVERY PARTICIPANT MUST BE INCLUDED
//
// The flow does not let you Confirm with someone unrated, and the server
// enforces the same thing rather than trusting it. A review that silently
// accepted a subset would leave the meetup marked reviewed while some people
// got nothing, with no way to go back and finish — the immutability again.
// Anyone the viewer has ALREADY rated (an out-of-band rating earlier, say)
// is excluded from the requirement and rejected if resubmitted, since that
// row cannot be written twice.
func (s *service) SubmitMeetupReview(ctx context.Context, req SubmitMeetupReviewRequest) error {
	if req.OverallScore < 1 || req.OverallScore > 5 {
		return fmt.Errorf("meetup: overall score must be between 1 and 5: %w", apperror.ErrInvalidInput)
	}
	if req.Notes != nil && len(*req.Notes) > maxFreeTextReasonLength {
		return fmt.Errorf("meetup: note is too long: %w", apperror.ErrInvalidInput)
	}
	if err := s.requireParticipant(ctx, req.MeetupID, req.RaterID); err != nil {
		return err
	}

	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.RaterID)
	if err != nil {
		return err
	}
	cancelled := m.Status == repository.MeetupStatusCancelled
	switch {
	case cancelled && m.HostUserID == req.RaterID:
		// The host cancelled it; there is nothing for them to review and
		// nobody it would be fair to rate.
		return fmt.Errorf("meetup: the host of a cancelled meetup does not review it: %w", apperror.ErrForbidden)
	case !cancelled && time.Now().Before(m.WindowEnd):
		// Same gate as SubmitMeetupFeedback, and for the same reason: this
		// write asserts the meetup happened. A CANCELLED meetup is over the
		// moment it is cancelled, however far off its window was — that is
		// the case this review exists for.
		return fmt.Errorf("meetup: %s is not over yet: %w", req.MeetupID, apperror.ErrConflict)
	}

	// Already finished? Reviews are made of immutable ratings, so there is
	// nothing a second submission could do except fail partway.
	existing, err := s.feedback.Get(ctx, req.MeetupID, req.RaterID)
	switch {
	case err == nil && existing.ReviewCompletedAt != nil:
		return fmt.Errorf("meetup: %s is already reviewed: %w", req.MeetupID, apperror.ErrConflict)
	case err != nil && !errors.Is(err, apperror.ErrNotFound):
		return err
	}

	outstanding, err := s.ratings.ListRatable(ctx, req.MeetupID, req.RaterID)
	if err != nil {
		return err
	}

	// Index what the flow was allowed to offer. A rated user not in here is
	// either not on this meetup or is the viewer themselves — in both cases
	// the client is sending something it was never shown.
	allowed := make(map[string]bool, len(outstanding))
	required := make(map[string]bool, len(outstanding))
	for _, p := range outstanding {
		allowed[p.UserID] = true
		if !p.AlreadyRated {
			required[p.UserID] = true
		}
	}

	seen := make(map[string]bool, len(req.Participants))
	participants := make([]repository.ReviewParticipant, 0, len(req.Participants))
	for _, p := range req.Participants {
		if !allowed[p.UserID] {
			return fmt.Errorf("meetup: %s is not a ratable participant of %s: %w", p.UserID, req.MeetupID, apperror.ErrInvalidInput)
		}
		if seen[p.UserID] {
			return fmt.Errorf("meetup: %s appears twice in the review: %w", p.UserID, apperror.ErrInvalidInput)
		}
		if !required[p.UserID] {
			return fmt.Errorf("meetup: %s was already rated for this meetup: %w", p.UserID, apperror.ErrConflict)
		}
		if p.Score < 1 || p.Score > 5 {
			return fmt.Errorf("meetup: score for %s must be between 1 and 5: %w", p.UserID, apperror.ErrInvalidInput)
		}
		if err := validateTraits(p.Traits); err != nil {
			return err
		}
		seen[p.UserID] = true
		participants = append(participants, repository.ReviewParticipant{
			UserID: p.UserID,
			Score:  p.Score,
			Traits: p.Traits,
		})
	}

	for userID := range required {
		if !seen[userID] {
			return fmt.Errorf("meetup: every participant must be rated, %s is missing: %w", userID, apperror.ErrInvalidInput)
		}
	}

	return s.ratings.SubmitReview(ctx, repository.ReviewSubmission{
		MeetupID:     req.MeetupID,
		RaterID:      req.RaterID,
		OverallScore: req.OverallScore,
		Notes:        req.Notes,
		Participants: participants,
		Happened:     !cancelled,
	})
}

// GetMeetupReview returns what the viewer themselves submitted — the read
// behind a history card. Only ever the viewer's own scores: what someone
// else rated a participant is not theirs to see.
func (s *service) GetMeetupReview(ctx context.Context, meetupID, viewerID string) (MeetupReview, error) {
	if err := s.requireParticipant(ctx, meetupID, viewerID); err != nil {
		return MeetupReview{}, err
	}

	var out MeetupReview
	feedback, err := s.feedback.Get(ctx, meetupID, viewerID)
	switch {
	case err == nil:
		out.Completed = feedback.ReviewCompletedAt != nil
		out.Notes = feedback.Notes
		if feedback.OverallScore != nil {
			out.OverallScore = *feedback.OverallScore
		}
	case errors.Is(err, apperror.ErrNotFound):
		// Nothing submitted yet — an empty review, not an error. The client
		// asks this before deciding whether to show the flow or the result.
	default:
		return MeetupReview{}, err
	}

	given, err := s.ratings.ListMyRatings(ctx, meetupID, viewerID)
	if err != nil {
		return MeetupReview{}, err
	}
	for _, g := range given {
		out.Participants = append(out.Participants, ReviewedParticipant{
			UserID:          g.UserID,
			FullName:        g.FullName,
			ProfilePhotoURL: g.ProfilePhotoURL,
			Score:           g.Score,
			Traits:          g.Traits,
		})
	}
	return out, nil
}
