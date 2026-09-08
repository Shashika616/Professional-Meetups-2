package repository

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

type postgresDeviceTokenRepository struct {
	q *sqlcgen.Queries
}

// NewDeviceTokenRepository constructs a DeviceTokenRepository backed by
// pool.
func NewDeviceTokenRepository(pool *pgxpool.Pool) DeviceTokenRepository {
	return &postgresDeviceTokenRepository{q: sqlcgen.New(pool)}
}

func (r *postgresDeviceTokenRepository) Upsert(ctx context.Context, userID, fcmToken string) error {
	user, err := parseUUID(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	if _, err := r.q.UpsertDeviceToken(ctx, sqlcgen.UpsertDeviceTokenParams{UserID: user, FcmToken: fcmToken}); err != nil {
		return fmt.Errorf("repository: upsert device token: %w", err)
	}
	return nil
}

func (r *postgresDeviceTokenRepository) ListForUser(ctx context.Context, userID string) ([]string, error) {
	user, err := parseUUID(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListDeviceTokensForUser(ctx, user)
	if err != nil {
		return nil, fmt.Errorf("repository: list device tokens for user: %w", err)
	}
	tokens := make([]string, 0, len(rows))
	for _, row := range rows {
		tokens = append(tokens, row.FcmToken)
	}
	return tokens, nil
}

// DeleteToken removes one dead device token. See the query's comment for
// why this is keyed by token rather than by user.
func (r *postgresDeviceTokenRepository) DeleteToken(ctx context.Context, fcmToken string) error {
	if err := r.q.DeleteDeviceToken(ctx, fcmToken); err != nil {
		// The token is deliberately absent from this error: it would end up
		// in a log line, and a device token is a bearer credential for
		// pushing to someone's phone.
		return fmt.Errorf("repository: delete device token: %w", err)
	}
	return nil
}

func (r *postgresDeviceTokenRepository) ListForUsers(ctx context.Context, userIDs []string) (map[string][]string, error) {
	if len(userIDs) == 0 {
		return map[string][]string{}, nil
	}
	parsed := make([]uuid.UUID, 0, len(userIDs))
	for _, userID := range userIDs {
		user, err := parseUUID(userID)
		if err != nil {
			return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
		}
		parsed = append(parsed, user)
	}

	rows, err := r.q.ListDeviceTokensForUsers(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list device tokens for users: %w", err)
	}
	tokensByUser := make(map[string][]string, len(userIDs))
	for _, row := range rows {
		userID := row.UserID.String()
		tokensByUser[userID] = append(tokensByUser[userID], row.FcmToken)
	}
	return tokensByUser, nil
}
