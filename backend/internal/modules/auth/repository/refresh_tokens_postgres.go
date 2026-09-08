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

// postgresRefreshTokenRepository implements RefreshTokenRepository against
// Postgres via pgx/sqlc.
type postgresRefreshTokenRepository struct {
	pool *pgxpool.Pool
	q    *sqlcgen.Queries
}

// NewRefreshTokenRepository constructs a RefreshTokenRepository backed by
// pool.
func NewRefreshTokenRepository(pool *pgxpool.Pool) RefreshTokenRepository {
	return &postgresRefreshTokenRepository{pool: pool, q: sqlcgen.New(pool)}
}

func (r *postgresRefreshTokenRepository) Create(ctx context.Context, userID, tokenHash string, expiresAt time.Time) (RefreshToken, error) {
	parsedUserID, err := uuid.Parse(userID)
	if err != nil {
		return RefreshToken{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.CreateRefreshToken(ctx, sqlcgen.CreateRefreshTokenParams{
		UserID:    parsedUserID,
		TokenHash: tokenHash,
		ExpiresAt: toTimestamptz(expiresAt),
	})
	if err != nil {
		return RefreshToken{}, fmt.Errorf("repository: create refresh token: %w", err)
	}
	return refreshTokenFromRow(row), nil
}

func (r *postgresRefreshTokenRepository) FindByHash(ctx context.Context, tokenHash string) (RefreshToken, error) {
	row, err := r.q.GetRefreshTokenByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RefreshToken{}, fmt.Errorf("repository: refresh token: %w", apperror.ErrNotFound)
		}
		return RefreshToken{}, fmt.Errorf("repository: get refresh token by hash: %w", err)
	}
	return refreshTokenFromRow(row), nil
}

// Rotate marks oldID's row as replaced and inserts a new row in a single
// transaction (PLAN.md Step 4: "don't do this as two separate
// non-transactional calls") — a crash between the two writes must never
// leave a rotated-out token looking still-valid, or a new token issued
// without the old one being invalidated.
func (r *postgresRefreshTokenRepository) Rotate(ctx context.Context, oldID, newTokenHash string, newExpiresAt time.Time) (string, error) {
	parsedOldID, err := uuid.Parse(oldID)
	if err != nil {
		return "", fmt.Errorf("repository: invalid refresh token id %q: %w", oldID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("repository: begin rotate transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed

	qtx := r.q.WithTx(tx)

	// Fetch the old row first (for its owning user) — the new row's id is
	// server-generated (DEFAULT gen_random_uuid()), so it isn't known until
	// after CreateRefreshToken runs, which is why replaced_by is set in a
	// third step below rather than passed to CreateRefreshToken directly.
	old, err := qtx.GetRefreshTokenByID(ctx, parsedOldID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("repository: refresh token %q: %w", oldID, apperror.ErrNotFound)
		}
		return "", fmt.Errorf("repository: get refresh token by id: %w", err)
	}

	created, err := qtx.CreateRefreshToken(ctx, sqlcgen.CreateRefreshTokenParams{
		UserID:    old.UserID,
		TokenHash: newTokenHash,
		ExpiresAt: toTimestamptz(newExpiresAt),
	})
	if err != nil {
		return "", fmt.Errorf("repository: create replacement refresh token: %w", err)
	}

	if err := qtx.MarkRefreshTokenReplaced(ctx, sqlcgen.MarkRefreshTokenReplacedParams{
		ID:         parsedOldID,
		ReplacedBy: pgtypeUUID(created.ID),
	}); err != nil {
		return "", fmt.Errorf("repository: mark refresh token replaced: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("repository: commit rotate transaction: %w", err)
	}

	return created.ID.String(), nil
}

func (r *postgresRefreshTokenRepository) Revoke(ctx context.Context, tokenHash string) error {
	if err := r.q.RevokeRefreshTokenByHash(ctx, tokenHash); err != nil {
		return fmt.Errorf("repository: revoke refresh token: %w", err)
	}
	return nil
}

// RevokeAllForUser revokes every non-revoked refresh token for userID.
//
// One UPDATE, not a select-then-loop: the set being revoked is exactly "this
// user's live tokens," which the WHERE clause expresses directly, and doing
// it in a single statement means a concurrent refresh cannot slip a
// newly-rotated token past the sweep between the read and the write.
func (r *postgresRefreshTokenRepository) RevokeAllForUser(ctx context.Context, userID string) (int, error) {
	parsedUserID, err := uuid.Parse(userID)
	if err != nil {
		return 0, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	revoked, err := r.q.RevokeAllRefreshTokensForUser(ctx, parsedUserID)
	if err != nil {
		return 0, fmt.Errorf("repository: revoke all refresh tokens for user: %w", err)
	}
	return int(revoked), nil
}

// DeleteExpired removes one batch of unusable refresh-token rows.
func (r *postgresRefreshTokenRepository) DeleteExpired(ctx context.Context, retention time.Duration, batchSize int) (int, error) {
	if batchSize <= 0 {
		return 0, fmt.Errorf("repository: refresh token sweep batch size must be positive: %w", apperror.ErrInvalidInput)
	}

	deleted, err := r.q.DeleteExpiredRefreshTokens(ctx, sqlcgen.DeleteExpiredRefreshTokensParams{
		ExpiredBefore: toTimestamptz(time.Now().UTC().Add(-retention)),
		BatchSize:     int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete expired refresh tokens: %w", err)
	}
	return int(deleted), nil
}

func refreshTokenFromRow(row sqlcgen.AuthRefreshToken) RefreshToken {
	return RefreshToken{
		ID:         row.ID.String(),
		UserID:     row.UserID.String(),
		TokenHash:  row.TokenHash,
		IssuedAt:   timestamptzOrZero(row.IssuedAt),
		ExpiresAt:  timestamptzOrZero(row.ExpiresAt),
		RevokedAt:  timePtrOrNil(row.RevokedAt),
		ReplacedBy: uuidPtrOrNil(row.ReplacedBy),
	}
}
