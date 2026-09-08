package notification

import (
	"context"
	"log/slog"
	"time"
)

// Retention parameters for meetup.notification_outbox (§F8).
//
// The partial claim index already means old rows cost the delivery path
// nothing — a delivered row leaves the index entirely. This is about disk and
// VACUUM hygiene, not query latency. It is still worth doing for the same
// reason as auth.refresh_tokens' sweep (§B3): an unbounded table is nearly
// free to trim continuously from day one and genuinely painful to
// backfill-delete from later.
const (
	// ProcessedRetention keeps successfully delivered rows for a week. They
	// have done their job; a week is a generous margin for anyone debugging
	// a "did this notification actually go out" question.
	ProcessedRetention = 7 * 24 * time.Hour

	// DeadLetterRetention keeps abandoned rows four times longer, on
	// purpose. A dead-lettered row is a real, permanent delivery failure
	// that someone should look at — deleting the evidence on the same
	// schedule as routine successes would quietly destroy the record of the
	// only outcome worth investigating.
	DeadLetterRetention = 30 * 24 * time.Hour

	// retentionInterval is coarse: nothing depends on a delivered row
	// disappearing promptly.
	retentionInterval = time.Hour

	// retentionBatchSize bounds one DELETE, so a large first run (or a run
	// after the job has been off) never holds one long lock. The job loops
	// until a batch comes back short.
	retentionBatchSize = 1000

	// retentionMaxBatches caps one tick's work so a huge backlog is drained
	// over several ticks rather than in one pass competing with live
	// traffic.
	retentionMaxBatches = 50
)

// RetentionStore is the narrow slice of the outbox repository this job needs.
type RetentionStore interface {
	DeleteProcessedOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
	DeleteDeadLetteredOlderThan(ctx context.Context, age time.Duration, batchSize int) (int, error)
}

// Retention deletes outbox rows that have reached a terminal state and
// outlived their retention window.
//
// Same shape and lifecycle as auth.RefreshTokenSweeper and the meetup
// lifecycle poller — started with `go r.Run(ctx)` from cmd/monolith, stops
// cleanly on SIGTERM — so this process has one recognisable pattern for
// periodic background work rather than three.
//
// # SERVES EVERY OUTBOX TABLE, NOT JUST NOTIFICATIONS
//
// It was already parameterized by STORE rather than by table name, so the
// meetups_completed_outbox added in migration 0006 needed a second instance
// (see NewRetentionFor) and no new logic at all. The only thing that was
// notification-specific was the log text, which is now a field — a second
// job logging "notification outbox retention" while deleting rows from a
// different table would be actively misleading during an incident.
type Retention struct {
	label  string
	store  RetentionStore
	logger *slog.Logger
}

// NewRetention constructs the retention job for the notification outbox.
func NewRetention(store RetentionStore, logger *slog.Logger) *Retention {
	return NewRetentionFor("notification outbox", store, logger)
}

// NewRetentionFor constructs the retention job for any outbox table, naming
// it in this job's log lines.
func NewRetentionFor(label string, store RetentionStore, logger *slog.Logger) *Retention {
	if logger == nil {
		logger = slog.Default()
	}
	return &Retention{label: label, store: store, logger: logger}
}

// Run sweeps on a fixed interval until ctx is cancelled.
//
// The first sweep waits for the first tick rather than running at startup: a
// process in a crash loop or a rolling deploy should not run a delete-heavy
// pass on every start, and an hour's delay costs nothing here.
func (r *Retention) Run(ctx context.Context) {
	ticker := time.NewTicker(retentionInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.Tick(ctx)
		}
	}
}

// Tick runs one retention sweep. Exported so a test can drive a single
// iteration deterministically instead of waiting on the ticker.
func (r *Retention) Tick(ctx context.Context) {
	processed, err := r.sweep(ctx, r.store.DeleteProcessedOlderThan, ProcessedRetention)
	if err != nil {
		r.logger.Error(r.label+" retention: delete processed", "error", err)
	}
	deadLettered, err := r.sweep(ctx, r.store.DeleteDeadLetteredOlderThan, DeadLetterRetention)
	if err != nil {
		r.logger.Error(r.label+" retention: delete dead-lettered", "error", err)
	}

	if processed > 0 || deadLettered > 0 {
		r.logger.Info(r.label+" retention",
			"processed_deleted", processed,
			"dead_lettered_deleted", deadLettered,
		)
	}
}

// Sweep runs both halves once and reports the totals. Exported for tests,
// which need the counts rather than a log line.
func (r *Retention) Sweep(ctx context.Context) (processed, deadLettered int, err error) {
	processed, err = r.sweep(ctx, r.store.DeleteProcessedOlderThan, ProcessedRetention)
	if err != nil {
		return processed, 0, err
	}
	deadLettered, err = r.sweep(ctx, r.store.DeleteDeadLetteredOlderThan, DeadLetterRetention)
	return processed, deadLettered, err
}

// sweep loops one delete until the eligible set is drained or the per-tick
// batch ceiling is reached.
func (r *Retention) sweep(
	ctx context.Context,
	del func(ctx context.Context, age time.Duration, batchSize int) (int, error),
	age time.Duration,
) (int, error) {
	total := 0
	for batch := 0; batch < retentionMaxBatches; batch++ {
		if ctx.Err() != nil {
			// A cancelled context ends the sweep cleanly rather than holding
			// shutdown open for a full backlog drain.
			return total, nil
		}
		deleted, err := del(ctx, age, retentionBatchSize)
		if err != nil {
			return total, err
		}
		total += deleted
		if deleted < retentionBatchSize {
			return total, nil
		}
	}
	return total, nil
}
