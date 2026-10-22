package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
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

// InsertPending adds the contact, its pending-consent row and the
// invitation log entry in one transaction, after checking every cap under
// the user's lock and then the number's lock.
//
// The contact cap moved in here from the service, which used to count and
// then insert as two separate calls: two additions racing could both see
// two contacts and both insert, ending at four.
func (r *postgresTrustedContactRepository) InsertPending(ctx context.Context, c NewPendingContact) (TrustedContact, error) {
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

	if err := qtx.LockTrustedContactInvitesForUser(ctx, c.UserID); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: lock contact invites for user: %w", err)
	}
	if err := qtx.LockTrustedContactInvitesForPhone(ctx, c.PhoneHash); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: lock contact invites for number: %w", err)
	}

	existing, err := qtx.CountTrustedContactsForUser(ctx, user)
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: count trusted contacts: %w", err)
	}
	if int(existing) >= c.MaxContacts {
		return TrustedContact{}, fmt.Errorf("repository: %d trusted contacts: %w", existing, ErrTooManyTrustedContacts)
	}

	since := toTimestamptz(time.Now().Add(-c.CapWindow))
	byUser, err := qtx.CountContactInvitesSentByUserSince(ctx, sqlcgen.CountContactInvitesSentByUserSinceParams{UserID: user, Since: since})
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: count invites by user: %w", err)
	}
	if int(byUser) >= c.MaxInvitesPerUser {
		return TrustedContact{}, fmt.Errorf("repository: %d invites by this user: %w", byUser, ErrContactInviteLimit)
	}
	toPhone, err := qtx.CountContactInvitesSentToPhoneSince(ctx, sqlcgen.CountContactInvitesSentToPhoneSinceParams{PhoneHash: c.PhoneHash, Since: since})
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: count invites to number: %w", err)
	}
	if int(toPhone) >= c.MaxInvitesPerPhone {
		return TrustedContact{}, fmt.Errorf("repository: %d invites to this number: %w", toPhone, ErrContactInviteLimit)
	}

	row, err := qtx.InsertTrustedContact(ctx, sqlcgen.InsertTrustedContactParams{
		UserID:      user,
		Name:        c.Name,
		PhoneNumber: textOrNull(c.PhoneNumber),
		Email:       textOrNull(c.Email),
	})
	if err != nil {
		return TrustedContact{}, fmt.Errorf("repository: insert trusted contact: %w", err)
	}
	if err := qtx.InsertPendingTrustedContact(ctx, sqlcgen.InsertPendingTrustedContactParams{
		ContactID: row.ID,
		TokenHash: c.TokenHash,
		ExpiresAt: toTimestamptz(c.ExpiresAt),
	}); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: insert pending trusted contact: %w", err)
	}
	if err := qtx.InsertContactInviteSent(ctx, sqlcgen.InsertContactInviteSentParams{UserID: user, PhoneHash: c.PhoneHash}); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: log contact invite: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return TrustedContact{}, fmt.Errorf("repository: commit trusted contact insert: %w", err)
	}

	contact := trustedContactFromRow(row)
	contact.PendingUntil = c.ExpiresAt
	return contact, nil
}

func (r *postgresTrustedContactRepository) Confirm(ctx context.Context, tokenHash string) (string, error) {
	name, err := r.q.ConfirmTrustedContactByToken(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("repository: confirmation token: %w", apperror.ErrNotFound)
		}
		return "", fmt.Errorf("repository: confirm trusted contact: %w", err)
	}
	return name, nil
}

func (r *postgresTrustedContactRepository) DeleteInvitesSentBefore(ctx context.Context, before time.Time, batchSize int) (int, error) {
	n, err := r.q.DeleteContactInvitesSentBefore(ctx, sqlcgen.DeleteContactInvitesSentBeforeParams{
		SentBefore: toTimestamptz(before),
		BatchSize:  int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete old contact invites: %w", err)
	}
	return int(n), nil
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
		var pendingUntil time.Time // zero: confirmed
		if row.PendingExpiresAt.Valid {
			pendingUntil = row.PendingExpiresAt.Time
		}
		contacts = append(contacts, TrustedContact{
			ID:           row.ID.String(),
			UserID:       row.UserID.String(),
			Name:         row.Name,
			PhoneNumber:  textOrEmpty(row.PhoneNumber),
			Email:        textOrEmpty(row.Email),
			CreatedAt:    timestamptzOrZero(row.CreatedAt),
			UpdatedAt:    timestamptzOrZero(row.UpdatedAt),
			PendingUntil: pendingUntil,
		})
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
		PhoneNumber: textOrEmpty(row.PhoneNumber),
		Email:       textOrEmpty(row.Email),
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

	id, err := qtx.ClaimSOSEvent(ctx, sqlcgen.ClaimSOSEventParams{
		UserID:          user,
		ClientRequestID: textOrNull(c.ClientRequestID),
		ContextMessage:  textOrNull(c.Event.ContextMessage),
		Latitude:        float8OrNull(c.Event.Latitude),
		Longitude:       float8OrNull(c.Event.Longitude),
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
