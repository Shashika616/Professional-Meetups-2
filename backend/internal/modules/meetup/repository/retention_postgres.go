package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// RetentionRepository reduces location data past its keep-by (plan 30B,
// 3.3, D4): cached locations after 30 days, and the exact coordinates of
// meetups that ended more than 180 days ago.
type RetentionRepository interface {
	DeleteStaleUserLocations(ctx context.Context) (int64, error)
	CoarsenOldMeetupCoordinates(ctx context.Context) (int64, error)
	// ActiveMeetup finds the meetup an SOS message mentions (plan 2.2).
	ActiveMeetup(ctx context.Context, userID string, at time.Time) (ActiveMeetup, bool, error)
}

// ActiveMeetup is what an SOS message says about a meetup.
type ActiveMeetup struct {
	Intent        string
	LocationLabel string
	Lat, Lng      float64
}

type postgresRetentionRepository struct{ q *sqlcgen.Queries }

// NewRetentionRepository constructs a RetentionRepository backed by pool.
func NewRetentionRepository(pool *pgxpool.Pool) RetentionRepository {
	return &postgresRetentionRepository{q: sqlcgen.New(pool)}
}

func (r *postgresRetentionRepository) DeleteStaleUserLocations(ctx context.Context) (int64, error) {
	n, err := r.q.DeleteStaleUserLocationCache(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: delete stale locations: %w", err)
	}
	return n, nil
}

func (r *postgresRetentionRepository) CoarsenOldMeetupCoordinates(ctx context.Context) (int64, error) {
	n, err := r.q.CoarsenOldMeetupCoordinates(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: coarsen old meetup coordinates: %w", err)
	}
	return n, nil
}

func (r *postgresRetentionRepository) ActiveMeetup(ctx context.Context, userID string, at time.Time) (ActiveMeetup, bool, error) {
	user, err := parseUUID(userID)
	if err != nil {
		return ActiveMeetup{}, false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	row, err := r.q.GetActiveMeetupForUser(ctx, sqlcgen.GetActiveMeetupForUserParams{AtTime: toTimestamptz(at), UserID: user})
	if errors.Is(err, pgx.ErrNoRows) {
		return ActiveMeetup{}, false, nil
	}
	if err != nil {
		return ActiveMeetup{}, false, fmt.Errorf("repository: find active meetup: %w", err)
	}
	return ActiveMeetup{
		Intent: string(row.Intent), LocationLabel: row.LocationLabel, Lat: row.LocationLat, Lng: row.LocationLng,
	}, true, nil
}
