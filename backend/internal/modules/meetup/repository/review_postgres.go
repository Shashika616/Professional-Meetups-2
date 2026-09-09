package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// SubmitReview writes an entire post-meetup review as ONE transaction: the
// overall score and note for the meetup, one rating row per participant with
// their traits, and the completion stamp that takes the meetup off Home.
//
// # WHY IT IS NOT A LOOP OVER Submit
//
// Submit commits per rating. Called in a loop, a review of four people is
// four commits, and a failure on the third leaves a half-finished review
// that the user cannot repair — the two ratings that landed are immutable,
// so re-entering the flow would fail on them with ErrConflict and they could
// never reach the completion stamp. The whole review has to land or none of
// it does.
//
// The rating-updated events are published AFTER the commit, one per rated
// user, for the same reason Submit does it: an event is a statement about
// committed state (ADR-001 §4). A publish failure is logged, never returned
// — the ratings are already durable, and auth's cached aggregate is a cache.
func (r *postgresRatingRepository) SubmitReview(ctx context.Context, review ReviewSubmission) error {
	meetup, err := parseUUID(review.MeetupID)
	if err != nil {
		return fmt.Errorf("repository: invalid meetup id %q: %w", review.MeetupID, apperror.ErrInvalidInput)
	}
	rater, err := parseUUID(review.RaterID)
	if err != nil {
		return fmt.Errorf("repository: invalid rater id %q: %w", review.RaterID, apperror.ErrInvalidInput)
	}

	// Parsed up front so a malformed id fails before anything is written,
	// rather than aborting a transaction halfway through.
	rated := make([]uuid.UUID, 0, len(review.Participants))
	for _, p := range review.Participants {
		uid, err := parseUUID(p.UserID)
		if err != nil {
			return fmt.Errorf("repository: invalid rated id %q: %w", p.UserID, apperror.ErrInvalidInput)
		}
		rated = append(rated, uid)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("repository: begin submit review transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	q := r.q.WithTx(tx)

	// The feedback row first: it carries happened=true, which is the
	// eligibility fact the ratings below depend on. Same transaction, so
	// ordering here is about readability rather than visibility.
	if _, err := q.SetMeetupOverallReview(ctx, sqlcgen.SetMeetupOverallReviewParams{
		MeetupID:     meetup,
		UserID:       rater,
		OverallScore: int2OrNull(&review.OverallScore),
		Notes:        stringPtrOrNull(review.Notes),
	}); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgCheckViolation {
			return fmt.Errorf("repository: invalid overall score: %w", apperror.ErrInvalidInput)
		}
		return fmt.Errorf("repository: set meetup overall review: %w", err)
	}

	aggregates := make(map[string]sqlcgen.ComputeUserRatingAggregateRow, len(rated))
	for i, p := range review.Participants {
		if _, err := q.CreateMeetupRating(ctx, sqlcgen.CreateMeetupRatingParams{
			MeetupID:    meetup,
			RaterUserID: rater,
			RatedUserID: rated[i],
			Score:       int16(p.Score),
			// Never nil — traits are optional per participant, but the
			// column is NOT NULL and the INSERT names it.
			Traits: nonNilTraits(p.Traits),
		}); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) {
				switch pgErr.Code {
				case pgUniqueViolation:
					return fmt.Errorf("repository: already rated %s for this meetup: %w", p.UserID, apperror.ErrConflict)
				case pgCheckViolation:
					return fmt.Errorf("repository: invalid rating: %w", apperror.ErrInvalidInput)
				}
			}
			return fmt.Errorf("repository: create meetup rating: %w", err)
		}

		aggregate, err := q.ComputeUserRatingAggregate(ctx, rated[i])
		if err != nil {
			return fmt.Errorf("repository: compute user rating aggregate: %w", err)
		}
		aggregates[p.UserID] = aggregate
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("repository: commit submit review transaction: %w: %w", apperror.ErrInternal, err)
	}

	for userID, aggregate := range aggregates {
		if err := r.bus.Publish(ctx, eventbus.TopicRatingUpdated, eventbus.RatingUpdatedPayload{
			UserID:        userID,
			RatingAverage: numericToFloat64(aggregate.RatingAverage),
			RatingCount:   int(aggregate.RatingCount),
			OccurredAt:    time.Now().UTC(),
		}); err != nil {
			r.logger.Error("publish rating-updated", "rated_user_id", userID, "error", err)
		}
	}
	return nil
}

// ListMyRatings returns what viewerID themselves submitted on meetupID.
func (r *postgresRatingRepository) ListMyRatings(ctx context.Context, meetupID, viewerID string) ([]SubmittedRating, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListMyMeetupRatings(ctx, sqlcgen.ListMyMeetupRatingsParams{
		MeetupID: meetup,
		ViewerID: viewer,
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list my meetup ratings: %w", err)
	}

	out := make([]SubmittedRating, 0, len(rows))
	for _, row := range rows {
		out = append(out, SubmittedRating{
			UserID:          row.RatedUserID.String(),
			FullName:        row.FullName,
			ProfilePhotoURL: row.ProfilePhotoUrl.String,
			Score:           int(row.Score),
			Traits:          row.Traits,
		})
	}
	return out, nil
}

// nonNilTraits maps "no traits chosen" onto an empty array rather than SQL
// NULL, which the NOT NULL column would reject.
func nonNilTraits(traits []string) []string {
	if traits == nil {
		return []string{}
	}
	return traits
}
