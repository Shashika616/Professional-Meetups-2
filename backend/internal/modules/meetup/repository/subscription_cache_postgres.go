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

// postgresSubscriptionCacheRepository goes through the generated queries in
// queries/subscription_cache.sql, like every other repository here.
//
// V-20 (gap tracker #69): it used to be raw pgx ported from the source,
// naming the table without its schema. With one database and a schema per
// module, `subscription_cache` resolved against the default search_path and
// every call failed with "relation does not exist". Nothing called it until
// plan 29B started feeding it from billing, which is why it went unnoticed.
type postgresSubscriptionCacheRepository struct {
	q *sqlcgen.Queries
}

// NewSubscriptionCacheRepository constructs a SubscriptionCacheRepository
// backed by pool.
func NewSubscriptionCacheRepository(pool *pgxpool.Pool) SubscriptionCacheRepository {
	return &postgresSubscriptionCacheRepository{q: sqlcgen.New(pool)}
}

// Upsert is idempotent and order-guarded (see UpsertSubscriptionCache):
// false means a stale event was skipped.
func (r *postgresSubscriptionCacheRepository) Upsert(ctx context.Context, userID, tier string, entitled bool, occurredAt time.Time) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rowsAffected, err := r.q.UpsertSubscriptionCache(ctx, sqlcgen.UpsertSubscriptionCacheParams{
		UserID: parsed, Tier: tier, Entitled: entitled, UpdatedAt: toTimestamptz(occurredAt),
	})
	if err != nil {
		return false, fmt.Errorf("repository: upsert subscription cache: %w", err)
	}
	return rowsAffected > 0, nil
}

func (r *postgresSubscriptionCacheRepository) IsEntitled(ctx context.Context, userID string) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	entitled, err := r.q.IsSubscriptionEntitled(ctx, parsed)
	if errors.Is(err, pgx.ErrNoRows) {
		// Never seen by either event: free/not-entitled is the safe
		// default, not an error.
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("repository: read subscription cache: %w", err)
	}
	return entitled, nil
}
