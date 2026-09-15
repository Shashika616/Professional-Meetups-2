package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// pgUniqueViolation is Postgres's error code for a UNIQUE constraint
// violation (23505) — mirrors services/auth's users_postgres.go conflict
// handling.
const pgUniqueViolation = "23505"

type postgresMeetupRequestRepository struct {
	// pool (not just *sqlcgen.Queries) — Accept needs to start its own
	// transaction spanning both meetup_requests and meetups, which a
	// plain Queries wrapping the pool alone can't do (backend/meetup-
	// scheduling-PLAN.md Step B).
	pool   *pgxpool.Pool
	q      *sqlcgen.Queries
	bus    eventbus.Bus
	logger *slog.Logger
}

// NewMeetupRequestRepository constructs a MeetupRequestRepository backed by
// pool.
func NewMeetupRequestRepository(pool *pgxpool.Pool, bus eventbus.Bus, logger *slog.Logger) MeetupRequestRepository {
	if logger == nil {
		logger = slog.Default()
	}
	return &postgresMeetupRequestRepository{pool: pool, q: sqlcgen.New(pool), bus: bus, logger: logger}
}

// pendingEvent is one event held back until the transaction that produced
// it commits (ADR-001 §4). The source wrote these into outbox_events inside
// the transaction; with an in-process bus the handler runs immediately, so
// publishing before the commit would expose uncommitted state to it.
// Collected during the transaction, drained by publishAll after.
type pendingEvent struct {
	topic   string
	payload any
}

// publishAll publishes every collected event, logging and continuing past
// any failure — the business write has already committed, so a consumer
// problem must not be reported as a failure of it.
func (r *postgresMeetupRequestRepository) publishAll(ctx context.Context, events []pendingEvent) {
	for _, e := range events {
		if err := r.bus.Publish(ctx, e.topic, e.payload); err != nil {
			r.logger.Error("publish event", "topic", e.topic, "error", err)
		}
	}
}

func (r *postgresMeetupRequestRepository) Create(ctx context.Context, meetupID, requesterID, hostUserID string, guard ScheduleGuard, notify NotifyRequest) (MeetupRequest, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	requester, err := parseUUID(requesterID)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid requester id %q: %w", requesterID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: begin create request transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// Lock, then check, then write — all on this connection (Plan 19).
	if err := runScheduleGuard(ctx, q, requesterID, guard); err != nil {
		return MeetupRequest{}, err
	}

	row, err := q.CreateMeetupRequest(ctx, sqlcgen.CreateMeetupRequestParams{MeetupID: meetup, RequesterID: requester})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
			return MeetupRequest{}, fmt.Errorf("repository: already requested to join this meetup: %w", apperror.ErrConflict)
		}
		return MeetupRequest{}, fmt.Errorf("repository: create meetup request: %w", err)
	}
	created := meetupRequestFromRow(row)

	// Queued inside this transaction, before the commit — the request row
	// and the host's notification of it are one atomic fact (§F3).
	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, created); err != nil {
			return MeetupRequest{}, fmt.Errorf("repository: queue join-request notification: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: commit create request transaction: %w: %w", apperror.ErrInternal, err)
	}

	r.publishAll(ctx, []pendingEvent{{
		topic: TopicRequestCreated,
		payload: requestEventPayload{
			RequestID:   created.ID,
			MeetupID:    meetupID,
			RequesterID: requesterID,
			HostUserID:  hostUserID,
			OccurredAt:  time.Now().UTC(),
		},
	}})
	return created, nil
}

func (r *postgresMeetupRequestRepository) GetByID(ctx context.Context, id string) (MeetupRequest, error) {
	parsed, err := parseUUID(id)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}

	row, err := r.q.GetMeetupRequestWithRequesterInfoByID(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, fmt.Errorf("repository: get meetup request: %w", err)
	}
	return meetupRequestWithRequesterFromRow(row), nil
}

// meetupRequestWithRequesterFromRow converts the joined single-request view.
// Extracted so notifyTx (outbox.go) reads the same shape from inside a
// business write's transaction as GetByID does outside one — two copies of
// this mapping would be two places for a new column to be forgotten.
func meetupRequestWithRequesterFromRow(row sqlcgen.GetMeetupRequestWithRequesterInfoByIDRow) MeetupRequest {
	return MeetupRequest{
		ID:                       row.ID.String(),
		MeetupID:                 row.MeetupID.String(),
		RequesterID:              row.RequesterID.String(),
		RequesterFullName:        row.RequesterFullName,
		RequesterProfilePhotoURL: textOrEmpty(row.RequesterProfilePhotoUrl),
		RequesterTrustLevel:      int(row.RequesterTrustLevel),
		RequesterRatingAverage:   numericToFloat64(row.RequesterRatingAverage),
		RequesterRatingCount:     int(row.RequesterRatingCount),
		Status:                   MeetupRequestStatus(row.Status),
		AutoRejected:             row.AutoRejected,
		CreatedAt:                timestamptzOrZero(row.CreatedAt),
		ResolvedAt:               timePtrOrNil(row.ResolvedAt),
		WithdrawalNote:           stringPtrOrNil(row.WithdrawalNote),
	}
}

func (r *postgresMeetupRequestRepository) ListForMeetup(ctx context.Context, meetupID string) ([]MeetupRequest, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListRequestsForMeetup(ctx, meetup)
	if err != nil {
		return nil, fmt.Errorf("repository: list requests for meetup: %w", err)
	}

	requests := make([]MeetupRequest, 0, len(rows))
	for _, row := range rows {
		requests = append(requests, meetupRequestForMeetupFromRow(row))
	}
	return requests, nil
}

// meetupRequestForMeetupFromRow converts one row of the per-meetup request
// list. Shared with notifyTx (outbox.go) for the same reason as
// meetupRequestWithRequesterFromRow above.
func meetupRequestForMeetupFromRow(row sqlcgen.ListRequestsForMeetupRow) MeetupRequest {
	return MeetupRequest{
		ID:                       row.ID.String(),
		MeetupID:                 row.MeetupID.String(),
		RequesterID:              row.RequesterID.String(),
		RequesterFullName:        row.RequesterFullName,
		RequesterProfilePhotoURL: textOrEmpty(row.RequesterProfilePhotoUrl),
		RequesterTrustLevel:      int(row.RequesterTrustLevel),
		RequesterRatingAverage:   numericToFloat64(row.RequesterRatingAverage),
		RequesterRatingCount:     int(row.RequesterRatingCount),
		Status:                   MeetupRequestStatus(row.Status),
		AutoRejected:             row.AutoRejected,
		CreatedAt:                timestamptzOrZero(row.CreatedAt),
		ResolvedAt:               timePtrOrNil(row.ResolvedAt),
		WithdrawalNote:           stringPtrOrNil(row.WithdrawalNote),
		CheckedInAt:              timePtrOrNil(row.RequesterCheckedInAt),
		DeclinedAt:               timePtrOrNil(row.RequesterDeclinedAt),
		DeclineReason:            stringPtrOrNil(row.RequesterDeclineReason),
	}
}

// Withdraw runs in a transaction now — not because the UPDATE needs one on
// its own (it is a single statement), but because the notification it
// triggers has to commit with it (§F3).
func (r *postgresMeetupRequestRepository) Withdraw(ctx context.Context, id, note, requesterID string, notify NotifyRequest) (MeetupRequest, error) {
	parsed, err := parseUUID(id)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}
	requester, err := parseUUID(requesterID)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid requester id %q: %w", requesterID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: begin withdraw transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// requester_id scoping (Round 11) is defense-in-depth alongside the
	// existing Go-level check in service.go's WithdrawRequest — a
	// mismatched requesterID hits the same zero-rows-affected path as an
	// already-resolved request, mapped to the same ErrConflict below.
	row, err := q.WithdrawMeetupRequest(ctx, sqlcgen.WithdrawMeetupRequestParams{ID: parsed, WithdrawalNote: textOrNull(note), RequesterID: requester})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: request %s is neither pending nor accepted: %w", id, apperror.ErrConflict)
		}
		return MeetupRequest{}, fmt.Errorf("repository: withdraw meetup request: %w", err)
	}
	withdrawn := meetupRequestFromRow(row)

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, withdrawn); err != nil {
			return MeetupRequest{}, fmt.Errorf("repository: queue withdrawal notification: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: commit withdraw transaction: %w: %w", apperror.ErrInternal, err)
	}
	return withdrawn, nil
}

func (r *postgresMeetupRequestRepository) Reject(ctx context.Context, id, hostUserID string, notify NotifyRequest) (MeetupRequest, error) {
	parsed, err := parseUUID(id)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}
	host, err := parseUUID(hostUserID)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid host user id %q: %w", hostUserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: begin reject request transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// host_user_id scoping (Round 11) is defense-in-depth alongside the
	// existing Go-level check in RespondToRequest — a mismatched
	// hostUserID hits the same zero-rows-affected path as an
	// already-resolved request, mapped to the same ErrConflict below.
	row, err := q.RejectMeetupRequest(ctx, sqlcgen.RejectMeetupRequestParams{ID: parsed, HostUserID: host})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: request %s is not pending: %w", id, apperror.ErrConflict)
		}
		return MeetupRequest{}, fmt.Errorf("repository: reject meetup request: %w", err)
	}
	rejected := meetupRequestFromRow(row)

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, rejected); err != nil {
			return MeetupRequest{}, fmt.Errorf("repository: queue rejection notification: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: commit reject request transaction: %w: %w", apperror.ErrInternal, err)
	}

	r.publishAll(ctx, []pendingEvent{{
		topic: TopicRequestRejected,
		payload: requestEventPayload{
			RequestID:   rejected.ID,
			MeetupID:    rejected.MeetupID,
			RequesterID: rejected.RequesterID,
			HostUserID:  hostUserID,
			OccurredAt:  time.Now().UTC(),
		},
	}})
	return rejected, nil
}

// callerHostUserID (Round 11) is the RPC caller's own asserted host id,
// already verified against the meetup's real host by the Go-level check in
// RespondToRequest before this is called — passed through so
// AcceptMeetupRequest's own query can independently re-check the same
// relationship (defense-in-depth). Deliberately distinct from the
// hostUserID local variable below, which is read from meetupRow inside
// this transaction and used only for the outbox payload/notifications —
// re-using that DB-read value for the query's own WHERE clause would be
// tautological (it's always this row's own host) and provide no
// independent check at all.
func (r *postgresMeetupRequestRepository) Accept(
	ctx context.Context, id, callerHostUserID string, notify NotifyAccept,
) (accepted MeetupRequest, meetupNowFull bool, autoRejected []MeetupRequest, err error) {
	requestID, err := parseUUID(id)
	if err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}
	callerHost, err := parseUUID(callerHostUserID)
	if err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: invalid host user id %q: %w", callerHostUserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: begin accept transaction: %w: %w", apperror.ErrInternal, err)
	}
	// Rollback is a no-op if Commit already succeeded — this is just the
	// safety net for every early-return error path below.
	defer func() { _ = tx.Rollback(ctx) }()

	q := r.q.WithTx(tx)

	reqRow, err := q.GetMeetupRequestByID(ctx, requestID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: get request for accept: %w", err)
	}
	if reqRow.Status != sqlcgen.MeetupMeetupRequestStatusPending {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: request %s is not pending: %w", id, apperror.ErrConflict)
	}

	// SELECT ... FOR UPDATE locks this meetup row until the transaction
	// commits or rolls back — a second, concurrent Accept call against the
	// same meetup blocks here until this one finishes, then re-reads the
	// now-current status/capacity rather than racing against a stale read
	// (backend/meetup-scheduling-PLAN.md Step B, the capacity-race
	// integration test exercises exactly this).
	meetupRow, err := q.GetMeetupByIDForUpdate(ctx, reqRow.MeetupID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup %s: %w", reqRow.MeetupID, apperror.ErrNotFound)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: lock meetup for accept: %w", err)
	}
	if meetupRow.Status != sqlcgen.MeetupMeetupStatusOpen {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup %s is not open: %w", reqRow.MeetupID, apperror.ErrConflict)
	}

	acceptedCount, err := q.CountAcceptedRequests(ctx, reqRow.MeetupID)
	if err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: count accepted requests: %w", err)
	}
	if acceptedCount >= int64(meetupRow.Capacity) {
		// Shouldn't normally be reachable — the meetup's status should have
		// already flipped to 'full' the moment capacity was reached — but
		// checked defensively under the same lock rather than trusting that
		// invariant blindly.
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup %s is full: %w", reqRow.MeetupID, apperror.ErrConflict)
	}

	acceptedRow, err := q.AcceptMeetupRequest(ctx, sqlcgen.AcceptMeetupRequestParams{ID: requestID, HostUserID: callerHost})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: request %s is not pending or not owned by caller: %w", id, apperror.ErrConflict)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: accept meetup request: %w", err)
	}

	hostUserID := meetupRow.HostUserID.String()
	acceptedRequest := meetupRequestFromRow(acceptedRow)
	now := time.Now().UTC()

	events := []pendingEvent{{
		topic: TopicRequestAccepted,
		payload: requestEventPayload{
			RequestID:   acceptedRequest.ID,
			MeetupID:    acceptedRequest.MeetupID,
			RequesterID: acceptedRequest.RequesterID,
			HostUserID:  hostUserID,
			OccurredAt:  now,
		},
	}}

	newCount := acceptedCount + 1
	var autoRejectedRows []sqlcgen.MeetupMeetupRequest
	if newCount >= int64(meetupRow.Capacity) {
		if err := q.MarkMeetupFull(ctx, meetupRow.ID); err != nil {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: mark meetup full: %w", err)
		}
		autoRejectedRows, err = q.AutoRejectPendingRequestsForMeetup(ctx, meetupRow.ID)
		if err != nil {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: auto-reject pending requests: %w", err)
		}
		meetupNowFull = true

		for _, row := range autoRejectedRows {
			rejected := meetupRequestFromRow(row)
			events = append(events, pendingEvent{
				topic: TopicRequestRejected,
				payload: requestEventPayload{
					RequestID:    rejected.ID,
					MeetupID:     rejected.MeetupID,
					RequesterID:  rejected.RequesterID,
					HostUserID:   hostUserID,
					AutoRejected: true,
					OccurredAt:   now,
				},
			})
		}
	}

	autoRejected = make([]MeetupRequest, 0, len(autoRejectedRows))
	for _, row := range autoRejectedRows {
		autoRejected = append(autoRejected, meetupRequestFromRow(row))
	}

	// Queued before the commit, with the accept and every auto-rejection it
	// caused, so the whole outcome — one person is in, the rest are out, and
	// all of them are told — is a single atomic fact (§F3). The outbox rows
	// are NOT the same thing as the bus events below: those feed idempotent
	// caches and tolerate loss (ADR-001 §4); these are one-shot,
	// user-visible pushes that do not.
	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, acceptedRequest, autoRejected); err != nil {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: queue accept notifications: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: commit accept transaction: %w: %w", apperror.ErrInternal, err)
	}

	// One accepted event plus one per auto-rejected request, all published
	// after the commit that produced them (ADR-001 §4).
	r.publishAll(ctx, events)

	return acceptedRequest, meetupNowFull, autoRejected, nil
}

// meetupRequestFromRow converts a plain (non-joined) sqlcgen.MeetupMeetupRequest —
// the shape every write query in this file returns via RETURNING — leaving
// RequesterFullName/RequesterProfilePhotoURL/RequesterTrustLevel blank.
// Callers that need those populated (an RPC response) should re-fetch via
// ListForMeetup or the caller's own join, same "write queries don't join"
// pattern as meetups_postgres.go's Create.
func meetupRequestFromRow(row sqlcgen.MeetupMeetupRequest) MeetupRequest {
	return MeetupRequest{
		ID:             row.ID.String(),
		MeetupID:       row.MeetupID.String(),
		RequesterID:    row.RequesterID.String(),
		Status:         MeetupRequestStatus(row.Status),
		AutoRejected:   row.AutoRejected,
		CreatedAt:      timestamptzOrZero(row.CreatedAt),
		ResolvedAt:     timePtrOrNil(row.ResolvedAt),
		WithdrawalNote: stringPtrOrNil(row.WithdrawalNote),
	}
}

func (r *postgresMeetupRequestRepository) CancelPending(ctx context.Context, id, requesterID string) error {
	parsed, err := parseUUID(id)
	if err != nil {
		return fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}
	requester, err := parseUUID(requesterID)
	if err != nil {
		return fmt.Errorf("repository: invalid requester id %q: %w", requesterID, apperror.ErrInvalidInput)
	}
	// No transaction and no notification hook: a cancellation queues
	// nothing for anyone. The WHERE's status/requester scoping makes an
	// already-accepted or foreign request a zero-row delete, reported as
	// the same conflict Withdraw reports for an unwithdrawable one.
	if _, err := r.q.CancelPendingMeetupRequest(ctx, sqlcgen.CancelPendingMeetupRequestParams{ID: parsed, RequesterID: requester}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("repository: request %s is not a pending request of this user: %w", id, apperror.ErrConflict)
		}
		return fmt.Errorf("repository: cancel pending request: %w", err)
	}
	return nil
}
