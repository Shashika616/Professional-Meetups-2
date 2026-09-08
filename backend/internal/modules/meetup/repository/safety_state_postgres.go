package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type postgresSafetyStateRepository struct {
	// pool as well as Queries — Decline needs its own transaction so the
	// notification it triggers commits with it (§F3).
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewSafetyStateRepository constructs a SafetyStateRepository backed by
// pool.
func NewSafetyStateRepository(pool *pgxpool.Pool) SafetyStateRepository {
	return &postgresSafetyStateRepository{pool: pool, q: sqlcgen.New(pool)}
}

// parseSafetyStateIDs is a small shared helper — every method here needs
// both a meetup and a user id parsed the same way.
func parseSafetyStateIDs(meetupID, userID string) (meetup, user uuid.UUID, err error) {
	meetup, err = parseUUID(meetupID)
	if err != nil {
		return uuid.UUID{}, uuid.UUID{}, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err = parseUUID(userID)
	if err != nil {
		return uuid.UUID{}, uuid.UUID{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	return meetup, user, nil
}

func (r *postgresSafetyStateRepository) EnsureExists(ctx context.Context, meetupID, userID string) error {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return err
	}
	if err := r.q.EnsureSafetyState(ctx, sqlcgen.EnsureSafetyStateParams{MeetupID: meetup, UserID: user}); err != nil {
		return fmt.Errorf("repository: ensure safety state: %w", err)
	}
	return nil
}

func (r *postgresSafetyStateRepository) Get(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return SafetyState{}, err
	}
	row, err := r.q.GetSafetyState(ctx, sqlcgen.GetSafetyStateParams{MeetupID: meetup, UserID: user})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SafetyState{}, fmt.Errorf("repository: no safety state for meetup %s, user %s: %w", meetupID, userID, apperror.ErrNotFound)
		}
		return SafetyState{}, fmt.Errorf("repository: get safety state: %w", err)
	}
	return safetyStateFromRow(row), nil
}

func (r *postgresSafetyStateRepository) AcknowledgeChecklist(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return SafetyState{}, err
	}
	row, err := r.q.SetChecklistAck(ctx, sqlcgen.SetChecklistAckParams{MeetupID: meetup, UserID: user})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SafetyState{}, fmt.Errorf("repository: no safety state for meetup %s, user %s: %w", meetupID, userID, apperror.ErrNotFound)
		}
		return SafetyState{}, fmt.Errorf("repository: acknowledge checklist: %w", err)
	}
	return safetyStateFromRow(row), nil
}

func (r *postgresSafetyStateRepository) SetLiveLocationOptIn(ctx context.Context, meetupID, userID string, optIn bool) (SafetyState, error) {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return SafetyState{}, err
	}
	row, err := r.q.SetLiveLocationOptIn(ctx, sqlcgen.SetLiveLocationOptInParams{MeetupID: meetup, UserID: user, LiveLocationOptIn: optIn})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SafetyState{}, fmt.Errorf("repository: no safety state for meetup %s, user %s: %w", meetupID, userID, apperror.ErrNotFound)
		}
		return SafetyState{}, fmt.Errorf("repository: set live location opt-in: %w", err)
	}
	return safetyStateFromRow(row), nil
}

func (r *postgresSafetyStateRepository) CheckIn(ctx context.Context, meetupID, userID string) (SafetyState, error) {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return SafetyState{}, err
	}
	row, err := r.q.SetCheckedIn(ctx, sqlcgen.SetCheckedInParams{MeetupID: meetup, UserID: user})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SafetyState{}, fmt.Errorf("repository: no safety state for meetup %s, user %s: %w", meetupID, userID, apperror.ErrNotFound)
		}
		return SafetyState{}, fmt.Errorf("repository: check in: %w", err)
	}
	return safetyStateFromRow(row), nil
}

// Decline runs in a transaction so the host's notice of the decline commits
// with the decline itself (§F3) — this is the one Safety Gate transition
// that notifies anybody.
func (r *postgresSafetyStateRepository) Decline(ctx context.Context, meetupID, userID, reason string, notify NotifySafetyState) (SafetyState, error) {
	meetup, user, err := parseSafetyStateIDs(meetupID, userID)
	if err != nil {
		return SafetyState{}, err
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return SafetyState{}, fmt.Errorf("repository: begin decline transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	row, err := q.SetDeclined(ctx, sqlcgen.SetDeclinedParams{MeetupID: meetup, UserID: user, DeclineReason: textOrNull(reason)})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SafetyState{}, fmt.Errorf("repository: no safety state for meetup %s, user %s: %w", meetupID, userID, apperror.ErrNotFound)
		}
		return SafetyState{}, fmt.Errorf("repository: decline check-in: %w", err)
	}
	declined := safetyStateFromRow(row)

	if notify != nil {
		if err := notify(ctx, notifyTx{q: q}, declined); err != nil {
			return SafetyState{}, fmt.Errorf("repository: queue decline notification: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return SafetyState{}, fmt.Errorf("repository: commit decline transaction: %w: %w", apperror.ErrInternal, err)
	}
	return declined, nil
}

func safetyStateFromRow(row sqlcgen.MeetupSafetyState) SafetyState {
	return SafetyState{
		MeetupID:          row.MeetupID.String(),
		UserID:            row.UserID.String(),
		ChecklistAckAt:    timePtrOrNil(row.ChecklistAckAt),
		LiveLocationOptIn: row.LiveLocationOptIn,
		CheckedInAt:       timePtrOrNil(row.CheckedInAt),
		DeclinedAt:        timePtrOrNil(row.DeclinedAt),
		DeclineReason:     stringPtrOrNil(row.DeclineReason),
	}
}

func (r *postgresSafetyStateRepository) RecordShare(ctx context.Context, meetupID, userID, contactID string) error {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	contact, err := parseUUID(contactID)
	if err != nil {
		return fmt.Errorf("repository: invalid contact id %q: %w", contactID, apperror.ErrInvalidInput)
	}

	if err := r.q.RecordSafetyShare(ctx, sqlcgen.RecordSafetyShareParams{
		MeetupID:  meetup,
		UserID:    user,
		ContactID: contact,
	}); err != nil {
		return fmt.Errorf("repository: record safety share: %w", err)
	}
	return nil
}

func (r *postgresSafetyStateRepository) ListShareContactIDs(ctx context.Context, meetupID, userID string) ([]string, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListSafetyShareContactIDs(ctx, sqlcgen.ListSafetyShareContactIDsParams{
		MeetupID: meetup,
		UserID:   user,
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list safety share contacts: %w", err)
	}

	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.String())
	}
	return ids, nil
}
