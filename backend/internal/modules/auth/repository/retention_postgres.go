package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
)

// RetentionRepository forgets location data past its keep-by (plan 30B,
// 3.3): last known locations after 30 days, SOS events after 90.
type RetentionRepository interface {
	ClearStaleLastKnownLocations(ctx context.Context) (int64, error)
	DeleteOldSOSEvents(ctx context.Context) (int64, error)
}

type postgresRetentionRepository struct{ q *sqlcgen.Queries }

// NewRetentionRepository constructs a RetentionRepository backed by pool.
func NewRetentionRepository(pool *pgxpool.Pool) RetentionRepository {
	return &postgresRetentionRepository{q: sqlcgen.New(pool)}
}

func (r *postgresRetentionRepository) ClearStaleLastKnownLocations(ctx context.Context) (int64, error) {
	n, err := r.q.ClearStaleLastKnownLocations(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: clear stale locations: %w", err)
	}
	return n, nil
}

func (r *postgresRetentionRepository) DeleteOldSOSEvents(ctx context.Context) (int64, error) {
	n, err := r.q.DeleteOldSOSEvents(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: delete old sos events: %w", err)
	}
	return n, nil
}
