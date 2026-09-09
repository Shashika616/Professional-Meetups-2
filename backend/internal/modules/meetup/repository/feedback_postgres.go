package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type postgresFeedbackRepository struct {
	q *sqlcgen.Queries
}

// NewFeedbackRepository constructs a FeedbackRepository backed by pool.
func NewFeedbackRepository(pool *pgxpool.Pool) FeedbackRepository {
	return &postgresFeedbackRepository{q: sqlcgen.New(pool)}
}

func (r *postgresFeedbackRepository) Upsert(
	ctx context.Context, meetupID, userID string, happened bool, feltSafe, profileAccurate, wouldMeetAgain *bool, notes *string,
) error {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	if _, err := r.q.UpsertMeetupFeedback(ctx, sqlcgen.UpsertMeetupFeedbackParams{
		MeetupID:        meetup,
		UserID:          user,
		Happened:        happened,
		FeltSafe:        boolPtrOrNull(feltSafe),
		ProfileAccurate: boolPtrOrNull(profileAccurate),
		WouldMeetAgain:  boolPtrOrNull(wouldMeetAgain),
		Notes:           stringPtrOrNull(notes),
	}); err != nil {
		return fmt.Errorf("repository: upsert meetup feedback: %w", err)
	}
	return nil
}

func (r *postgresFeedbackRepository) IDsAwaitingReview(ctx context.Context, userID string, cutoff time.Time) ([]string, error) {
	user, err := parseUUID(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	ids, err := r.q.ListMeetupIDsAwaitingReview(ctx, sqlcgen.ListMeetupIDsAwaitingReviewParams{
		UserID: user,
		Cutoff: pgtype.Timestamptz{Time: cutoff, Valid: true},
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list meetups awaiting review: %w", err)
	}
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		out = append(out, id.String())
	}
	return out, nil
}

func (r *postgresFeedbackRepository) Get(ctx context.Context, meetupID, userID string) (MeetupFeedback, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return MeetupFeedback{}, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return MeetupFeedback{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.GetMeetupFeedback(ctx, sqlcgen.GetMeetupFeedbackParams{MeetupID: meetup, UserID: user})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupFeedback{}, fmt.Errorf("repository: no feedback for meetup %s: %w", meetupID, apperror.ErrNotFound)
		}
		return MeetupFeedback{}, fmt.Errorf("repository: get meetup feedback: %w", err)
	}

	out := MeetupFeedback{Happened: row.Happened}
	if row.OverallScore.Valid {
		score := int(row.OverallScore.Int16)
		out.OverallScore = &score
	}
	if row.Notes.Valid {
		notes := row.Notes.String
		out.Notes = &notes
	}
	if row.ReviewCompletedAt.Valid {
		at := row.ReviewCompletedAt.Time
		out.ReviewCompletedAt = &at
	}
	return out, nil
}
