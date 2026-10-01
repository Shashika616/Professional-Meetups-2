package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// UserDeletedOutboxRepository is the store behind the user-deleted poller.
//
// Rows are written by postgresUserRepository.Delete, inside the same
// transaction that removes the account (see 0015_user_deleted_outbox.up.sql
// for why that pairing is the entire point). This repository only drains
// them: the generic poller in internal/platform/outbox claims a batch, hands
// each row to cmd/monolith, which publishes eventbus.TopicUserDeleted, and
// records the outcome here.
//
// Structurally a copy of the meetup module's
// postgresMeetupsCompletedOutboxRepository. Copied, not shared: a module
// never imports another module's repository (ADR-001 §3), and the two
// tables would live in different databases the day these modules become
// services.
type UserDeletedOutboxRepository interface {
	ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error)
	MarkProcessed(ctx context.Context, id string) error
	MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error
	MarkDeadLettered(ctx context.Context, id string, lastErr string) error
	CountPending(ctx context.Context) (int, error)
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
}

type postgresUserDeletedOutboxRepository struct {
	q *sqlcgen.Queries
}

// NewUserDeletedOutboxRepository constructs the store.
func NewUserDeletedOutboxRepository(pool *pgxpool.Pool) UserDeletedOutboxRepository {
	return &postgresUserDeletedOutboxRepository{q: sqlcgen.New(pool)}
}

var _ outbox.Store = (*postgresUserDeletedOutboxRepository)(nil)

// UserDeletedClaimVisibilityTimeout is how long a claimed row stays hidden
// from other claimers. Delivery here is an in-process handler that runs a
// handful of indexed single-user deletes, so this is generous; it only
// governs how quickly a row whose claimer crashed becomes claimable again.
const UserDeletedClaimVisibilityTimeout = 60 * time.Second

func (r *postgresUserDeletedOutboxRepository) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := r.q.ClaimUserDeletedOutboxBatch(ctx, sqlcgen.ClaimUserDeletedOutboxBatchParams{
		VisibilityTimeout: pgtype.Interval{Microseconds: UserDeletedClaimVisibilityTimeout.Microseconds(), Valid: true},
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: claim user-deleted outbox batch: %w", err)
	}
	claimed := make([]outbox.Row, 0, len(rows))
	for _, row := range rows {
		payload, err := json.Marshal(eventbus.UserDeletedPayload{UserID: row.UserID.String()})
		if err != nil {
			return nil, fmt.Errorf("repository: encode user-deleted payload: %w", err)
		}
		claimed = append(claimed, outbox.Row{
			ID:       row.ID.String(),
			Payload:  payload,
			Attempts: int(row.Attempts),
		})
	}
	return claimed, nil
}

func (r *postgresUserDeletedOutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	parsed, err := uuid.Parse(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkUserDeletedProcessed(ctx, parsed); err != nil {
		return fmt.Errorf("repository: mark user-deleted processed: %w", err)
	}
	return nil
}

func (r *postgresUserDeletedOutboxRepository) MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error {
	parsed, err := uuid.Parse(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkUserDeletedFailed(ctx, sqlcgen.MarkUserDeletedFailedParams{
		ID:            parsed,
		NextAttemptAt: toTimestamptz(nextAttemptAt),
		LastError:     textOrNull(truncateOutboxError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark user-deleted failed: %w", err)
	}
	return nil
}

func (r *postgresUserDeletedOutboxRepository) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	parsed, err := uuid.Parse(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkUserDeletedDeadLettered(ctx, sqlcgen.MarkUserDeletedDeadLetteredParams{
		ID:        parsed,
		LastError: textOrNull(truncateOutboxError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark user-deleted dead-lettered: %w", err)
	}
	return nil
}

func (r *postgresUserDeletedOutboxRepository) CountPending(ctx context.Context) (int, error) {
	n, err := r.q.CountPendingUserDeleted(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: count pending user-deleted: %w", err)
	}
	return int(n), nil
}

func (r *postgresUserDeletedOutboxRepository) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteProcessedUserDeleted(ctx, sqlcgen.DeleteProcessedUserDeletedParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete processed user-deleted: %w", err)
	}
	return int(n), nil
}

func (r *postgresUserDeletedOutboxRepository) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteDeadLetteredUserDeleted(ctx, sqlcgen.DeleteDeadLetteredUserDeletedParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete dead-lettered user-deleted: %w", err)
	}
	return int(n), nil
}

// maxOutboxErrorLength bounds last_error: the column is for a human to read,
// and an unbounded error string would be an unbounded row.
const maxOutboxErrorLength = 1000

func truncateOutboxError(s string) string {
	if len(s) <= maxOutboxErrorLength {
		return s
	}
	return s[:maxOutboxErrorLength] + "… (truncated)"
}
