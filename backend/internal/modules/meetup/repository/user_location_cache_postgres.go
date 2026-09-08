package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type postgresUserLocationCacheRepository struct {
	q *sqlcgen.Queries
}

// NewUserLocationCacheRepository constructs a UserLocationCacheRepository
// backed by pool.
func NewUserLocationCacheRepository(pool *pgxpool.Pool) UserLocationCacheRepository {
	return &postgresUserLocationCacheRepository{q: sqlcgen.New(pool)}
}

func (r *postgresUserLocationCacheRepository) Upsert(
	ctx context.Context, userID string, lat, lng float64, occurredAt time.Time,
) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rowsAffected, err := r.q.UpsertUserLocationCache(ctx, sqlcgen.UpsertUserLocationCacheParams{
		UserID:    parsed,
		Lat:       lat,
		Lng:       lng,
		UpdatedAt: toTimestamptz(occurredAt),
	})
	if err != nil {
		return false, fmt.Errorf("repository: upsert user location cache: %w", err)
	}
	return rowsAffected > 0, nil
}

func (r *postgresUserLocationCacheRepository) ListWithinRadius(
	ctx context.Context, centerLat, centerLng float64, notBefore time.Time,
) ([]UserLocation, error) {
	rows, err := r.q.ListUserLocationCacheWithinRadius(ctx, sqlcgen.ListUserLocationCacheWithinRadiusParams{
		NotBefore: toTimestamptz(notBefore),
		CenterLat: centerLat,
		CenterLng: centerLng,
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list user location cache within radius: %w", err)
	}

	locations := make([]UserLocation, 0, len(rows))
	for _, row := range rows {
		locations = append(locations, UserLocation{
			UserID:    row.UserID.String(),
			Lat:       row.Lat,
			Lng:       row.Lng,
			UpdatedAt: timestamptzOrZero(row.UpdatedAt),
		})
	}
	return locations, nil
}
