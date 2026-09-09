package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// NotificationPayload is what one outbox row decodes to. It is the contract
// between the meetup module (which writes rows) and the notification module
// (which delivers them) — the two never share a Go type otherwise, since
// neither imports the other.
type NotificationPayload struct {
	FCMTokens []string          `json:"fcm_tokens"`
	Title     string            `json:"title"`
	Body      string            `json:"body"`
	Data      map[string]string `json:"data"`
}

// NotificationOutboxRepository is the meetup module's outbox surface.
//
// It is split in two halves on purpose. WithinTx serves the ONE publisher
// with no business write to attach to (the nearby-notify fan-out, which is
// itself already an event consumer). Everything else — the Store methods —
// serves the poller. Every other publisher never touches this interface at
// all: those enqueue through the NotifyTx handed to them inside their own
// write's transaction (see outbox.go), which is the whole point of §F3.
type NotificationOutboxRepository interface {
	// WithinTx runs fn in its own transaction with a NotifyTx bound to it.
	//
	// For a caller with no accompanying business write there is nothing to be
	// atomic WITH, so this is not weaker than the NotifyTx path — it is the
	// same guarantee applied to a smaller unit of work: the token resolution
	// and every row it produces commit together, so a fan-out can never be
	// half-queued.
	WithinTx(ctx context.Context, fn func(ctx context.Context, tx NotifyTx) error) error

	// The rest satisfies internal/platform/outbox.Store.
	ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error)
	MarkProcessed(ctx context.Context, id string) error
	MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error
	MarkDeadLettered(ctx context.Context, id string, lastErr string) error
	CountPending(ctx context.Context) (int, error)

	// DeleteProcessedOlderThan / DeleteDeadLetteredOlderThan back the
	// retention job (§F8), batched — see the queries for why.
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)

	// ListForUser backs the in-app notification list: rows addressed to
	// userID, newest first, no older than since. Dead-lettered rows are
	// excluded by the query — they never reached anybody.
	ListForUser(ctx context.Context, userID string, since time.Time, limit int) ([]UserNotification, error)
}

// UserNotification is one delivered notification as the recipient sees it.
type UserNotification struct {
	ID        string
	Title     string
	Body      string
	Data      map[string]string
	CreatedAt time.Time
	// Delivered is false while the row is still queued — the push has not
	// gone out yet, but it is already a real notification for this user, so
	// the list shows it rather than pretending nothing happened.
	Delivered bool
}

type postgresNotificationOutboxRepository struct {
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewNotificationOutboxRepository constructs the outbox repository.
func NewNotificationOutboxRepository(pool *pgxpool.Pool) NotificationOutboxRepository {
	return &postgresNotificationOutboxRepository{pool: pool, q: sqlcgen.New(pool)}
}

// Compile-time proof this satisfies the generic poller's Store.
var _ outbox.Store = (*postgresNotificationOutboxRepository)(nil)

func (r *postgresNotificationOutboxRepository) WithinTx(ctx context.Context, fn func(ctx context.Context, tx NotifyTx) error) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("repository: begin outbox transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := fn(ctx, notifyTx{q: r.q.WithTx(tx)}); err != nil {
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("repository: commit outbox transaction: %w: %w", apperror.ErrInternal, err)
	}
	return nil
}

// ClaimVisibilityTimeout is how long a claimed row stays invisible to other
// claimers before it becomes due again on its own.
//
// It bounds two things at once. Too SHORT and a slow-but-succeeding delivery
// gets claimed a second time while the first is still in flight, producing a
// duplicate push. Too LONG and a row whose claimer crashed sits idle for that
// whole period before anyone retries it.
//
// 60 seconds sits comfortably above the worst realistic delivery time — the
// FCM sender's own batch deadline is 30s, and that is itself a pathological
// case — while keeping post-crash recovery to about a minute, which for a
// push notification is unnoticeable.
const ClaimVisibilityTimeout = 60 * time.Second

// ClaimBatch claims due rows.
//
// The claim is an UPDATE that stamps each row's next_attempt_at into the
// future, not a SELECT holding a lock — see the query's own comment for the
// full reasoning. The short version: this caller's "processing" is an FCM
// round trip, and holding a database transaction open across a third-party
// HTTP call would let a degraded FCM exhaust the connection pool. Writing the
// claim instead of holding it means the row leaves the claimable set the
// moment this commits, and stays out of it for ClaimVisibilityTimeout.
func (r *postgresNotificationOutboxRepository) ClaimBatch(ctx context.Context, limit int) ([]outbox.Row, error) {
	rows, err := r.q.ClaimNotificationOutboxBatch(ctx, sqlcgen.ClaimNotificationOutboxBatchParams{
		VisibilityTimeout: intervalFromDuration(ClaimVisibilityTimeout),
		BatchSize:         int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: claim notification outbox batch: %w", err)
	}

	claimed := make([]outbox.Row, 0, len(rows))
	for _, row := range rows {
		var data map[string]string
		if len(row.Data) > 0 {
			if err := json.Unmarshal(row.Data, &data); err != nil {
				// A row whose data column will not decode can never be
				// delivered, no matter how often it is retried. Rather than
				// failing the whole batch — which would block every healthy
				// row behind it — the payload is handed on with empty data
				// and the poller's process function deals with it, the same
				// path any other undeliverable row takes.
				data = map[string]string{}
			}
		}
		payload, err := json.Marshal(NotificationPayload{
			FCMTokens: row.FcmTokens,
			Title:     row.Title,
			Body:      row.Body,
			Data:      data,
		})
		if err != nil {
			return nil, fmt.Errorf("repository: encode outbox payload: %w", err)
		}
		claimed = append(claimed, outbox.Row{
			ID:       row.ID.String(),
			Payload:  payload,
			Attempts: int(row.Attempts),
		})
	}
	return claimed, nil
}

// intervalFromDuration converts a Go duration to the pgtype.Interval the
// claim query's visibility timeout expects.
func intervalFromDuration(d time.Duration) pgtype.Interval {
	return pgtype.Interval{Microseconds: d.Microseconds(), Valid: true}
}

func (r *postgresNotificationOutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkNotificationProcessed(ctx, parsed); err != nil {
		return fmt.Errorf("repository: mark notification processed: %w", err)
	}
	return nil
}

func (r *postgresNotificationOutboxRepository) MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkNotificationFailed(ctx, sqlcgen.MarkNotificationFailedParams{
		ID:            parsed,
		NextAttemptAt: toTimestamptz(nextAttemptAt),
		LastError:     textOrNull(truncateError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark notification failed: %w", err)
	}
	return nil
}

func (r *postgresNotificationOutboxRepository) MarkDeadLettered(ctx context.Context, id string, lastErr string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid outbox row id %q: %w", id, apperror.ErrInvalidInput)
	}
	if err := r.q.MarkNotificationDeadLettered(ctx, sqlcgen.MarkNotificationDeadLetteredParams{
		ID:        parsed,
		LastError: textOrNull(truncateError(lastErr)),
	}); err != nil {
		return fmt.Errorf("repository: mark notification dead-lettered: %w", err)
	}
	return nil
}

func (r *postgresNotificationOutboxRepository) CountPending(ctx context.Context) (int, error) {
	n, err := r.q.CountPendingNotifications(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: count pending notifications: %w", err)
	}
	return int(n), nil
}

func (r *postgresNotificationOutboxRepository) DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteProcessedNotifications(ctx, sqlcgen.DeleteProcessedNotificationsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete processed notifications: %w", err)
	}
	return int(n), nil
}

func (r *postgresNotificationOutboxRepository) DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error) {
	n, err := r.q.DeleteDeadLetteredNotifications(ctx, sqlcgen.DeleteDeadLetteredNotificationsParams{
		OlderThan: toTimestamptz(time.Now().UTC().Add(-age)),
		BatchSize: int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete dead-lettered notifications: %w", err)
	}
	return int(n), nil
}

// maxLastErrorLength bounds what goes into last_error. An unbounded error
// string from a third party is an unbounded row, and this column exists for
// a human to read, not to archive a vendor's HTML error page.
const maxLastErrorLength = 1000

func truncateError(s string) string {
	if len(s) <= maxLastErrorLength {
		return s
	}
	return s[:maxLastErrorLength] + "… (truncated)"
}

func (r *postgresNotificationOutboxRepository) ListForUser(ctx context.Context, userID string, since time.Time, limit int) ([]UserNotification, error) {
	id, err := parseUUID(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListNotificationsForUser(ctx, sqlcgen.ListNotificationsForUserParams{
		UserID:   pgtype.UUID{Bytes: id, Valid: true},
		Since:    pgtype.Timestamptz{Time: since, Valid: true},
		RowLimit: int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list notifications for user: %w", err)
	}

	out := make([]UserNotification, 0, len(rows))
	for _, row := range rows {
		data := map[string]string{}
		if len(row.Data) > 0 {
			// A malformed payload must not take down the whole list — the
			// title and body are what the user actually reads.
			_ = json.Unmarshal(row.Data, &data)
		}
		out = append(out, UserNotification{
			ID:        row.ID.String(),
			Title:     row.Title,
			Body:      row.Body,
			Data:      data,
			CreatedAt: row.CreatedAt.Time,
			Delivered: row.ProcessedAt.Valid,
		})
	}
	return out, nil
}
