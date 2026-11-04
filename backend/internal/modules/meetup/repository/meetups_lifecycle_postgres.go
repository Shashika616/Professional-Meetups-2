package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// Cancel runs in a transaction so the participants' cancellation notices
// commit with the cancellation itself (§F3).
func (r *postgresMeetupRepository) Cancel(ctx context.Context, id, reason, hostUserID string, notify NotifyMeetup) (Meetup, error) {
	meetupID, err := parseUUID(id)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid meetup id %q: %w", id, apperror.ErrInvalidInput)
	}
	host, err := parseUUID(hostUserID)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid host user id %q: %w", hostUserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: begin cancel transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// host_user_id scoping (Round 11) is defense-in-depth alongside the
	// existing Go-level check in service.go's CancelMeetup — mirrors
	// CloseMeetup's own ownership clause exactly.
	row, err := q.CancelMeetup(ctx, sqlcgen.CancelMeetupParams{ID: meetupID, CancellationReason: textOrNull(reason), HostUserID: host})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Three conditions can produce zero rows now, and they are not
			// the same answer (V-10). "Not found" for a meetup that is
			// merely in the wrong state tells the host their meetup has
			// vanished, which is both wrong and alarming.
			return Meetup{}, r.explainFailedCancel(ctx, q, meetupID, host, id)
		}
		return Meetup{}, fmt.Errorf("repository: cancel meetup: %w", err)
	}

	cancelled := Meetup{
		ID:                 row.ID.String(),
		HostUserID:         row.HostUserID.String(),
		Intent:             Intent(row.Intent),
		WindowStart:        timestamptzOrZero(row.WindowStart),
		WindowEnd:          timestamptzOrZero(row.WindowEnd),
		LocationLat:        row.LocationLat,
		LocationLng:        row.LocationLng,
		LocationLabel:      row.LocationLabel,
		Capacity:           int(row.Capacity),
		Status:             MeetupStatus(row.Status),
		CreatedAt:          timestamptzOrZero(row.CreatedAt),
		CancelledAt:        timePtrOrNil(row.CancelledAt),
		CancellationReason: stringPtrOrNil(row.CancellationReason),
		ClosedAt:           timePtrOrNil(row.ClosedAt),
	}

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, cancelled); err != nil {
			return Meetup{}, fmt.Errorf("repository: queue cancellation notifications: %w", err)
		}
	}

	if err := enqueueBillingEvents(ctx, q, BillingTopicCancelled, []sqlcgen.MeetupMeetup{row}); err != nil {
		return Meetup{}, err
	}

	if err := tx.Commit(ctx); err != nil {
		return Meetup{}, fmt.Errorf("repository: commit cancel transaction: %w: %w", apperror.ErrInternal, err)
	}
	return cancelled, nil
}

// Close returns apperror.ErrNotFound (wrapped) if zero rows matched — the
// service layer re-fetches via GetByID to distinguish *why* (wrong host,
// already closed/cancelled, window not started yet) for a useful error
// message, same "query encodes the whole precondition check" shape as
// RejectMeetupRequest's zero-rows-means-ErrConflict pattern elsewhere in
// this package (ADR-016).
// It runs in a transaction for the same reason Cancel does (§F3).
func (r *postgresMeetupRepository) Close(ctx context.Context, id, hostUserID string, notify NotifyMeetup) (Meetup, error) {
	meetupID, err := parseUUID(id)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid meetup id %q: %w", id, apperror.ErrInvalidInput)
	}
	host, err := parseUUID(hostUserID)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid host user id %q: %w", hostUserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: begin close transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	row, err := q.CloseMeetup(ctx, sqlcgen.CloseMeetupParams{ID: meetupID, HostUserID: host})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Meetup{}, fmt.Errorf("repository: meetup %s: %w", id, apperror.ErrNotFound)
		}
		return Meetup{}, fmt.Errorf("repository: close meetup: %w", err)
	}

	closed := Meetup{
		ID:                 row.ID.String(),
		HostUserID:         row.HostUserID.String(),
		Intent:             Intent(row.Intent),
		WindowStart:        timestamptzOrZero(row.WindowStart),
		WindowEnd:          timestamptzOrZero(row.WindowEnd),
		LocationLat:        row.LocationLat,
		LocationLng:        row.LocationLng,
		LocationLabel:      row.LocationLabel,
		Capacity:           int(row.Capacity),
		Status:             MeetupStatus(row.Status),
		CreatedAt:          timestamptzOrZero(row.CreatedAt),
		CancelledAt:        timePtrOrNil(row.CancelledAt),
		CancellationReason: stringPtrOrNil(row.CancellationReason),
		ClosedAt:           timePtrOrNil(row.ClosedAt),
	}

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, closed); err != nil {
			return Meetup{}, fmt.Errorf("repository: queue close notifications: %w", err)
		}
	}

	if err := enqueueMeetupsCompletedRecompute(ctx, q, []Meetup{closed}); err != nil {
		return Meetup{}, err
	}
	if err := enqueueBillingEvents(ctx, q, BillingTopicClosed, []sqlcgen.MeetupMeetup{row}); err != nil {
		return Meetup{}, err
	}

	if err := tx.Commit(ctx); err != nil {
		return Meetup{}, fmt.Errorf("repository: commit close transaction: %w: %w", apperror.ErrInternal, err)
	}

	// Nudge the recompute poller the instant the completion is durable, so
	// the profile figure updates in about the time one query takes rather
	// than waiting up to a tick. The safety-net tick still catches a
	// coalesced nudge or a row written while the poller was down.
	r.wakeMeetupsCompleted()
	return closed, nil
}

// recomputeMeetupsCompleted builds the meetups-completed events for a batch
// of meetups that have completed.
//
// # THIS NO LONGER RUNS ON THE CLOSING TRANSACTION
//
// It used to be called inline from Close and claimSweep, before their
// commits. RecomputeMeetupsCompletedForParticipants re-derives each
// participant's ENTIRE lifetime count from scratch, so that put a query
// whose cost scales with (participants x their full history) inside the
// transaction holding locks on meetup.meetups — with the auto-close sweep
// closing up to 100 meetups in one of them. See migration 0006.
//
// Both call sites now insert a meetups_completed_outbox row instead, and
// this function is called by that outbox's poller
// (MeetupsCompletedOutboxRepository.RecomputeForMeetups) afterwards. Nothing
// about WHAT it computes or publishes changed — only when.
//
// Takes ids rather than []Meetup because its caller is now a poller holding
// a decoded payload, not a repository method holding rows it just wrote.
//
// Returns payloads rather than publishing them so the caller controls
// ordering relative to its own bookkeeping.
func recomputeMeetupsCompleted(ctx context.Context, q *sqlcgen.Queries, meetupIDs []string) ([]eventbus.MeetupsCompletedUpdatedPayload, error) {
	if len(meetupIDs) == 0 {
		return nil, nil
	}
	ids := make([]uuid.UUID, 0, len(meetupIDs))
	for _, id := range meetupIDs {
		parsed, err := parseUUID(id)
		if err != nil {
			// A row naming an unparseable id can never succeed, however many
			// times it is retried — surfaced as permanent so the poller
			// dead-letters it immediately instead of burning its whole retry
			// budget on a payload that is structurally broken.
			return nil, fmt.Errorf("repository: invalid meetup id %q in outbox row: %w", id, outbox.ErrPermanent)
		}
		ids = append(ids, parsed)
	}

	rows, err := q.RecomputeMeetupsCompletedForParticipants(ctx, ids)
	if err != nil {
		return nil, fmt.Errorf("repository: recompute meetups completed: %w", err)
	}

	// One timestamp for the whole batch, taken once: these events all
	// describe the same set of completions, and giving two participants of
	// one meetup microsecond-apart stamps would be inventing an ordering
	// that does not exist. (The auth-side guard compares the COUNT, not this
	// timestamp — see UpsertUserMeetupsCompletedCache — so the stamp is
	// recorded rather than load-bearing.)
	now := time.Now().UTC()
	payloads := make([]eventbus.MeetupsCompletedUpdatedPayload, 0, len(rows))
	for _, row := range rows {
		payloads = append(payloads, eventbus.MeetupsCompletedUpdatedPayload{
			UserID:           row.UserID.String(),
			MeetupsCompleted: int(row.MeetupsCompleted),
			OccurredAt:       now,
		})
	}
	return payloads, nil
}

// enqueueMeetupsCompletedRecompute writes the outbox row that replaces the
// inline recompute — on the SAME transaction as the completion, so a meetup
// can never be completed without its recompute being scheduled.
func enqueueMeetupsCompletedRecompute(ctx context.Context, q *sqlcgen.Queries, meetups []Meetup) error {
	if len(meetups) == 0 {
		return nil
	}
	ids := make([]uuid.UUID, 0, len(meetups))
	for _, m := range meetups {
		ids = append(ids, mustParseUUID(m.ID))
	}
	if err := q.EnqueueMeetupsCompleted(ctx, ids); err != nil {
		return fmt.Errorf("repository: enqueue meetups-completed recompute: %w", err)
	}
	return nil
}

// ClaimStartingSoon atomically claims the next batch of meetups due a
// starting-soon reminder and lets the caller queue their notifications in
// the SAME transaction.
//
// See ClaimMeetupsStartingSoon in queries/meetups.sql for why this is one
// claiming statement rather than a select-then-mark pair (§C2), and
// outbox.go's NotifyTx for why the notification callback runs in here rather
// than after the method returns (§F3).
func (r *postgresMeetupRepository) ClaimStartingSoon(ctx context.Context, limit int, notify NotifyMeetups) ([]Meetup, error) {
	// completes: false — a reminder changes no meetup's status, so nobody's
	// completed total moves and republishing an unchanged count on every
	// reminder would be pure noise.
	return r.claimSweep(ctx, "starting-soon", limit, notify, false,
		func(q *sqlcgen.Queries, batch int32) ([]sqlcgen.MeetupMeetup, error) {
			return q.ClaimMeetupsStartingSoon(ctx, batch)
		})
}

// ClaimReadyToAutoClose atomically closes the next batch of meetups whose
// window has elapsed, with the same transaction-scoped notification hook.
func (r *postgresMeetupRepository) ClaimReadyToAutoClose(ctx context.Context, limit int, notify NotifyMeetups) ([]Meetup, error) {
	// completes: true — this is the sweep that actually marks meetups
	// completed, so it is the one that has to recompute participants'
	// totals. The starting-soon sweep changes no meetup's status and must
	// not (it would publish an unchanged count on every reminder).
	return r.claimSweep(ctx, "auto-close", limit, notify, true,
		func(q *sqlcgen.Queries, batch int32) ([]sqlcgen.MeetupMeetup, error) {
			return q.ClaimMeetupsToAutoClose(ctx, batch)
		})
}

// claimSweep is the shared body of both lifecycle claims — identical
// transaction handling, differing only in which claiming statement runs.
//
// If notify returns an error the whole transaction rolls back, INCLUDING the
// claim: the rows go back to unclaimed and the next tick retries them. That
// is the correct failure mode here and the reason the callback is inside the
// transaction at all — a claim that succeeded while its notification did not
// would silently swallow the reminder forever, since the de-dup guard would
// already be set.
func (r *postgresMeetupRepository) claimSweep(
	ctx context.Context,
	label string,
	limit int,
	notify NotifyMeetups,
	completes bool,
	claim func(q *sqlcgen.Queries, batch int32) ([]sqlcgen.MeetupMeetup, error),
) ([]Meetup, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("repository: begin %s claim transaction: %w: %w", label, apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	rows, err := claim(q, int32(limit))
	if err != nil {
		return nil, fmt.Errorf("repository: claim %s batch: %w", label, err)
	}
	if len(rows) == 0 {
		// Nothing claimed: commit or rollback is equivalent, and rolling
		// back (via the deferred call) avoids a pointless commit round trip
		// on the overwhelmingly common empty tick.
		return nil, nil
	}

	claimed := make([]Meetup, 0, len(rows))
	for _, row := range rows {
		claimed = append(claimed, bareMeetupFromRow(row))
	}

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, claimed); err != nil {
			return nil, fmt.Errorf("repository: queue %s notifications: %w", label, err)
		}
	}

	if completes {
		if err := enqueueMeetupsCompletedRecompute(ctx, q, claimed); err != nil {
			return nil, err
		}
		if err := enqueueBillingEvents(ctx, q, BillingTopicClosed, rows); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("repository: commit %s claim transaction: %w: %w", label, apperror.ErrInternal, err)
	}

	// Only the completing sweep has anything for the recompute poller to do.
	// Waking it after a starting-soon tick would be a guaranteed-empty drain
	// every minute.
	if completes {
		r.wakeMeetupsCompleted()
	}
	return claimed, nil
}

// explainFailedCancel says why a cancel matched no row: the meetup is gone,
// it is not the caller's, or it is no longer cancellable (V-10).
//
// Read on the SAME transaction the failed UPDATE ran on, so it sees exactly
// the state that refused it rather than a later one.
//
// A meetup that exists but belongs to someone else reports not-found, not
// "forbidden": a stranger guessing ids must not be able to tell the
// difference between a meetup that is not theirs and one that does not
// exist.
//
// Nothing has been written at this point and the caller returns immediately
// on this error, so the notify callback never runs and the transaction rolls
// back — no participant is told about a cancellation that did not happen.
func (r *postgresMeetupRepository) explainFailedCancel(
	ctx context.Context, q *sqlcgen.Queries, meetupID, host uuid.UUID, id string,
) error {
	row, err := q.GetMeetupByIDForUpdate(ctx, meetupID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("repository: meetup %s: %w", id, apperror.ErrNotFound)
		}
		return fmt.Errorf("repository: read meetup after failed cancel: %w", err)
	}
	if row.HostUserID != host {
		return fmt.Errorf("repository: meetup %s: %w", id, apperror.ErrNotFound)
	}
	return fmt.Errorf("repository: meetup %s is %s and can no longer be cancelled: %w",
		id, row.Status, apperror.ErrConflict)
}
