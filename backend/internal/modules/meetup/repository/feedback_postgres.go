package repository

import (
	"context"
	"fmt"

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
