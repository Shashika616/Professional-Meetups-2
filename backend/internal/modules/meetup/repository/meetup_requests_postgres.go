package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
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
		// Zero rows is the conditional INSERT's own answer: this person
		// was rejected on this meetup before (#79, decision D1). It is
		// not the same as the 23505 below and does not deserve the same
		// sentence — "the host already said no" versus "you have already
		// asked".
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf(
				"repository: this meetup's host already declined a request from %s: %w",
				requesterID, apperror.ErrConflict)
		}
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
// conflictIfUniqueViolation turns a 23505 into ErrConflict rather than an
// opaque 500 (tracker #79).
//
// Before migration 0019 these paths genuinely collided: the old
// UNIQUE (meetup_id, requester_id, status) made the STATUS part of the
// key, so rejecting a re-requested row hit the requester's earlier
// 'rejected' row, auto-reject on the final-seat accept hit it too, and a
// second withdrawal hit the earlier 'withdrawn' row. Each surfaced as a
// 500 on an action the host had every right to take.
//
// 0019 removes the collision, so this should now be unreachable. It stays
// because "should be unreachable" is a belief about the schema, and the
// cost of being wrong is a 500 on the host's reject button; a conflict at
// least tells the client to re-read and retry. If one of these ever
// fires, the schema and the code have diverged.
func conflictIfUniqueViolation(err error, action, id string) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
		return fmt.Errorf("repository: %s %s: request state changed under us: %w",
			action, id, apperror.ErrConflict)
	}
	return fmt.Errorf("repository: %s: %w", action, err)
}

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

	// # LOCK THE MEETUP FIRST, IN THE SAME ORDER ACCEPT DOES (tracker #85)
	//
	// Withdrawing can now change the MEETUP as well as the request: a
	// freed seat reopens a full meetup. That makes this a second writer
	// of meetup.status racing AcceptRequest, which reads the accepted
	// count and decides whether the meetup is full.
	//
	// This first read is for one value — which meetup to lock. Its status
	// is deliberately not trusted, exactly as in Accept: it is an
	// unlocked read. Taking the meetup lock BEFORE touching the request
	// also matches Accept's order, so the two paths queue behind each
	// other rather than deadlocking by grabbing the pair in opposite
	// orders.
	locateRow, err := q.GetMeetupRequestByID(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, fmt.Errorf("repository: get request for withdraw: %w", err)
	}
	if _, err := q.GetMeetupByIDForUpdate(ctx, locateRow.MeetupID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: meetup %s: %w", locateRow.MeetupID, apperror.ErrNotFound)
		}
		return MeetupRequest{}, fmt.Errorf("repository: lock meetup for withdraw: %w", err)
	}

	// Re-read the request under the meetup lock, exactly as Accept does,
	// for the status it held BEFORE this withdrawal. The update below
	// cannot supply it: RETURNING hands back the row as written, so its
	// status is always 'withdrawn' and "was this seat occupied?" is not a
	// question it can answer. The unlocked locate read above cannot
	// supply it either — a concurrent accept may have resolved the row in
	// the window before the lock.
	current, err := q.GetMeetupRequestByIDForUpdate(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, fmt.Errorf("repository: re-read request for withdraw: %w", err)
	}
	heldASeat := MeetupRequestStatus(current.Status) == RequestStatusAccepted

	// requester_id scoping (Round 11) is defense-in-depth alongside the
	// existing Go-level check in service.go's WithdrawRequest — a
	// mismatched requesterID hits the same zero-rows-affected path as an
	// already-resolved request, mapped to the same ErrConflict below. The
	// query also refuses a meetup that is over or cancelled (#84).
	row, err := q.WithdrawMeetupRequest(ctx, sqlcgen.WithdrawMeetupRequestParams{ID: parsed, WithdrawalNote: textOrNull(note), RequesterID: requester})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, fmt.Errorf("repository: request %s is not withdrawable on a live meetup: %w", id, apperror.ErrConflict)
		}
		return MeetupRequest{}, conflictIfUniqueViolation(err, "withdraw meetup request", id)
	}
	withdrawn := meetupRequestFromRow(row)

	// Only an accepted request was holding a seat, so only that can free
	// one (#85). The query re-checks 'full' itself, so this is a cheap
	// guard rather than the decision.
	if heldASeat {
		if _, err := q.ReopenMeetupIfSeatFreed(ctx, locateRow.MeetupID); err != nil {
			return MeetupRequest{}, fmt.Errorf("repository: reopen meetup after withdrawal: %w", err)
		}

		// meetups_completed counts accepted requests on completed meetups
		// (tracker #84). Leaving 'accepted' invalidates that total for
		// this person, so the recompute is scheduled in the SAME
		// transaction — the same co-location EnqueueNotification relies
		// on, so there is no window where the withdrawal committed and
		// nobody was asked to recount. The poller computes an absolute
		// count, so an enqueue that turns out to change nothing is
		// harmless.
		if err := q.EnqueueMeetupsCompleted(ctx, []uuid.UUID{locateRow.MeetupID}); err != nil {
			return MeetupRequest{}, fmt.Errorf("repository: enqueue meetups-completed recompute: %w", err)
		}
	}

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
		return MeetupRequest{}, conflictIfUniqueViolation(err, "reject meetup request", id)
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

	// # LOCK FIRST, THEN DECIDE (V-2)
	//
	// This first read is for ONE value: which meetup to lock. Its status is
	// deliberately not trusted — it is an unlocked read, and acting on it is
	// the bug this ordering fixes. Two accepts of the same request both saw
	// 'pending' here, both then waited on the meetup lock, and both went on
	// to accept, counting one seat twice.
	locateRow, err := q.GetMeetupRequestByID(ctx, requestID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: get request for accept: %w", err)
	}

	// SELECT ... FOR UPDATE locks this meetup row until the transaction
	// commits or rolls back — a second, concurrent Accept call against the
	// same meetup blocks here until this one finishes, then re-reads the
	// now-current status/capacity rather than racing against a stale read
	// (backend/meetup-scheduling-PLAN.md Step B, the capacity-race
	// integration test exercises exactly this).
	meetupRow, err := q.GetMeetupByIDForUpdate(ctx, locateRow.MeetupID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup %s: %w", locateRow.MeetupID, apperror.ErrNotFound)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: lock meetup for accept: %w", err)
	}
	if meetupRow.Status != sqlcgen.MeetupMeetupStatusOpen {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup %s is not open: %w", locateRow.MeetupID, apperror.ErrConflict)
	}

	// NOW the request's status means something: re-read it under its own
	// lock, behind the meetup lock, so what we check is the committed state
	// and cannot change under us before the UPDATE.
	reqRow, err := q.GetMeetupRequestByIDForUpdate(ctx, requestID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: meetup request %s: %w", id, apperror.ErrNotFound)
		}
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: lock request for accept: %w", err)
	}
	if reqRow.Status != sqlcgen.MeetupMeetupRequestStatusPending {
		// Conflict, not not-found: the request exists, it has simply already
		// been decided — by the host's first tap, or by the requester
		// withdrawing. Accepting it again must not resurrect it.
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: request %s is not pending: %w", id, apperror.ErrConflict)
	}
	if reqRow.MeetupID != meetupRow.ID {
		// Cannot happen: meetup_id is immutable. Checked anyway, because the
		// value that chose which row to lock came from the unlocked read
		// above, and a lock on the wrong row protects nothing.
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: request %s changed meetup under the lock: %w", id, apperror.ErrConflict)
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
		return MeetupRequest{}, false, nil, conflictIfUniqueViolation(err, "accept meetup request", id)
	}

	hostUserID := meetupRow.HostUserID.String()
	acceptedRequest := meetupRequestFromRow(acceptedRow)
	now := time.Now().UTC()

	// DERIVED, NOT ARITHMETIC (V-2). This was `acceptedCount + 1`, which is
	// only right if this transaction's UPDATE changed exactly one row that
	// was not already accepted — precisely what the old code could not
	// guarantee. Counting again under the same lock asks the database what
	// is true instead of inferring it, so a double accept can no longer
	// manufacture a seat and close the meetup early.
	newCount, err := q.CountAcceptedRequests(ctx, meetupRow.ID)
	if err != nil {
		return MeetupRequest{}, false, nil, fmt.Errorf("repository: recount accepted requests: %w", err)
	}

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

	var autoRejectedRows []sqlcgen.MeetupMeetupRequest
	if newCount >= int64(meetupRow.Capacity) {
		if err := q.MarkMeetupFull(ctx, meetupRow.ID); err != nil {
			return MeetupRequest{}, false, nil, fmt.Errorf("repository: mark meetup full: %w", err)
		}
		// The collision that made the final seat unfillable before 0019:
		// auto-rejecting the remaining pending requests hit the earlier
		// 'rejected' row of anyone who had been rejected and re-requested,
		// and rolled the whole accept back. Mapped rather than wrapped so
		// a recurrence reads as a conflict the client can retry, not a
		// 500 on the host's accept button.
		autoRejectedRows, err = q.AutoRejectPendingRequestsForMeetup(ctx, meetupRow.ID)
		if err != nil {
			return MeetupRequest{}, false, nil, conflictIfUniqueViolation(err, "auto-reject pending requests", id)
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
