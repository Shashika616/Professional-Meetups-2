package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/outbox"
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
func (r *postgresMeetupRepository) Create(ctx context.Context, m NewMeetup) (Meetup, error) {
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

	row, err := q.CreateMeetup(ctx, sqlcgen.CreateMeetupParams{
		HostUserID:    hostID,
		Intent:        sqlcgen.MeetupIntentType(m.Intent),
		WindowStart:   toTimestamptz(m.WindowStart),
		WindowEnd:     toTimestamptz(m.WindowEnd),
		LocationLat:   m.LocationLat,
		LocationLng:   m.LocationLng,
		LocationLabel: m.LocationLabel,
		Capacity:      int16(m.Capacity),
	})
	if err != nil {
		return Meetup{}, fmt.Errorf("repository: create meetup: %w", err)
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

func (r *postgresMeetupRepository) ListOpen(
	ctx context.Context, filter OpenMeetupFilter, viewerID string, viewerLat, viewerLng float64, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}

	// A nil Intent becomes a NULL bind, which the query reads as "every
	// intent" — see its WHERE clause. Building the sqlc null wrapper here
	// rather than in the service keeps pgtype/sqlc types out of the module.
	intentArg := sqlcgen.NullMeetupIntentType{}
	if filter.Intent != nil {
		intentArg = sqlcgen.NullMeetupIntentType{
			MeetupIntentType: sqlcgen.MeetupIntentType(*filter.Intent),
			Valid:            true,
		}
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultPageSize
	} else if limit > maxPageSize {
		limit = maxPageSize
	}
	// Fetch one extra row to know whether there's a next page, without a
	// separate count query.
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListOpenMeetupsFirstPage(ctx, sqlcgen.ListOpenMeetupsFirstPageParams{
			Intent:      intentArg,
			WithinDays:  filter.WithinDays,
			RequesterID: viewer,
			PageLimit:   fetchLimit,
			ViewerLat:   viewerLat,
			ViewerLng:   viewerLng,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list open meetups: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
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
			})
		}
	} else {
		rows, err := r.q.ListOpenMeetupsAfterCursor(ctx, sqlcgen.ListOpenMeetupsAfterCursorParams{
			Intent:          intentArg,
			WithinDays:      filter.WithinDays,
			RequesterID:     viewer,
			PageLimit:       fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
			ViewerLat:       viewerLat,
			ViewerLng:       viewerLng,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list open meetups after cursor: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
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
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}

	return meetups, next, nil
}

func (r *postgresMeetupRepository) ListByHost(
	ctx context.Context, hostID string, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	host, err := parseUUID(hostID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid host id %q: %w", hostID, apperror.ErrInvalidInput)
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultMyMeetupsPageSize
	} else if limit > maxMyMeetupsPageSize {
		limit = maxMyMeetupsPageSize
	}
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListMeetupsByHostFirstPage(ctx, sqlcgen.ListMeetupsByHostFirstPageParams{
			HostUserID: host,
			Limit:      fetchLimit,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups by host: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
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
			})
		}
	} else {
		rows, err := r.q.ListMeetupsByHostAfterCursor(ctx, sqlcgen.ListMeetupsByHostAfterCursorParams{
			HostUserID:      host,
			Limit:           fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups by host after cursor: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
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
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}
	return meetups, next, nil
}

func (r *postgresMeetupRepository) ListRequestedByUser(
	ctx context.Context, userID string, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	requester, err := parseUUID(userID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultMyMeetupsPageSize
	} else if limit > maxMyMeetupsPageSize {
		limit = maxMyMeetupsPageSize
	}
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListMeetupsRequestedByUserFirstPage(ctx, sqlcgen.ListMeetupsRequestedByUserFirstPageParams{
			RequesterID: requester,
			Limit:       fetchLimit,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups requested by user: %w", err)
		}
		for _, row := range rows {
			status := MeetupRequestStatus(row.MyRequestStatus)
			meetups = append(meetups, Meetup{
				ID:                    row.ID.String(),
				HostUserID:            row.HostUserID.String(),
				HostFullName:          row.HostFullName,
				HostProfilePhotoURL:   textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:        int(row.HostTrustLevel),
				HostRatingAverage:     numericToFloat64(row.HostRatingAverage),
				HostRatingCount:       int(row.HostRatingCount),
				Intent:                Intent(row.Intent),
				WindowStart:           timestamptzOrZero(row.WindowStart),
				WindowEnd:             timestamptzOrZero(row.WindowEnd),
				LocationLat:           row.LocationLat,
				LocationLng:           row.LocationLng,
				LocationLabel:         row.LocationLabel,
				Capacity:              int(row.Capacity),
				AcceptedCount:         int(row.AcceptedCount),
				Status:                MeetupStatus(row.Status),
				CreatedAt:             timestamptzOrZero(row.CreatedAt),
				CancelledAt:           timePtrOrNil(row.CancelledAt),
				CancellationReason:    stringPtrOrNil(row.CancellationReason),
				ClosedAt:              timePtrOrNil(row.ClosedAt),
				MyRequestStatus:       &status,
				MyRequestAutoRejected: row.MyRequestAutoRejected,
			})
		}
	} else {
		rows, err := r.q.ListMeetupsRequestedByUserAfterCursor(ctx, sqlcgen.ListMeetupsRequestedByUserAfterCursorParams{
			RequesterID:     requester,
			Limit:           fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups requested by user after cursor: %w", err)
		}
		for _, row := range rows {
			status := MeetupRequestStatus(row.MyRequestStatus)
			meetups = append(meetups, Meetup{
				ID:                    row.ID.String(),
				HostUserID:            row.HostUserID.String(),
				HostFullName:          row.HostFullName,
				HostProfilePhotoURL:   textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:        int(row.HostTrustLevel),
				HostRatingAverage:     numericToFloat64(row.HostRatingAverage),
				HostRatingCount:       int(row.HostRatingCount),
				Intent:                Intent(row.Intent),
				WindowStart:           timestamptzOrZero(row.WindowStart),
				WindowEnd:             timestamptzOrZero(row.WindowEnd),
				LocationLat:           row.LocationLat,
				LocationLng:           row.LocationLng,
				LocationLabel:         row.LocationLabel,
				Capacity:              int(row.Capacity),
				AcceptedCount:         int(row.AcceptedCount),
				Status:                MeetupStatus(row.Status),
				CreatedAt:             timestamptzOrZero(row.CreatedAt),
				CancelledAt:           timePtrOrNil(row.CancelledAt),
				CancellationReason:    stringPtrOrNil(row.CancellationReason),
				ClosedAt:              timePtrOrNil(row.ClosedAt),
				MyRequestStatus:       &status,
				MyRequestAutoRejected: row.MyRequestAutoRejected,
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}
	return meetups, next, nil
}

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
			return Meetup{}, fmt.Errorf("repository: meetup %s: %w", id, apperror.ErrNotFound)
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
