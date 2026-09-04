package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresUserIdentityRepository implements UserIdentityRepository against
// Postgres via pgx/sqlc.
type postgresUserIdentityRepository struct {
	q *sqlcgen.Queries
}

// NewUserIdentityRepository constructs a UserIdentityRepository backed by
// pool.
func NewUserIdentityRepository(pool *pgxpool.Pool) UserIdentityRepository {
	return &postgresUserIdentityRepository{q: sqlcgen.New(pool)}
}

func (r *postgresUserIdentityRepository) Insert(
	ctx context.Context, userID string, provider IdentityProvider, subject, email string,
) (UserIdentity, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return UserIdentity{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.InsertIdentity(ctx, sqlcgen.InsertIdentityParams{
		UserID:   parsed,
		Provider: sqlcgen.AuthIdentityProvider(provider),
		Subject:  subject,
		Email:    textOrNull(email),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return UserIdentity{}, fmt.Errorf("repository: %s identity already linked: %w", provider, apperror.ErrConflict)
		}
		return UserIdentity{}, fmt.Errorf("repository: insert identity: %w", err)
	}
	return userIdentityFromRow(row), nil
}

func (r *postgresUserIdentityRepository) GetByProviderSubject(
	ctx context.Context, provider IdentityProvider, subject string,
) (UserIdentity, error) {
	row, err := r.q.GetIdentityByProviderSubject(ctx, sqlcgen.GetIdentityByProviderSubjectParams{
		Provider: sqlcgen.AuthIdentityProvider(provider),
		Subject:  subject,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return UserIdentity{}, fmt.Errorf("repository: no %s identity for this subject: %w", provider, apperror.ErrNotFound)
		}
		return UserIdentity{}, fmt.Errorf("repository: get identity by provider/subject: %w", err)
	}
	return userIdentityFromRow(row), nil
}

func (r *postgresUserIdentityRepository) ListForUser(ctx context.Context, userID string) ([]UserIdentity, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListIdentitiesForUser(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list identities for user: %w", err)
	}

	identities := make([]UserIdentity, 0, len(rows))
	for _, row := range rows {
		identities = append(identities, userIdentityFromRow(row))
	}
	return identities, nil
}

func userIdentityFromRow(row sqlcgen.AuthUserIdentity) UserIdentity {
	return UserIdentity{
		ID:       row.ID.String(),
		UserID:   row.UserID.String(),
		Provider: IdentityProvider(row.Provider),
		Subject:  row.Subject,
		Email:    textOrEmpty(row.Email),
		LinkedAt: timestamptzOrZero(row.LinkedAt),
	}
}
