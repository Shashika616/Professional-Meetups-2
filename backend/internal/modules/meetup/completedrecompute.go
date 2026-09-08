package meetup

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// CompletedRecompute is the meetups_completed_outbox poller's process
// function — the expensive half of "a meetup completed, so its participants'
// profile totals changed", moved off the transaction that does the
// completing (docs/plans/06-async-meetups-completed-recompute.md).
//
// # WHAT MOVED, AND WHAT DID NOT
//
// Nothing about the event changed. Same topic
// (eventbus.TopicMeetupsCompletedUpdated), same payload, same consumer
// (auth.ApplyMeetupsCompletedUpdate), same absolute-count semantics. Only
// WHEN it is published changed: previously inline before the closing
// transaction's commit, now from a poller after it.
//
// # WHY THIS IS A PARTICULARLY SAFE OUTBOX CONSUMER
//
// internal/platform/outbox is at-least-once, and its package comment is
// explicit that a caller whose side effect is not safely repeatable must not
// use it as-is. This one is about as repeatable as a side effect gets: the
// recompute always re-derives the true current total from authoritative
// rows, never a delta, and the auth-side write is guarded on the count
// itself. A duplicate delivery is a complete no-op, not the "minor
// annoyance" a duplicate push is.
//
// Shaped like notification.Delivery deliberately — same constructor-plus-
// Process-method shape, so cmd/monolith wires two pollers the same way
// rather than two different ways.
type CompletedRecompute struct {
	outbox repository.MeetupsCompletedOutboxRepository
	bus    eventbus.Bus
	logger *slog.Logger
}

// NewCompletedRecompute constructs the processor.
func NewCompletedRecompute(
	store repository.MeetupsCompletedOutboxRepository,
	bus eventbus.Bus,
	logger *slog.Logger,
) *CompletedRecompute {
	if logger == nil {
		logger = slog.Default()
	}
	return &CompletedRecompute{outbox: store, bus: bus, logger: logger}
}

// Process handles one claimed outbox row.
//
// Returning an error hands the row back to the poller's existing
// backoff/dead-letter handling — there is deliberately no retry logic here.
// An undecodable payload is returned wrapped in outbox.ErrPermanent, because
// no number of retries will make it parse.
func (c *CompletedRecompute) Process(ctx context.Context, row outbox.Row) error {
	var payload repository.MeetupsCompletedPayload
	if err := json.Unmarshal(row.Payload, &payload); err != nil {
		return fmt.Errorf("meetup: decode meetups-completed payload: %w: %w", outbox.ErrPermanent, err)
	}
	if len(payload.MeetupIDs) == 0 {
		// Nothing to do, and nothing that retrying would fix. Treated as
		// success so the row leaves the pending set rather than being
		// retried ten times and dead-lettered for being empty.
		return nil
	}

	events, err := c.outbox.RecomputeForMeetups(ctx, payload.MeetupIDs)
	if err != nil {
		// Surfaced, not swallowed: a failed recompute must be retried, or
		// the affected profiles stay stale with nothing to retrigger them —
		// the meetups are already marked completed and will never be
		// claimed again.
		return err
	}

	// Publish failures are logged rather than returned. The bus is
	// in-process and synchronous (ADR-001 §4), so a failure here means a
	// CONSUMER failed, and re-running the whole recompute — including
	// re-publishing for every other participant who succeeded — is not the
	// right response to that. The consumer's own write is idempotent and the
	// next completion for the same user recomputes from scratch anyway.
	for _, event := range events {
		if err := c.bus.Publish(ctx, eventbus.TopicMeetupsCompletedUpdated, event); err != nil {
			c.logger.Error("publish meetups-completed-updated",
				"user_id", event.UserID, "error", err)
		}
	}
	return nil
}
