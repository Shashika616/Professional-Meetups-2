package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresKnownCompanyRepository implements KnownCompanyRepository against
// the manually-seeded known_companies table (migration 0007, ADR-019 §3).
type postgresKnownCompanyRepository struct {
	q *sqlcgen.Queries
}

// NewKnownCompanyRepository constructs a KnownCompanyRepository backed by
// pool.
func NewKnownCompanyRepository(pool *pgxpool.Pool) KnownCompanyRepository {
	return &postgresKnownCompanyRepository{q: sqlcgen.New(pool)}
}

func (r *postgresKnownCompanyRepository) GetByNameNormalized(ctx context.Context, nameNormalized string) (KnownCompany, error) {
	row, err := r.q.GetKnownCompanyByNameNormalized(ctx, nameNormalized)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return KnownCompany{}, fmt.Errorf("repository: known company %q: %w", nameNormalized, apperror.ErrNotFound)
		}
		return KnownCompany{}, fmt.Errorf("repository: get known company by name: %w", err)
	}
	return KnownCompany{
		ID:             row.ID.String(),
		NameNormalized: row.NameNormalized,
		Domains:        row.Domains,
		CreatedAt:      timestamptzOrZero(row.CreatedAt),
	}, nil
}

// postgresUnverifiedCompanyClaimRepository implements
// UnverifiedCompanyClaimRepository against the manual-review queue table
// (migration 0007, ADR-019 §3).
type postgresUnverifiedCompanyClaimRepository struct {
	q *sqlcgen.Queries
}

// NewUnverifiedCompanyClaimRepository constructs an
// UnverifiedCompanyClaimRepository backed by pool.
func NewUnverifiedCompanyClaimRepository(pool *pgxpool.Pool) UnverifiedCompanyClaimRepository {
	return &postgresUnverifiedCompanyClaimRepository{q: sqlcgen.New(pool)}
}

func (r *postgresUnverifiedCompanyClaimRepository) Insert(ctx context.Context, claim UnverifiedCompanyClaim) error {
	parsed, err := uuid.Parse(claim.UserID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", claim.UserID, apperror.ErrInvalidInput)
	}

	if err := r.q.InsertUnverifiedCompanyClaim(ctx, sqlcgen.InsertUnverifiedCompanyClaimParams{
		UserID:             parsed,
		CompanyNameEntered: claim.CompanyNameEntered,
		Domain:             claim.Domain,
	}); err != nil {
		return fmt.Errorf("repository: insert unverified company claim: %w", err)
	}
	return nil
}
