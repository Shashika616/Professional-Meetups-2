package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// postgresUserRepository implements UserRepository against Postgres via
// pgx/sqlc.
//
// Ported from ../Professional-Meetups/backend/services/auth/internal/
// repository/users_postgres.go with one structural change (ADR-001 §4): every
// method that changes a name/photo/trust-level field used to open a
// transaction so it could write a user-profile-updated (or, for Create, a
// user-onboarded) row into outbox_events atomically with its business write,
// for a relay process to publish later. There is no outbox_events table here
// and no relay — so each method is now a single statement followed by a
// synchronous bus.Publish in the same call.
//
// The publish deliberately happens AFTER the write returns, not inside a
// transaction around it, and its failure is logged rather than propagated —
// both straight from ADR-001 §4 ("commit the business write, then call
// bus.Publish synchronously in the same request... a failed in-process
// handler must not roll back or fail the original request"). Publishing
// inside an open transaction would be actively wrong here: an in-process
// handler runs immediately and would read a row its own caller hasn't
// committed yet.
type postgresUserRepository struct {
	pool   *pgxpool.Pool
	q      *sqlcgen.Queries
	bus    eventbus.Bus
	logger *slog.Logger
}

// NewUserRepository constructs a UserRepository backed by pool, publishing
// its profile/onboarding/location events on bus.
func NewUserRepository(pool *pgxpool.Pool, bus eventbus.Bus, logger *slog.Logger) UserRepository {
	if logger == nil {
		logger = slog.Default()
	}
	return &postgresUserRepository{pool: pool, q: sqlcgen.New(pool), bus: bus, logger: logger}
}

func (r *postgresUserRepository) GetByLinkedInSub(ctx context.Context, linkedInSub string) (User, error) {
	row, err := r.q.GetUserByLinkedInSub(ctx, textOrNull(linkedInSub))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user with linkedin_sub %q: %w", linkedInSub, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: get user by linkedin_sub: %w", err)
	}
	return userFromRow(row), nil
}

func (r *postgresUserRepository) GetByID(ctx context.Context, id string) (User, error) {
	parsed, err := uuid.Parse(id)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", id, apperror.ErrInvalidInput)
	}

	row, err := r.q.GetUserByID(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user %q: %w", id, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: get user by id: %w", err)
	}
	return userFromRow(row), nil
}

func (r *postgresUserRepository) GetByPersonalEmail(ctx context.Context, email string) (User, error) {
	row, err := r.q.GetUserByPersonalEmail(ctx, textOrNull(email))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user with personal_email %q: %w", email, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: get user by personal_email: %w", err)
	}
	return userFromRow(row), nil
}

func (r *postgresUserRepository) GetByWorkEmailHash(ctx context.Context, workEmailHash string) (User, error) {
	row, err := r.q.GetUserByWorkEmailHash(ctx, textOrNull(workEmailHash))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user with work_email_hash %q: %w", workEmailHash, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: get user by work_email_hash: %w", err)
	}
	return userFromRow(row), nil
}

// publishProfileUpdated publishes user-profile-updated for user — the shared
// tail every field-mutating method below calls right after its business
// write succeeds, so the payload shape and ordering stay defined in exactly
// one place (the same role the outbox-writing helper played in the source).
func (r *postgresUserRepository) publishProfileUpdated(ctx context.Context, user User) {
	if err := r.bus.Publish(ctx, eventbus.TopicUserProfileUpdated, eventbus.UserProfileUpdatedPayload{
		UserID:          user.ID,
		FullName:        user.FullName,
		ProfilePhotoURL: user.ProfilePhotoURL,
		TrustLevel:      user.TrustLevel,
		OccurredAt:      time.Now().UTC(),
	}); err != nil {
		r.logger.Error("publish user-profile-updated", "user_id", user.ID, "error", err)
	}
}

func (r *postgresUserRepository) Create(ctx context.Context, u NewUser) (User, error) {
	row, err := r.q.CreateUser(ctx, sqlcgen.CreateUserParams{
		LinkedinSub:        textOrNull(u.LinkedInSub),
		FullName:           u.FullName,
		ProfilePhotoUrl:    textOrNull(u.ProfilePhotoURL),
		Headline:           textOrNull(u.Headline),
		TrustLevel:         int16(u.TrustLevel),
		AgeConfirmedOver18: u.AgeConfirmedOver18,
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: user with linkedin_sub %q already exists: %w", u.LinkedInSub, apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: create user: %w", err)
	}
	created := userFromRow(row)

	// user-onboarded — Create is only ever called to make a genuinely new
	// account (never for an existing one, see ResolveOrCreateIdentity), so
	// publishing unconditionally here is correct without an isNewUser check
	// at the call site.
	if err := r.bus.Publish(ctx, eventbus.TopicUserOnboarded, eventbus.UserOnboardedPayload{
		UserID:          created.ID,
		FullName:        created.FullName,
		ProfilePhotoURL: created.ProfilePhotoURL,
		TrustLevel:      created.TrustLevel,
		OccurredAt:      time.Now().UTC(),
	}); err != nil {
		r.logger.Error("publish user-onboarded", "user_id", created.ID, "error", err)
	}

	return created, nil
}

func (r *postgresUserRepository) UpdatePhoneNumber(ctx context.Context, userID, phoneNumber string, trustLevel int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserPhoneNumber(ctx, sqlcgen.UpdateUserPhoneNumberParams{
		ID:          parsed,
		PhoneNumber: textOrNull(phoneNumber),
		TrustLevel:  int16(trustLevel),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: phone number already verified on a different account: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user phone number: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

// UpdateLastKnownLocation — the browse screen's on-demand location read,
// exactly one call site (an authenticated RPC, no trust-level recompute).
// Publishes user-location-updated right after the write, same shape as every
// other user-mutating method here.
func (r *postgresUserRepository) UpdateLastKnownLocation(ctx context.Context, userID string, lat, lng float64) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserLastKnownLocation(ctx, sqlcgen.UpdateUserLastKnownLocationParams{
		ID:              parsed,
		LastLocationLat: pgtype.Float8{Float64: lat, Valid: true},
		LastLocationLng: pgtype.Float8{Float64: lng, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user %s: %w", userID, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: update last known location: %w", err)
	}
	updated := userFromRow(row)

	if err := r.bus.Publish(ctx, eventbus.TopicUserLocationUpdated, eventbus.UserLocationUpdatedPayload{
		UserID:     updated.ID,
		Lat:        lat,
		Lng:        lng,
		OccurredAt: time.Now().UTC(),
	}); err != nil {
		r.logger.Error("publish user-location-updated", "user_id", updated.ID, "error", err)
	}

	return updated, nil
}

func (r *postgresUserRepository) UpdatePersonalEmail(ctx context.Context, userID, personalEmail string, trustLevel int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserPersonalEmail(ctx, sqlcgen.UpdateUserPersonalEmailParams{
		ID:            parsed,
		PersonalEmail: textOrNull(personalEmail),
		TrustLevel:    int16(trustLevel),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: personal email already verified on a different account: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user personal email: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdatePersonalDetails(ctx context.Context, userID, legalName, address string, trustLevel int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserPersonalDetails(ctx, sqlcgen.UpdateUserPersonalDetailsParams{
		ID:         parsed,
		LegalName:  textOrNull(legalName),
		Address:    textOrNull(address),
		TrustLevel: int16(trustLevel),
	})
	if err != nil {
		return User{}, fmt.Errorf("repository: update user personal details: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateLinkedInSub(ctx context.Context, userID, linkedInSub string, trustLevel int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserLinkedInSub(ctx, sqlcgen.UpdateUserLinkedInSubParams{
		ID:          parsed,
		LinkedinSub: textOrNull(linkedInSub),
		TrustLevel:  int16(trustLevel),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: linkedin account already linked to a different user: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user linkedin sub: %w", err)
	}
	updated := userFromRow(row)

	// LinkedIn linking changes trust_level too — the same real
	// profile-affecting change the meetup module's display cache needs to
	// hear about, so it publishes here as well as from the verification
	// paths.
	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateWorkEmailVerified(ctx context.Context, userID, companyDomain string, verified bool, verifiedAt time.Time, workEmailHash string, trustLevel int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserWorkEmailVerified(ctx, sqlcgen.UpdateUserWorkEmailVerifiedParams{
		ID:                  parsed,
		CompanyDomain:       textOrNull(companyDomain),
		WorkEmailVerified:   verified,
		WorkEmailVerifiedAt: toTimestamptz(verifiedAt),
		WorkEmailHash:       textOrNull(workEmailHash),
		TrustLevel:          int16(trustLevel),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: work email hash already claimed by a different account: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user work email verified: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateFullName(ctx context.Context, userID, fullName string) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserFullName(ctx, sqlcgen.UpdateUserFullNameParams{
		ID:       parsed,
		FullName: fullName,
	})
	if err != nil {
		return User{}, fmt.Errorf("repository: update user full name: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpsertRatingCache(ctx context.Context, userID string, ratingAverage float64, ratingCount int, occurredAt time.Time) (bool, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rowsAffected, err := r.q.UpsertUserRatingCache(ctx, sqlcgen.UpsertUserRatingCacheParams{
		RatingAverage: float64ToNumeric(ratingAverage),
		RatingCount:   int32(ratingCount),
		OccurredAt:    toTimestamptz(occurredAt),
		UserID:        parsed,
	})
	if err != nil {
		return false, fmt.Errorf("repository: upsert rating cache: %w", err)
	}
	return rowsAffected > 0, nil
}

func userFromRow(row sqlcgen.AuthUser) User {
	return User{
		ID:              row.ID.String(),
		LinkedInSub:     textOrEmpty(row.LinkedinSub),
		FullName:        row.FullName,
		ProfilePhotoURL: textOrEmpty(row.ProfilePhotoUrl),
		Headline:        textOrEmpty(row.Headline),
		TrustLevel:      int(row.TrustLevel),
		AccountStatus:   AccountStatus(row.AccountStatus),
		CreatedAt:       timestamptzOrZero(row.CreatedAt),
		UpdatedAt:       timestamptzOrZero(row.UpdatedAt),

		PhoneNumber:         textOrEmpty(row.PhoneNumber),
		PersonalEmail:       textOrEmpty(row.PersonalEmail),
		LegalName:           textOrEmpty(row.LegalName),
		Address:             textOrEmpty(row.Address),
		CompanyDomain:       textOrEmpty(row.CompanyDomain),
		WorkEmailVerified:   row.WorkEmailVerified,
		WorkEmailVerifiedAt: timePtrOrNil(row.WorkEmailVerifiedAt),

		AgeConfirmedOver18: row.AgeConfirmedOver18,
		AgeConfirmedAt:     timePtrOrNil(row.AgeConfirmedAt),
		WorkEmailHash:      textOrEmpty(row.WorkEmailHash),

		RatingAverage: numericToFloat64(row.RatingAverage),
		RatingCount:   int(row.RatingCount),

		LastLocationLat:       float8PtrOrNil(row.LastLocationLat),
		LastLocationLng:       float8PtrOrNil(row.LastLocationLng),
		LastLocationUpdatedAt: timePtrOrNil(row.LastLocationUpdatedAt),
	}
}
