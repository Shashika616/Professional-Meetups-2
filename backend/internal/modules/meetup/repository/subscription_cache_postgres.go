package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresSubscriptionCacheRepository issues raw parameterized SQL
// directly via pgx, not through this service's usual sqlcgen-generated
// Queries type — the sqlc CLI wasn't available in this environment at
// implementation time (same deviation, same reasoning, as
// services/billing/internal/repository's own doc comment). Functionally
// identical to every other repository in this package (same interface,
// same fake-backed testing pattern in internal/service's tests) — worth
// regenerating through sqlcgen for real once the CLI is available,
// matching every other file in this package.
type postgresSubscriptionCacheRepository struct {
	pool *pgxpool.Pool
}

// NewSubscriptionCacheRepository constructs a SubscriptionCacheRepository
// backed by pool.
func NewSubscriptionCacheRepository(pool *pgxpool.Pool) SubscriptionCacheRepository {
	return &postgresSubscriptionCacheRepository{pool: pool}
}

func (r *postgresSubscriptionCacheRepository) Upsert(ctx context.Context, userID, tier string, entitled bool, occurredAt time.Time) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	// Same idempotent, order-guarded upsert shape as
	// user_display_cache_postgres.go's UpsertUserDisplayCache (ADR-018
	// Decision 2) — ON CONFLICT DO UPDATE handles redelivery safely; the
	// WHERE clause is the ordering guard, applying unconditionally on
	// first insert, otherwise only if this event is strictly newer than
	// what's already stored.
	tag, err := r.pool.Exec(ctx,
		`INSERT INTO subscription_cache (user_id, tier, entitled, updated_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (user_id) DO UPDATE
		 SET tier = excluded.tier, entitled = excluded.entitled, updated_at = excluded.updated_at
		 WHERE excluded.updated_at > subscription_cache.updated_at`,
		parsed, tier, entitled, occurredAt,
	)
	if err != nil {
		return false, fmt.Errorf("repository: upsert subscription cache: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

func (r *postgresSubscriptionCacheRepository) IsEntitled(ctx context.Context, userID string) (bool, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	var entitled bool
	err = r.pool.QueryRow(ctx, `SELECT entitled FROM subscription_cache WHERE user_id = $1`, parsed).Scan(&entitled)
	if errors.Is(err, pgx.ErrNoRows) {
		// Never seen by either event — free/not-entitled is the safe
		// default, not an error.
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("repository: read subscription cache: %w", err)
	}
	return entitled, nil
}
