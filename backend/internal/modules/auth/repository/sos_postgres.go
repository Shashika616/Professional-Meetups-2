package repository

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresTrustedContactRepository implements TrustedContactRepository
// against the trusted_contacts table (migration 0009, ADR-026 §1).
type postgresTrustedContactRepository struct {
	q *sqlcgen.Queries
}

// NewTrustedContactRepository constructs a TrustedContactRepository backed
// by pool.
func NewTrustedContactRepository(pool *pgxpool.Pool) TrustedContactRepository {
	return &postgresTrustedContactRepository{q: sqlcgen.New(pool)}
}

func (r *postgresTrustedContactRepository) Insert(ctx context.Context, userID, name, phoneNumber, email string) (TrustedContact, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	row, err := r.q.InsertTrustedContact(ctx, sqlcgen.InsertTrustedContactParams{
		UserID:      user,
		Name:        name,
		PhoneNumber: textOrNull(phoneNumber),
		Email:       textOrNull(email),
	})
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: insert trusted contact: %w", err)
	}
	return trustedContactFromRow(row), nil
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

func (r *postgresTrustedContactRepository) CountForUser(ctx context.Context, userID string) (int, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return 0, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	count, err := r.q.CountTrustedContactsForUser(ctx, user)
	if err != nil {
		return 0, fmt.Errorf("repository: count trusted contacts: %w", err)
	}
	return int(count), nil
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
		PhoneNumber: textOrEmpty(row.PhoneNumber),
		Email:       textOrEmpty(row.Email),
		CreatedAt:   timestamptzOrZero(row.CreatedAt),
		UpdatedAt:   timestamptzOrZero(row.UpdatedAt),
	}
}

// postgresSOSEventRepository implements SOSEventRepository against the
// sos_events table (migration 0009, ADR-026 §4).
type postgresSOSEventRepository struct {
	q *sqlcgen.Queries
}

// NewSOSEventRepository constructs an SOSEventRepository backed by pool.
func NewSOSEventRepository(pool *pgxpool.Pool) SOSEventRepository {
	return &postgresSOSEventRepository{q: sqlcgen.New(pool)}
}

func (r *postgresSOSEventRepository) Insert(ctx context.Context, event SOSEvent) error {
	user, err := uuid.Parse(event.UserID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", event.UserID, apperror.ErrInvalidInput)
	}
	if err := r.q.InsertSOSEvent(ctx, sqlcgen.InsertSOSEventParams{
		UserID:           user,
		ContextMessage:   textOrNull(event.ContextMessage),
		Latitude:         event.Latitude,
		Longitude:        event.Longitude,
		ContactsNotified: int32(event.ContactsNotified),
	}); err != nil {
		return fmt.Errorf("repository: insert sos event: %w", err)
	}
	return nil
}
