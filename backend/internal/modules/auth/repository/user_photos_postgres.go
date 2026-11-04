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

// UserPhoto is the one stored JPEG for a user (plan 2.1).
type UserPhoto struct {
	JPEG          []byte
	Etag          string
	Width, Height int
}

// UserPhotoRepository stores users' photos, apart from auth.users so that
// ordinary user reads never load image bytes.
type UserPhotoRepository interface {
	Upsert(ctx context.Context, userID string, photo UserPhoto) error
	// Get returns apperror.ErrNotFound (wrapped) when there is no photo.
	Get(ctx context.Context, userID string) (UserPhoto, error)
	// Etag is the same without the bytes.
	Etag(ctx context.Context, userID string) (string, error)
	Delete(ctx context.Context, userID string) error
}

type postgresUserPhotoRepository struct{ q *sqlcgen.Queries }

// NewUserPhotoRepository constructs a UserPhotoRepository backed by pool.
func NewUserPhotoRepository(pool *pgxpool.Pool) UserPhotoRepository {
	return &postgresUserPhotoRepository{q: sqlcgen.New(pool)}
}

func (r *postgresUserPhotoRepository) Upsert(ctx context.Context, userID string, p UserPhoto) error {
	user, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	if err := r.q.UpsertUserPhoto(ctx, sqlcgen.UpsertUserPhotoParams{
		UserID: user, Jpeg: p.JPEG, Etag: p.Etag,
		Width: int32(p.Width), Height: int32(p.Height), Bytes: int32(len(p.JPEG)),
	}); err != nil {
		return fmt.Errorf("repository: store user photo: %w", err)
	}
	return nil
}

func (r *postgresUserPhotoRepository) Get(ctx context.Context, userID string) (UserPhoto, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return UserPhoto{}, fmt.Errorf("repository: no photo for %q: %w", userID, apperror.ErrNotFound)
	}
	row, err := r.q.GetUserPhoto(ctx, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return UserPhoto{}, fmt.Errorf("repository: no photo: %w", apperror.ErrNotFound)
	}
	if err != nil {
		return UserPhoto{}, fmt.Errorf("repository: read user photo: %w", err)
	}
	return UserPhoto{JPEG: row.Jpeg, Etag: row.Etag}, nil
}

func (r *postgresUserPhotoRepository) Etag(ctx context.Context, userID string) (string, error) {
	user, err := uuid.Parse(userID)
	if err != nil {
		return "", fmt.Errorf("repository: no photo for %q: %w", userID, apperror.ErrNotFound)
	}
	etag, err := r.q.GetUserPhotoEtag(ctx, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("repository: no photo: %w", apperror.ErrNotFound)
	}
	if err != nil {
		return "", fmt.Errorf("repository: read user photo etag: %w", err)
	}
	return etag, nil
}

func (r *postgresUserPhotoRepository) Delete(ctx context.Context, userID string) error {
	user, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	if err := r.q.DeleteUserPhoto(ctx, user); err != nil {
		return fmt.Errorf("repository: delete user photo: %w", err)
	}
	return nil
}
