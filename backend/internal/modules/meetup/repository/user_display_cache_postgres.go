package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type postgresUserDisplayCacheRepository struct {
	q *sqlcgen.Queries
}

// NewUserDisplayCacheRepository constructs a UserDisplayCacheRepository
// backed by pool.
func NewUserDisplayCacheRepository(pool *pgxpool.Pool) UserDisplayCacheRepository {
	return &postgresUserDisplayCacheRepository{q: sqlcgen.New(pool)}
}

func (r *postgresUserDisplayCacheRepository) Upsert(
	ctx context.Context, userID, fullName, profilePhotoURL string, trustLevel int, occurredAt time.Time,
) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rowsAffected, err := r.q.UpsertUserDisplayCache(ctx, sqlcgen.UpsertUserDisplayCacheParams{
		UserID:          parsed,
		FullName:        fullName,
		ProfilePhotoUrl: textOrNull(profilePhotoURL),
		TrustLevel:      int16(trustLevel),
		UpdatedAt:       toTimestamptz(occurredAt),
	})
	if err != nil {
		return false, fmt.Errorf("repository: upsert user display cache: %w", err)
	}
	return rowsAffected > 0, nil
}
