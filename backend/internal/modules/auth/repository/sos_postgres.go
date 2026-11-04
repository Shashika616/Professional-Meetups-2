package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresTrustedContactRepository implements TrustedContactRepository
// against the trusted_contacts table (migration 0009, ADR-026 §1).
type postgresTrustedContactRepository struct {
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewTrustedContactRepository constructs a TrustedContactRepository backed
// by pool.
func NewTrustedContactRepository(pool *pgxpool.Pool) TrustedContactRepository {
	return &postgresTrustedContactRepository{pool: pool, q: sqlcgen.New(pool)}
}

// Insert adds the contact after checking the cap under the user's lock.
func (r *postgresTrustedContactRepository) Insert(ctx context.Context, c NewContact) (TrustedContact, error) {
	user, err := uuid.Parse(c.UserID)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: invalid user id %q: %w", c.UserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: begin trusted contact insert: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := r.q.WithTx(tx)

	if err := qtx.LockTrustedContactsForUser(ctx, c.UserID); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: lock trusted contacts: %w", err)
	}
	existing, err := qtx.CountTrustedContactsForUser(ctx, user)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: count trusted contacts: %w", err)
	}
	if int(existing) >= c.MaxContacts {
		return TrustedContact{}, fmt.Errorf("repository: %d trusted contacts: %w", existing, ErrTooManyTrustedContacts)
	}
	row, err := qtx.InsertTrustedContact(ctx, sqlcgen.InsertTrustedContactParams{
		UserID: user, Name: c.Name, PhoneNumber: c.PhoneNumber,
	})
	if err != nil {
		return TrustedContact{}, contactWriteError("insert", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: commit trusted contact insert: %w", err)
	}
	return trustedContactFromRow(row), nil
}

func (r *postgresTrustedContactRepository) Update(ctx context.Context, contactID, userID, name, phoneNumber string) (TrustedContact, error) {
	contact, err := uuid.Parse(contactID)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: invalid contact id %q: %w", contactID, apperror.ErrInvalidInput)
	}
	user, err := uuid.Parse(userID)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	row, err := r.q.UpdateTrustedContact(ctx, sqlcgen.UpdateTrustedContactParams{
		ID: contact, UserID: user, Name: name, PhoneNumber: phoneNumber,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return TrustedContact{}, fmt.Errorf("repository: trusted contact %s: %w", contactID, apperror.ErrNotFound)
	}
	if err != nil {
		return TrustedContact{}, contactWriteError("update", err)
	}
	return trustedContactFromRow(row), nil
}

func contactWriteError(op string, err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return fmt.Errorf("repository: %s trusted contact: %w", op, ErrDuplicateTrustedContact)
	}
	return fmt.Errorf("repository: %s trusted contact: %w", op, err)
}

func (r *postgresTrustedContactRepository) ListForUser(ctx context.Context, userID string) ([]TrustedContact, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListTrustedContactsForUser(ctx, user)
	if err != nil {
		return nil, fmt.Errorf("repository: list trusted contacts: %w", err)
	}
	contacts := make([]TrustedContact, 0, len(rows))
	for _, row := range rows {
		contacts = append(contacts, trustedContactFromRow(row))
	}
	return contacts, nil
}

func (r *postgresTrustedContactRepository) Delete(ctx context.Context, contactID, userID string) error {
	contact, err := uuid.Parse(contactID)
	if err != nil {
		return fmt.Errorf("repository: invalid contact id %q: %w", contactID, apperror.ErrInvalidInput)
	}
	user, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rowsAffected, err := r.q.DeleteTrustedContact(ctx, sqlcgen.DeleteTrustedContactParams{ID: contact, UserID: user})
	if err != nil {
		return fmt.Errorf("repository: delete trusted contact: %w", err)
	}
	if rowsAffected == 0 {
		return fmt.Errorf("repository: trusted contact %s: %w", contactID, apperror.ErrNotFound)
	}
	return nil
}

func trustedContactFromRow(row sqlcgen.AuthTrustedContact) TrustedContact {
	return TrustedContact{
		ID:          row.ID.String(),
		UserID:      row.UserID.String(),
		Name:        row.Name,
		PhoneNumber: row.PhoneNumber,
		CreatedAt:   timestamptzOrZero(row.CreatedAt),
		UpdatedAt:   timestamptzOrZero(row.UpdatedAt),
	}
}

// postgresSOSEventRepository implements SOSEventRepository against the
// sos_events table (migration 0009, ADR-026 §4; 0023 for claims).
type postgresSOSEventRepository struct {
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewSOSEventRepository constructs an SOSEventRepository backed by pool.
func NewSOSEventRepository(pool *pgxpool.Pool) SOSEventRepository {
	return &postgresSOSEventRepository{pool: pool, q: sqlcgen.New(pool)}
}

// Claim runs the duplicate check, the daily count and the insert under the
// user's SOS lock, so a request and its retry arriving together cannot both
// claim, and two alerts cannot both slip under the cap.
func (r *postgresSOSEventRepository) Claim(ctx context.Context, c SOSClaim) (SOSOutcome, error) {
	user, err := uuid.Parse(c.Event.UserID)
	if err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: invalid user id %q: %w", c.Event.UserID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: begin sos claim: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := r.q.WithTx(tx)

	if err := qtx.LockSOSForUser(ctx, c.Event.UserID); err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: lock sos: %w", err)
	}

	if c.ClientRequestID != "" {
		prior, err := qtx.GetSOSEventByClientRequest(ctx, sqlcgen.GetSOSEventByClientRequestParams{
			UserID: user, ClientRequestID: textOrNull(c.ClientRequestID),
		})
		switch {
		case err == nil:
			return SOSOutcome{
				EventID:          prior.ID.String(),
				Duplicate:        true,
				Completed:        prior.CompletedAt.Valid,
				ContactsNotified: int(prior.ContactsNotified),
			}, nil
		case !errors.Is(err, pgx.ErrNoRows):
			return SOSOutcome{}, fmt.Errorf("repository: find sos by client request: %w", err)
		}
	}

	count, err := qtx.CountSOSEventsForUserSince(ctx, sqlcgen.CountSOSEventsForUserSinceParams{
		UserID: user, Since: toTimestamptz(time.Now().Add(-c.Window)),
	})
	if err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: count sos events: %w", err)
	}
	if int(count) >= c.MaxPerWindow {
		return SOSOutcome{}, fmt.Errorf("repository: %d sos events in window: %w", count, ErrSOSLimit)
	}
	if c.MaxPerHour > 0 {
		hourly, err := qtx.CountSOSEventsForUserSince(ctx, sqlcgen.CountSOSEventsForUserSinceParams{
			UserID: user, Since: toTimestamptz(time.Now().Add(-time.Hour)),
		})
		if err != nil {
			return SOSOutcome{}, fmt.Errorf("repository: count sos events: %w", err)
		}
		if int(hourly) >= c.MaxPerHour {
			return SOSOutcome{}, fmt.Errorf("repository: %d sos events in the last hour: %w", hourly, ErrSOSHourlyLimit)
		}
	}

	id, err := qtx.ClaimSOSEvent(ctx, sqlcgen.ClaimSOSEventParams{
		UserID:             user,
		ClientRequestID:    textOrNull(c.ClientRequestID),
		ContextMessage:     textOrNull(c.Event.ContextMessage),
		Latitude:           float8OrNull(c.Event.Latitude),
		Longitude:          float8OrNull(c.Event.Longitude),
		LocationSource:     textOrNull(c.Event.LocationSource),
		LocationCapturedAt: capturedAtOrNull(c.Event.LocationCapturedAt),
	})
	if err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: claim sos event: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: commit sos claim: %w", err)
	}
	return SOSOutcome{EventID: id.String()}, nil
}

func (r *postgresSOSEventRepository) Complete(ctx context.Context, eventID string, contactsNotified int) error {
	id, err := uuid.Parse(eventID)
	if err != nil {
		return fmt.Errorf("repository: invalid sos event id %q: %w", eventID, apperror.ErrInvalidInput)
	}
	if err := r.q.CompleteSOSEvent(ctx, sqlcgen.CompleteSOSEventParams{
		ID: id, ContactsNotified: int32(contactsNotified),
	}); err != nil {
		return fmt.Errorf("repository: complete sos event: %w", err)
	}
	return nil
}

func (r *postgresSOSEventRepository) Outcome(ctx context.Context, userID, clientRequestID string) (SOSOutcome, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return SOSOutcome{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	row, err := r.q.GetSOSEventByClientRequest(ctx, sqlcgen.GetSOSEventByClientRequestParams{
		UserID: user, ClientRequestID: textOrNull(clientRequestID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return SOSOutcome{}, fmt.Errorf("repository: sos event: %w", apperror.ErrNotFound)
		}
		return SOSOutcome{}, fmt.Errorf("repository: read sos event: %w", err)
	}
	return SOSOutcome{
		EventID:          row.ID.String(),
		Duplicate:        true,
		Completed:        row.CompletedAt.Valid,
		ContactsNotified: int(row.ContactsNotified),
	}, nil
}

func capturedAtOrNull(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return toTimestamptz(*t)
}
