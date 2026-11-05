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

// LegalDocuments is one published version of the terms and privacy policy.
type LegalDocuments struct {
	Version string
	Terms   string
	Privacy string
}

// LegalRepository holds the published documents and who accepted them.
type LegalRepository interface {
	// Current returns apperror.ErrNotFound (wrapped) before the first publish.
	Current(ctx context.Context) (LegalDocuments, error)
	// Publish makes docs the current version. Its version must be new.
	Publish(ctx context.Context, docs LegalDocuments) error
	// Accept is safe to repeat: the first acceptance stands.
	Accept(ctx context.Context, userID, version, appVersion, platform string) error
	HasAccepted(ctx context.Context, userID, version string) (bool, error)
}

type postgresLegalRepository struct{ q *sqlcgen.Queries }

// NewLegalRepository constructs a LegalRepository backed by pool.
func NewLegalRepository(pool *pgxpool.Pool) LegalRepository {
	return &postgresLegalRepository{q: sqlcgen.New(pool)}
}

func (r *postgresLegalRepository) Current(ctx context.Context) (LegalDocuments, error) {
	row, err := r.q.CurrentLegalDocuments(ctx)
	if errors.Is(err, pgx.ErrNoRows) {
		return LegalDocuments{}, fmt.Errorf("repository: no legal documents published: %w", apperror.ErrNotFound)
	}
	if err != nil {
		return LegalDocuments{}, fmt.Errorf("repository: current legal documents: %w", err)
	}
	return LegalDocuments{Version: row.Version, Terms: row.Terms, Privacy: row.Privacy}, nil
}

func (r *postgresLegalRepository) Publish(ctx context.Context, docs LegalDocuments) error {
	if err := r.q.PublishLegalDocuments(ctx, sqlcgen.PublishLegalDocumentsParams{
		Version: docs.Version, Terms: docs.Terms, Privacy: docs.Privacy,
	}); err != nil {
		return fmt.Errorf("repository: publish legal documents: %w", err)
	}
	return nil
}

func (r *postgresLegalRepository) Accept(ctx context.Context, userID, version, appVersion, platform string) error {
	id, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id: %w", apperror.ErrInvalidInput)
	}
	if err := r.q.InsertLegalAcceptance(ctx, sqlcgen.InsertLegalAcceptanceParams{
		UserID: id, Version: version, AppVersion: appVersion, Platform: platform,
	}); err != nil {
		return fmt.Errorf("repository: accept legal: %w", err)
	}
	return nil
}

func (r *postgresLegalRepository) HasAccepted(ctx context.Context, userID, version string) (bool, error) {
	id, err := uuid.Parse(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id: %w", apperror.ErrInvalidInput)
	}
	ok, err := r.q.HasLegalAcceptance(ctx, sqlcgen.HasLegalAcceptanceParams{UserID: id, Version: version})
	if err != nil {
		return false, fmt.Errorf("repository: has accepted legal: %w", err)
	}
	return ok, nil
}
