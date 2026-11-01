package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// The topics meetup.billing_outbox carries (plan 29 §3.5, §3.6).
const (
	BillingTopicCreated   = "meetup.created"
	BillingTopicCancelled = "meetup.cancelled"
	BillingTopicClosed    = "meetup.closed"
)

// BillingEvent is a charged meetup's lifecycle fact, as the billing module
// will see it. Facts only: what the meetup module knows about its own
// meetup. What the facts mean for money is billing's decision.
type BillingEvent struct {
	Topic         string    `json:"topic"`
	MeetupID      string    `json:"meetup_id"`
	HostUserID    string    `json:"host_user_id"`
	HoldID        string    `json:"hold_id"`
	AcceptedCount int       `json:"accepted_count"`
	WindowStart   time.Time `json:"window_start"`
	// EndedAt is cancelled_at or closed_at; zero for meetup.created.
	EndedAt time.Time `json:"ended_at,omitempty"`
}

// enqueueBillingEvents writes one event per charged meetup in rows, on the
// caller's transaction. Uncharged meetups (no charge_hold_id: created
// before credits existed, or with no charger wired) write nothing.
func enqueueBillingEvents(ctx context.Context, q *sqlcgen.Queries, topic string, rows []sqlcgen.MeetupMeetup) error {
	for _, row := range rows {
		if !row.ChargeHoldID.Valid {
			continue
		}
		e := BillingEvent{
			Topic:       topic,
			MeetupID:    row.ID.String(),
			HostUserID:  row.HostUserID.String(),
			HoldID:      uuid.UUID(row.ChargeHoldID.Bytes).String(),
			WindowStart: timestamptzOrZero(row.WindowStart),
		}
		switch topic {
		case BillingTopicCancelled:
			e.EndedAt = timestamptzOrZero(row.CancelledAt)
		case BillingTopicClosed:
			e.EndedAt = timestamptzOrZero(row.ClosedAt)
		}
		if topic != BillingTopicCreated {
			n, err := q.CountAcceptedRequests(ctx, row.ID)
			if err != nil {
				return fmt.Errorf("repository: count accepted for billing event: %w", err)
			}
			e.AcceptedCount = int(n)
		}
		payload, err := json.Marshal(e)
		if err != nil {
			return err
		}
		if err := q.InsertBillingEvent(ctx, sqlcgen.InsertBillingEventParams{Topic: topic, Payload: payload}); err != nil {
			return fmt.Errorf("repository: queue %s: %w", topic, err)
		}
	}
	return nil
}

// BillingOutboxRepository is meetup.billing_outbox as an outbox.Store, with
// the retention deletes notification.Retention needs.
type BillingOutboxRepository interface {
	outbox.Store
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
}

type postgresBillingOutboxRepository struct {
	q *sqlcgen.Queries
}

// NewBillingOutboxRepository constructs the repository.
func NewBillingOutboxRepository(pool *pgxpool.Pool) BillingOutboxRepository {
	return &postgresBillingOutboxRepository{q: sqlcgen.New(pool)}
}

// ClaimBatch hands each row's payload — already a BillingEvent with its
// topic — to the poller as-is.
func (r *postgresBillingOutboxRepository) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := r.q.ClaimBillingOutboxBatch(ctx, sqlcgen.ClaimBillingOutboxBatchParams{
		VisibilityTimeout: intervalFromDuration(ClaimVisibilityTimeout),
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: claim billing outbox: %w", err)
	}
	out := make([]outbox.Row, 0, len(rows))
	for _, row := range rows {
		out = append(out, outbox.Row{ID: row.ID.String(), Payload: row.Payload, Attempts: int(row.Attempts)})
	}
	return out, nil
}

func (r *postgresBillingOutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkBillingEventProcessed(ctx, parsed)
}

func (r *postgresBillingOutboxRepository) MarkFailed(ctx context.Context, id string, next time.Time, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkBillingEventFailed(ctx, sqlcgen.MarkBillingEventFailedParams{
		ID: parsed, NextAttemptAt: toTimestamptz(next), LastError: textOrNull(truncateError(lastErr)),
	})
}

func (r *postgresBillingOutboxRepository) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return err
	}
	return r.q.MarkBillingEventDeadLettered(ctx, sqlcgen.MarkBillingEventDeadLetteredParams{
		ID: parsed, LastError: textOrNull(truncateError(lastErr)),
	})
}

func (r *postgresBillingOutboxRepository) CountPending(ctx context.Context) (int, error) {
	n, err := r.q.CountPendingBillingEvents(ctx)
	return int(n), err
}

func (r *postgresBillingOutboxRepository) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteProcessedBillingEvents(ctx, sqlcgen.DeleteProcessedBillingEventsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)), BatchSize: int32(batchSize),
	})
	return int(n), err
}

func (r *postgresBillingOutboxRepository) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteDeadLetteredBillingEvents(ctx, sqlcgen.DeleteDeadLetteredBillingEventsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)), BatchSize: int32(batchSize),
	})
	return int(n), err
}
