package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// defaultPageSize/maxPageSize bound ListOpen's page_size — a client-supplied
// value outside this range is clamped, not rejected, since it's a UX
// parameter, not a security boundary.
const (
	defaultPageSize = 20
	maxPageSize     = 50
)

// defaultMyMeetupsPageSize/maxMyMeetupsPageSize bound ListByHost/
// ListRequestedByUser's page size (2026-08-31 round-3 hardening). Unlike
// ListOpen's page_size, these aren't exposed as a client-supplied
// pagination param on the proto — ListMyMeetups/ListActiveMeetups
// (service.go) always request a single page with cursor=nil, matching
// the flat LIMIT 200 this replaced, so the max here is set to cover
// realistic host/participant meetup counts in one page rather than
// ListOpen's smaller browse-UX page size.
const (
	defaultMyMeetupsPageSize = 200
	maxMyMeetupsPageSize     = 500
)

type postgresMeetupRepository struct {
	// pool (not just *sqlcgen.Queries) — Create opens its own transaction.
	// In the source that transaction spanned the INSERT and the outbox row;
	// here it wraps the INSERT alone, and the event goes out on the bus
	// after the commit (ADR-001 §4).
	pool   *pgxpool.Pool
	q      *sqlcgen.Queries
	bus    eventbus.Bus
	logger *slog.Logger

	// wakeCompleted nudges the meetups-completed recompute poller after a
	// completion commits. Optional: a nil wake just means the recompute
	// waits for the poller's safety-net tick, which is what most tests want
	// and is never incorrect, only slower — the same contract meetup.Deps'
	// own Wake has.
	wakeCompleted func()
}

// NewMeetupRepository constructs a MeetupRepository backed by pool,
// publishing its meetup-created events on bus.
// NewMeetupRepository constructs the meetup repository.
//
// wakeMeetupsCompleted is the meetups-completed recompute poller's Wake, and
// may be nil (see the field's comment). It is a function rather than the
// poller itself to keep this package unaware of internal/platform/outbox's
// Poller type, and to break what would otherwise be a construction cycle:
// the poller needs a Store, and this repository needs the poller's Wake.
func NewMeetupRepository(pool *pgxpool.Pool, bus eventbus.Bus, logger *slog.Logger, wakeMeetupsCompleted func()) MeetupRepository {
	if logger == nil {
		logger = slog.Default()
	}
	return &postgresMeetupRepository{
		pool:          pool,
		q:             sqlcgen.New(pool),
		bus:           bus,
		logger:        logger,
		wakeCompleted: wakeMeetupsCompleted,
	}
}

// wakeMeetupsCompleted nudges the recompute poller if one was wired.
func (r *postgresMeetupRepository) wakeMeetupsCompleted() {
	if r.wakeCompleted != nil {
		r.wakeCompleted()
	}
}

// publish is the shared "commit first, then tell the bus" tail every
// event-producing method in this package uses (ADR-001 §4). A failed
// in-process handler must not fail — or appear to fail — the business write
// that already committed, so this logs and moves on.
func (r *postgresMeetupRepository) publish(ctx context.Context, topic string, payload any) {
	if err := r.bus.Publish(ctx, topic, payload); err != nil {
		r.logger.Error("publish event", "topic", topic, "error", err)
	}
}

// Create does not populate HostFullName/HostProfilePhotoURL/HostTrustLevel/
// AcceptedCount on the returned Meetup — the underlying INSERT has nothing
// to join against yet. Callers that need the fully-populated view (e.g. the
// service layer building a CreateMeetup RPC response) should follow up with
// GetByID.
//
// Publishes meetup-created (ADR-021 §1, backend/geo-visibility-and-nearby-
// notifications-PLAN.md Step 1) through the same transaction as the INSERT
// — the event ADR-008's addendum flagged as missing since before any
// "notify about nearby meetups" feature could exist.
func (r *postgresMeetupRepository) Create(ctx context.Context, m NewMeetup, guard ScheduleGuard) (Meetup, error) {
	hostID, err := parseUUID(m.HostUserID)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid host user id %q: %w", m.HostUserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: begin create meetup transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// Lock, then check, then write — all on this connection (Plan 19).
	//
	// The idempotency check runs under the same lock and BEFORE the
	// schedule guard: a retry of a create that already succeeded would
	// otherwise be refused as a clash with the very meetup it created.
	if guard != nil || m.CreationKey != "" {
		if err := q.LockUserSchedule(ctx, m.HostUserID); err != nil {
			return Meetup{}, fmt.Errorf("repository: lock user schedule: %w: %w", apperror.ErrInternal, err)
		}
	}
	if m.CreationKey != "" {
		existing, err := q.GetMeetupByCreationKey(ctx, sqlcgen.GetMeetupByCreationKeyParams{
			HostUserID: hostID, CreationKey: textOrNull(m.CreationKey),
		})
		if err == nil {
			return Meetup{}, &CreationKeyExistsError{MeetupID: existing.ID.String(), RequestHash: existing.CreationRequestHash.String}
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return Meetup{}, fmt.Errorf("repository: look up creation key: %w", err)
		}
	}
	if guard != nil {
		// Returned as-is: the guard's error is the caller's own typed error.
		if err := guard(ctx, scheduleTx{q: q}); err != nil {
			return Meetup{}, err
		}
	}

	holdID := pgtype.UUID{}
	if m.ChargeHoldID != "" {
		parsed, err := parseUUID(m.ChargeHoldID)
		if err != nil {
			return Meetup{}, fmt.Errorf("repository: invalid charge hold id: %w", apperror.ErrInternal)
		}
		holdID = pgtype.UUID{Bytes: parsed, Valid: true}
	}
	row, err := q.CreateMeetup(ctx, sqlcgen.CreateMeetupParams{
		HostUserID:          hostID,
		Intent:              sqlcgen.MeetupIntentType(m.Intent),
		WindowStart:         toTimestamptz(m.WindowStart),
		WindowEnd:           toTimestamptz(m.WindowEnd),
		LocationLat:         m.LocationLat,
		LocationLng:         m.LocationLng,
		LocationLabel:       m.LocationLabel,
		Capacity:            int16(m.Capacity),
		CreationKey:         textOrNull(m.CreationKey),
		ChargeHoldID:        holdID,
		CreationRequestHash: textOrNull(m.CreationRequestHash),
	})
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: create meetup: %w", err)
	}

	// The charge's capture is queued in the same transaction as the meetup
	// it pays for: either both exist or neither does (plan 29 §3.5).
	if err := enqueueBillingEvents(ctx, q, BillingTopicCreated, []sqlcgen.MeetupMeetup{row}); err != nil {
		return Meetup{}, err
	}

	created := Meetup{
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

	if err := tx.Commit(ctx); err != nil {
		return Meetup{}, fmt.Errorf("repository: commit create meetup transaction: %w: %w", apperror.ErrInternal, err)
	}

	// meetup-created, published AFTER the commit (ADR-001 §4) rather than
	// written into an outbox row inside the transaction the way the source
	// does. Its subscriber — the nearby-notify fan-out — runs synchronously
	// and immediately, so publishing inside the still-open transaction would
	// let that handler query for a meetup its own caller hasn't committed
	// yet. A publish failure is logged, never propagated: the meetup is
	// already created, and reporting failure for committed work would be
	// wrong.
	r.publish(ctx, eventbus.TopicMeetupCreated, eventbus.MeetupCreatedPayload{
		MeetupID:    created.ID,
		HostUserID:  created.HostUserID,
		Intent:      string(created.Intent),
		LocationLat: created.LocationLat,
		LocationLng: created.LocationLng,
		WindowStart: created.WindowStart,
		OccurredAt:  time.Now().UTC(),
	})

	return created, nil
}

func (r *postgresMeetupRepository) FindByCreationKey(ctx context.Context, hostUserID, key string) (Meetup, error) {
	host, err := parseUUID(hostUserID)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid host user id: %w", apperror.ErrInvalidInput)
	}
	row, err := r.q.GetMeetupByCreationKey(ctx, sqlcgen.GetMeetupByCreationKeyParams{HostUserID: host, CreationKey: textOrNull(key)})
	if errors.Is(err, pgx.ErrNoRows) {
		return Meetup{}, fmt.Errorf("repository: no meetup for this creation key: %w", apperror.ErrNotFound)
	}
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: look up creation key: %w", err)
	}
	out := bareMeetupFromRow(row)
	out.CreationRequestHash = row.CreationRequestHash.String
	return out, nil
}

func (r *postgresMeetupRepository) GetByID(ctx context.Context, id, viewerID string) (Meetup, error) {
	meetupID, err := parseUUID(id)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid meetup id %q: %w", id, apperror.ErrInvalidInput)
	}
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}

	row, err := r.q.GetMeetupByID(ctx, sqlcgen.GetMeetupByIDParams{ID: meetupID, RequesterID: viewer})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Meetup{}, fmt.Errorf("repository: meetup %s: %w", id, apperror.ErrNotFound)
		}
		return Meetup{}, fmt.Errorf("repository: get meetup: %w", err)
	}

	return Meetup{
		ID:                  row.ID.String(),
		HostUserID:          row.HostUserID.String(),
		HostFullName:        row.HostFullName,
		HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
		HostTrustLevel:      int(row.HostTrustLevel),
		HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
		HostRatingCount:     int(row.HostRatingCount),
		Intent:              Intent(row.Intent),
		WindowStart:         timestamptzOrZero(row.WindowStart),
		WindowEnd:           timestamptzOrZero(row.WindowEnd),
		LocationLat:         row.LocationLat,
		LocationLng:         row.LocationLng,
		LocationLabel:       row.LocationLabel,
		Capacity:            int(row.Capacity),
		AcceptedCount:       int(row.AcceptedCount),
		Status:              MeetupStatus(row.Status),
		CreatedAt:           timestamptzOrZero(row.CreatedAt),
		CancelledAt:         timePtrOrNil(row.CancelledAt),
		CancellationReason:  stringPtrOrNil(row.CancellationReason),
		ClosedAt:            timePtrOrNil(row.ClosedAt),
		MyRequestStatus:     requestStatusPtrOrNil(row.MyRequestStatus),
		MyRequestID:         uuidPtrOrNil(row.MyRequestID),
	}, nil
}

// runScheduleGuard takes userID's schedule lock on q's transaction and
// runs guard against it. A nil guard takes no lock: callers with nothing
// to check must not queue behind ones that do.
func runScheduleGuard(ctx context.Context, q *sqlcgen.Queries, userID string, guard ScheduleGuard) error {
	if guard == nil {
		return nil
	}
	if err := q.LockUserSchedule(ctx, userID); err != nil {
		return fmt.Errorf("repository: lock user schedule: %w: %w", apperror.ErrInternal, err)
	}
	// Returned as-is: the guard's error is the caller's own typed error.
	return guard(ctx, scheduleTx{q: q})
}

// FindScheduleConflict on the pool: the same query as the locked read,
// for the advisory pre-check.
func (r *postgresMeetupRepository) FindScheduleConflict(
	ctx context.Context, userID string, windowStart, windowEnd time.Time, excludeID string,
) (Meetup, bool, error) {
	return scheduleTx{q: r.q}.FindScheduleConflict(ctx, userID, windowStart, windowEnd, excludeID)
}

// scheduleTx is the ScheduleTx a guard sees: the locked transaction (or,
// for the pre-check above, the pool).
type scheduleTx struct{ q *sqlcgen.Queries }

func (s scheduleTx) FindScheduleConflict(
	ctx context.Context, userID string, windowStart, windowEnd time.Time, excludeID string,
) (Meetup, bool, error) {
	user, err := parseUUID(userID)
	if err != nil {
		return Meetup{}, false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	// The nil UUID matches no row, so "nothing to exclude" needs no second
	// query shape.
	var exclude uuid.UUID
	if excludeID != "" {
		if exclude, err = parseUUID(excludeID); err != nil {
			return Meetup{}, false, fmt.Errorf("repository: invalid meetup id %q: %w", excludeID, apperror.ErrInvalidInput)
		}
	}

	row, err := s.q.FindScheduleConflict(ctx, sqlcgen.FindScheduleConflictParams{
		UserID:      user,
		WindowStart: toTimestamptz(windowStart),
		WindowEnd:   toTimestamptz(windowEnd),
		ExcludeID:   exclude,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Meetup{}, false, nil
		}
		return Meetup{}, false, fmt.Errorf("repository: find schedule conflict: %w", err)
	}

	return Meetup{
		ID:                  row.ID.String(),
		HostUserID:          row.HostUserID.String(),
		HostFullName:        row.HostFullName,
		HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
		HostTrustLevel:      int(row.HostTrustLevel),
		HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
		HostRatingCount:     int(row.HostRatingCount),
		Intent:              Intent(row.Intent),
		WindowStart:         timestamptzOrZero(row.WindowStart),
		WindowEnd:           timestamptzOrZero(row.WindowEnd),
		LocationLat:         row.LocationLat,
		LocationLng:         row.LocationLng,
		LocationLabel:       row.LocationLabel,
		Capacity:            int(row.Capacity),
		AcceptedCount:       int(row.AcceptedCount),
		Status:              MeetupStatus(row.Status),
		CreatedAt:           timestamptzOrZero(row.CreatedAt),
		CancelledAt:         timePtrOrNil(row.CancelledAt),
		CancellationReason:  stringPtrOrNil(row.CancellationReason),
		ClosedAt:            timePtrOrNil(row.ClosedAt),
		MyRequestStatus:     requestStatusPtrOrNil(row.MyRequestStatus),
		MyRequestID:         uuidPtrOrNil(row.MyRequestID),
	}, true, nil
}

func mustParseUUID(id string) uuid.UUID {
	parsed, err := parseUUID(id)
	if err != nil {
		// Cursor.ID is only ever constructed by this package from a real
		// database row's id (see ListOpen above) — a parse failure here
		// means a caller fabricated a cursor by hand, which is a
		// programming error, not a runtime condition to recover from.
		panic(fmt.Sprintf("repository: cursor id %q is not a valid uuid: %v", id, err))
	}
	return parsed
}

// bareMeetupFromRow converts a bare (unjoined) sqlcgen.Meetup row — no
// host display info, same limitation Close/Cancel's own inline conversions
// have (see this file's earlier CreateMeetup/Close comments on why: those
// queries have nothing to join against).
func bareMeetupFromRow(row sqlcgen.MeetupMeetup) Meetup {
	return Meetup{
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
}

// ListStartingSoonUnnotified/MarkStartingSoonNotified/ListReadyToAutoClose/
// AutoClose back the lifecycle poller's two sweeps (ADR-025 §4,
// internal/lifecycle/poller.go).

func (r *postgresMeetupRepository) ListParticipants(ctx context.Context, meetupID string) ([]MeetupParticipant, error) {
	id, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListMeetupParticipants(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("repository: list meetup participants: %w", err)
	}
	out := make([]MeetupParticipant, 0, len(rows))
	for _, row := range rows {
		out = append(out, MeetupParticipant{
			UserID:          row.UserID.String(),
			IsHost:          row.IsHost,
			FullName:        row.FullName,
			ProfilePhotoURL: row.ProfilePhotoUrl.String,
			TrustLevel:      int(row.TrustLevel),
		})
	}
	return out, nil
}

func (r *postgresMeetupRepository) CountCreatedByHostSince(ctx context.Context, hostUserID string, since time.Time) (int, error) {
	host, err := uuid.Parse(hostUserID)
	if err != nil {
		return 0, fmt.Errorf("repository: invalid host user id %q: %w", hostUserID, apperror.ErrInvalidInput)
	}
	n, err := r.q.CountMeetupsCreatedByHostSince(ctx, sqlcgen.CountMeetupsCreatedByHostSinceParams{
		HostUserID: host,
		Since:      toTimestamptz(since),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: count meetups by host: %w", err)
	}
	return int(n), nil
}
