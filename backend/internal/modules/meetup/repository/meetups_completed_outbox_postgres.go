package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// MeetupsCompletedPayload is what one meetups_completed_outbox row decodes
// to: the meetups that just completed and whose participants therefore need
// their totals recomputed.
//
// JSON, rather than handing the poller this table's native uuid[] column
// shape, for the same reason NotificationPayload is JSON — internal/platform/
// outbox's Row.Payload is an opaque []byte and the package never looks
// inside it, so the encoding is entirely this Store's business. Mirroring
// the existing convention rather than inventing a second one.
type MeetupsCompletedPayload struct {
	MeetupIDs []string `json:"meetup_ids"`
}

// MeetupsCompletedOutboxRepository is the persistence behind the async
// meetups-completed recompute.
//
// # WHY THIS EXISTS SEPARATELY FROM THE RECOMPUTE ITSELF
//
// The recompute query is expensive and was being run inside the transaction
// that closes a meetup (see migration 0006's comment). This interface is the
// two halves of taking it off that path: Enqueue* is called on the closing
// transaction (cheap, atomic with the completion), and everything else
// serves the poller that does the expensive work afterwards.
type MeetupsCompletedOutboxRepository interface {
	// RecomputeForMeetups re-derives every affected participant's total and
	// returns the events to publish. Called by the poller's handler, never
	// on a business write's transaction any more.
	RecomputeForMeetups(ctx context.Context, meetupIDs []string) ([]eventbus.MeetupsCompletedUpdatedPayload, error)

	// The rest satisfies internal/platform/outbox.Store.
	ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error)
	MarkProcessed(ctx context.Context, id string) error
	MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error
	MarkDeadLettered(ctx context.Context, id string, lastErr string) error
	CountPending(ctx context.Context) (int, error)

	// Retention (§F8), batched — same contract as the notification outbox's,
	// which is what lets one Retention job type serve both tables.
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
}

type postgresMeetupsCompletedOutboxRepository struct {
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewMeetupsCompletedOutboxRepository constructs the repository.
func NewMeetupsCompletedOutboxRepository(pool *pgxpool.Pool) MeetupsCompletedOutboxRepository {
	return &postgresMeetupsCompletedOutboxRepository{pool: pool, q: sqlcgen.New(pool)}
}

// Compile-time proof this satisfies the generic poller's Store.
var _ outbox.Store = (*postgresMeetupsCompletedOutboxRepository)(nil)

func (r *postgresMeetupsCompletedOutboxRepository) RecomputeForMeetups(ctx context.Context, meetupIDs []string) ([]eventbus.MeetupsCompletedUpdatedPayload, error) {
	return recomputeMeetupsCompleted(ctx, r.q, meetupIDs)
}

// ClaimBatch claims due rows.
//
// Deliberately identical in shape to the notification outbox's — see the
// claim query's comment for why the claim is an UPDATE that stamps a
// visibility timeout rather than a held lock. ClaimVisibilityTimeout is
// shared with that outbox rather than given its own value: this processing
// is database-only and finishes far inside 60 seconds, so a second constant
// would be two numbers to reason about where one suffices.
func (r *postgresMeetupsCompletedOutboxRepository) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := r.q.ClaimMeetupsCompletedOutboxBatch(ctx, sqlcgen.ClaimMeetupsCompletedOutboxBatchParams{
		VisibilityTimeout: intervalFromDuration(ClaimVisibilityTimeout),
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: claim meetups-completed outbox batch: %w", err)
	}

	claimed := make([]outbox.Row, 0, len(rows))
	for _, row := range rows {
		ids := make([]string, 0, len(row.MeetupIds))
		for _, id := range row.MeetupIds {
			ids = append(ids, id.String())
		}
		payload, err := json.Marshal(MeetupsCompletedPayload{MeetupIDs: ids})
		if err != nil {
			return nil, fmt.Errorf("repository: encode meetups-completed payload: %w", err)
		}
		claimed = append(claimed, outbox.Row{
			ID:       row.ID.String(),
			Payload:  payload,
			Attempts: int(row.Attempts),
		})
	}
	return claimed, nil
}

func (r *postgresMeetupsCompletedOutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkMeetupsCompletedProcessed(ctx, parsed); err != nil {
		return fmt.Errorf("repository: mark meetups-completed processed: %w", err)
	}
	return nil
}

func (r *postgresMeetupsCompletedOutboxRepository) MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkMeetupsCompletedFailed(ctx, sqlcgen.MarkMeetupsCompletedFailedParams{
		ID:            parsed,
		NextAttemptAt: toTimestamptz(nextAttemptAt),
		LastError:     textOrNull(truncateError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark meetups-completed failed: %w", err)
	}
	return nil
}

func (r *postgresMeetupsCompletedOutboxRepository) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkMeetupsCompletedDeadLettered(ctx, sqlcgen.MarkMeetupsCompletedDeadLetteredParams{
		ID:        parsed,
		LastError: textOrNull(truncateError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark meetups-completed dead-lettered: %w", err)
	}
	return nil
}

func (r *postgresMeetupsCompletedOutboxRepository) CountPending(ctx context.Context) (int, error) {
	n, err := r.q.CountPendingMeetupsCompleted(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: count pending meetups-completed: %w", err)
	}
	return int(n), nil
}

func (r *postgresMeetupsCompletedOutboxRepository) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteProcessedMeetupsCompleted(ctx, sqlcgen.DeleteProcessedMeetupsCompletedParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete processed meetups-completed: %w", err)
	}
	return int(n), nil
}

func (r *postgresMeetupsCompletedOutboxRepository) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteDeadLetteredMeetupsCompleted(ctx, sqlcgen.DeleteDeadLetteredMeetupsCompletedParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete dead-lettered meetups-completed: %w", err)
	}
	return int(n), nil
}
