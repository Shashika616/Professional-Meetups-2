package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// meetup.activity_outbox topics (migration 0031, plan 29D).
const (
	ActivityTopicRequestCreated  = "request.created"
	ActivityTopicRequestAccepted = "request.accepted"
)

// ActivityEvent is one activity_outbox payload: ids only, never a name or
// text. Its one consumer is analytics (cmd/monolith), which cannot fail.
type ActivityEvent struct {
	Topic       string    `json:"topic"`
	RequestID   string    `json:"request_id"`
	MeetupID    string    `json:"meetup_id"`
	RequesterID string    `json:"requester_id"`
	HostUserID  string    `json:"host_user_id"`
	OccurredAt  time.Time `json:"occurred_at"`
}

// enqueueActivity writes one activity event on the caller's transaction,
// so the request (or the accept) and its record commit together, whether
// or not anyone has a device to notify.
func enqueueActivity(ctx context.Context, q *sqlcgen.Queries, e ActivityEvent) error {
	payload, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if err := q.InsertActivityEvent(ctx, sqlcgen.InsertActivityEventParams{Topic: e.Topic, Payload: payload}); err != nil {
		return fmt.Errorf("repository: queue %s: %w", e.Topic, err)
	}
	return nil
}

// ActivityOutboxRepository is meetup.activity_outbox as an outbox.Store,
// with the retention deletes notification.Retention needs.
type ActivityOutboxRepository interface {
	outbox.Store
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
}

type postgresActivityOutboxRepository struct {
	q *sqlcgen.Queries
}

// NewActivityOutboxRepository constructs the repository.
func NewActivityOutboxRepository(pool *pgxpool.Pool) ActivityOutboxRepository {
	return &postgresActivityOutboxRepository{q: sqlcgen.New(pool)}
}

func (r *postgresActivityOutboxRepository) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := r.q.ClaimActivityOutboxBatch(ctx, sqlcgen.ClaimActivityOutboxBatchParams{
		VisibilityTimeout: intervalFromDuration(ClaimVisibilityTimeout),
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: claim activity outbox: %w", err)
	}
	out := make([]outbox.Row, 0, len(rows))
	for _, row := range rows {
		out = append(out, outbox.Row{ID: row.ID.String(), Payload: row.Payload, Attempts: int(row.Attempts)})
	}
	return out, nil
}

func (r *postgresActivityOutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkActivityEventProcessed(ctx, parsed)
}

func (r *postgresActivityOutboxRepository) MarkFailed(ctx context.Context, id string, next time.Time, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkActivityEventFailed(ctx, sqlcgen.MarkActivityEventFailedParams{
		ID: parsed, NextAttemptAt: toTimestamptz(next), LastError: textOrNull(truncateError(lastErr)),
	})
}

func (r *postgresActivityOutboxRepository) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkActivityEventDeadLettered(ctx, sqlcgen.MarkActivityEventDeadLetteredParams{
		ID: parsed, LastError: textOrNull(truncateError(lastErr)),
	})
}

func (r *postgresActivityOutboxRepository) CountPending(ctx context.Context) (int, error) {
	n, err := r.q.CountPendingActivityEvents(ctx)
	return int(n), err
}

func (r *postgresActivityOutboxRepository) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteProcessedActivityEvents(ctx, sqlcgen.DeleteProcessedActivityEventsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)), BatchSize: int32(batchSize),
	})
	return int(n), err
}

func (r *postgresActivityOutboxRepository) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteDeadLetteredActivityEvents(ctx, sqlcgen.DeleteDeadLetteredActivityEventsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)), BatchSize: int32(batchSize),
	})
	return int(n), err
}
