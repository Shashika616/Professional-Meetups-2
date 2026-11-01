package billing

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// OutboxEvent is one billing_outbox row as its consumers see it.
type OutboxEvent struct {
	// ID is the outbox row's id, set by OutboxProcess (not part of the
	// stored payload). A consumer that derives an idempotency key, as the
	// analytics one does, takes it from here.
	ID      string          `json:"-"`
	Topic   string          `json:"topic"`
	Payload json.RawMessage `json:"payload"`
}

// outboxVisibilityTimeout matches the other outboxes' claim timeout.
const outboxVisibilityTimeout = 60 * time.Second

// OutboxStore is billing.billing_outbox as an outbox.Store, plus the two
// retention deletes notification.Retention needs.
type OutboxStore struct {
	q *sqlcgen.Queries
}

// NewOutboxStore constructs the store.
func NewOutboxStore(pool *pgxpool.Pool) *OutboxStore { return &OutboxStore{q: sqlcgen.New(pool)} }

var _ outbox.Store = (*OutboxStore)(nil)

// ClaimBatch claims due rows (see the claim query).
func (o *OutboxStore) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := o.q.ClaimBillingOutboxBatch(ctx, sqlcgen.ClaimBillingOutboxBatchParams{
		VisibilityTimeout: pgtype.Interval{Microseconds: outboxVisibilityTimeout.Microseconds(), Valid: true},
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("billing: claim outbox: %w", err)
	}
	out := make([]outbox.Row, 0, len(rows))
	for _, r := range rows {
		payload, err := json.Marshal(OutboxEvent{Topic: r.Topic, Payload: r.Payload})
		if err != nil {
			return nil, err
		}
		out = append(out, outbox.Row{ID: r.ID.String(), Payload: payload, Attempts: int(r.Attempts)})
	}
	return out, nil
}

func (o *OutboxStore) MarkProcessed(ctx context.Context, id string) error {
	uid, err := uuid.Parse(id)
	if err != nil {
		return err
	}
	return o.q.MarkBillingOutboxProcessed(ctx, uid)
}

func (o *OutboxStore) MarkFailed(ctx context.Context, id string, next time.Time, lastErr string) error {
	uid, err := uuid.Parse(id)
	if err != nil {
		return err
	}
	return o.q.MarkBillingOutboxFailed(ctx, sqlcgen.MarkBillingOutboxFailedParams{
		ID: uid, NextAttemptAt: ts(next), LastError: pgtype.Text{String: truncate(lastErr), Valid: true},
	})
}

func (o *OutboxStore) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	uid, err := uuid.Parse(id)
	if err != nil {
		return err
	}
	return o.q.MarkBillingOutboxDeadLettered(ctx, sqlcgen.MarkBillingOutboxDeadLetteredParams{
		ID: uid, LastError: pgtype.Text{String: truncate(lastErr), Valid: true},
	})
}

func (o *OutboxStore) CountPending(ctx context.Context) (int, error) {
	n, err := o.q.CountPendingBillingOutbox(ctx)
	return int(n), err
}

// DeleteProcessedOlderThan and DeleteDeadLetteredOlderThan keep the table
// bounded (notification.Retention).
func (o *OutboxStore) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batch int) (int, error) {
	n, err := o.q.DeleteProcessedBillingOutbox(ctx, sqlcgen.DeleteProcessedBillingOutboxParams{
		OlderThan: ts(time.Now().Add(-age)), BatchSize: int32(batch),
	})
	return int(n), err
}

func (o *OutboxStore) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batch int) (int, error) {
	n, err := o.q.DeleteDeadLetteredBillingOutbox(ctx, sqlcgen.DeleteDeadLetteredBillingOutboxParams{
		OlderThan: ts(time.Now().Add(-age)), BatchSize: int32(batch),
	})
	return int(n), err
}

func truncate(s string) string {
	const limit = 1000
	if len(s) > limit {
		return s[:limit]
	}
	return s
}

// OutboxConsumer handles one billing event: billing's own store finishes,
// the meetup module's subscription cache, and (29D) analytics, whose
// consumer never returns an error so it can never hold a billing row back.
type OutboxConsumer func(ctx context.Context, e OutboxEvent) error

// OutboxProcess decodes a row and hands it to every consumer, returning the
// first error so the poller retries the row.
func OutboxProcess(consumers ...OutboxConsumer) func(context.Context, outbox.Row) error {
	return func(ctx context.Context, row outbox.Row) error {
		var e OutboxEvent
		if err := json.Unmarshal(row.Payload, &e); err != nil {
			return fmt.Errorf("billing: decode outbox row: %w", err)
		}
		e.ID = row.ID
		for _, c := range consumers {
			if err := c(ctx, e); err != nil {
				return err
			}
		}
		return nil
	}
}
