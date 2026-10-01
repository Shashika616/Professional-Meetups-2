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
	// onDeleted, when set, wakes the user-deleted outbox poller after a
	// deletion commits, so the other modules hear about it immediately
	// rather than at the poller's next tick. Optional: without it delivery
	// is only delayed, never lost — the row is already durable.
	onDeleted func()
}

// SetDeletedNotifier wires the poller wake-up. A setter rather than a
// constructor argument because the poller is built after this repository and
// needs the store this package provides; see cmd/monolith.
func SetDeletedNotifier(repo UserRepository, wake func()) {
	if r, ok := repo.(*postgresUserRepository); ok {
		r.onDeleted = wake
	}
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
		IsGuest:            u.IsGuest,
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

// lockUserForTrustLevelWrite is the read half of every trust-level write
// (gap-tracker #17): it takes a row lock inside tx and returns the locked
// row as a mutable snapshot.
//
// Callers apply their own pending field write to that snapshot before
// handing it to recomputeTrustLevel, so the computed level accounts for
// every change the statement is ABOUT to make and not merely what is
// already committed — the same reasoning behind afterVerification's
// is_guest handling in the service layer.
//
// The lock is held until the enclosing transaction commits, which is what
// serialises two concurrent verification steps for the same user: the
// second either sees the first's write or waits for it.
func lockUserForTrustLevelWrite(ctx context.Context, qtx *sqlcgen.Queries, userID string, parsed uuid.UUID, what string) (User, error) {
	row, err := qtx.GetUserByIDForUpdate(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user %q: %w", userID, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: lock user for %s: %w", what, err)
	}
	return userFromRow(row), nil
}

func (r *postgresUserRepository) UpdatePhoneNumber(ctx context.Context, userID, phoneNumber string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-phone-number transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "phone number update")
	if err != nil {
		return User{}, err
	}
	locked.PhoneNumber = phoneNumber
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserPhoneNumber(ctx, sqlcgen.UpdateUserPhoneNumberParams{
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

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-phone-number transaction: %w", err)
	}
	updated := userFromRow(row)

	// After the commit, never inside the transaction (ADR-001 §4).
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

func (r *postgresUserRepository) UpdatePersonalEmail(ctx context.Context, userID, personalEmail string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-personal-email transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "personal email update")
	if err != nil {
		return User{}, err
	}
	locked.PersonalEmail = personalEmail
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserPersonalEmail(ctx, sqlcgen.UpdateUserPersonalEmailParams{
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

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-personal-email transaction: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdatePersonalDetails(ctx context.Context, userID, legalName, address string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-personal-details transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "personal details update")
	if err != nil {
		return User{}, err
	}
	locked.LegalName = legalName
	locked.Address = address
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserPersonalDetails(ctx, sqlcgen.UpdateUserPersonalDetailsParams{
		ID:         parsed,
		LegalName:  textOrNull(legalName),
		Address:    textOrNull(address),
		TrustLevel: int16(trustLevel),
	})
	if err != nil {
		return User{}, fmt.Errorf("repository: update user personal details: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-personal-details transaction: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateLinkedInSub(ctx context.Context, userID, linkedInSub string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-linkedin-sub transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "linkedin sub update")
	if err != nil {
		return User{}, err
	}
	locked.LinkedInSub = linkedInSub
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserLinkedInSub(ctx, sqlcgen.UpdateUserLinkedInSubParams{
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

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-linkedin-sub transaction: %w", err)
	}
	updated := userFromRow(row)

	// LinkedIn linking changes trust_level too — the same real
	// profile-affecting change the meetup module's display cache needs to
	// hear about, so it publishes here as well as from the verification
	// paths.
	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) ClearGuestFlag(ctx context.Context, userID string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin clear-guest-flag transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	// Sets nothing extra on the snapshot: is_guest is the only field this
	// statement writes, and the caller's own afterVerification applies it.
	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "clear guest flag")
	if err != nil {
		return User{}, err
	}
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.ClearUserGuestFlag(ctx, sqlcgen.ClearUserGuestFlagParams{
		ID:         parsed,
		TrustLevel: int16(trustLevel),
	})
	if err != nil {
		return User{}, fmt.Errorf("repository: clear user guest flag: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit clear-guest-flag transaction: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateWorkEmailVerified(ctx context.Context, userID, companyDomain string, verified bool, verifiedAt time.Time, workEmailHash, companyName string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-work-email-verified transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	locked, err := lockUserForTrustLevelWrite(ctx, qtx, userID, parsed, "work email verification")
	if err != nil {
		return User{}, err
	}
	locked.CompanyDomain = companyDomain
	locked.WorkEmailVerified = verified
	locked.CompanyName = companyName
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserWorkEmailVerified(ctx, sqlcgen.UpdateUserWorkEmailVerifiedParams{
		ID:                  parsed,
		CompanyDomain:       textOrNull(companyDomain),
		WorkEmailVerified:   verified,
		WorkEmailVerifiedAt: toTimestamptz(verifiedAt),
		WorkEmailHash:       textOrNull(workEmailHash),
		TrustLevel:          int16(trustLevel),
		CompanyName:         textOrNull(companyName),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return User{}, fmt.Errorf("repository: work email hash already claimed by a different account: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user work email verified: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-work-email-verified transaction: %w", err)
	}
	updated := userFromRow(row)

	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}

func (r *postgresUserRepository) UpdateProfilePhoto(ctx context.Context, userID, photoURL string) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	row, err := r.q.UpdateUserProfilePhoto(ctx, sqlcgen.UpdateUserProfilePhotoParams{
		ID:              parsed,
		ProfilePhotoUrl: textOrNull(photoURL),
	})
	if err != nil {
		return User{}, fmt.Errorf("repository: update user profile photo: %w", err)
	}
	updated := userFromRow(row)

	// Same as UpdateFullName: the meetup module caches the display name and
	// photo for meetup cards, so a change here has to reach it.
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

func (r *postgresUserRepository) UpsertMeetupsCompletedCache(ctx context.Context, userID string, meetupsCompleted int, occurredAt time.Time) (bool, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	rowsAffected, err := r.q.UpsertUserMeetupsCompletedCache(ctx, sqlcgen.UpsertUserMeetupsCompletedCacheParams{
		MeetupsCompleted: int32(meetupsCompleted),
		OccurredAt:       toTimestamptz(occurredAt),
		UserID:           parsed,
	})
	if err != nil {
		return false, fmt.Errorf("repository: upsert meetups-completed cache: %w", err)
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

		IsGuest:     row.IsGuest,
		CompanyName: textOrEmpty(row.CompanyName),

		RatingAverage: numericToFloat64(row.RatingAverage),
		RatingCount:   int(row.RatingCount),

		MeetupsCompleted: int(row.MeetupsCompleted),

		LastLocationLat:       float8PtrOrNil(row.LastLocationLat),
		LastLocationLng:       float8PtrOrNil(row.LastLocationLng),
		LastLocationUpdatedAt: timePtrOrNil(row.LastLocationUpdatedAt),
	}
}

func (r *postgresUserRepository) DeleteAbandonedGuests(ctx context.Context, retention time.Duration, batchSize int) (int, error) {
	if batchSize <= 0 {
		return 0, fmt.Errorf("repository: guest cleanup batch size must be positive: %w", apperror.ErrInvalidInput)
	}

	deleted, err := r.q.DeleteAbandonedGuests(ctx, sqlcgen.DeleteAbandonedGuestsParams{
		AbandonedBefore: toTimestamptz(time.Now().UTC().Add(-retention)),
		BatchSize:       int32(batchSize),
	})
	if err != nil {
		return 0, fmt.Errorf("repository: delete abandoned guests: %w", err)
	}
	// Same wake-up as an ordinary deletion: the other modules should hear
	// about it now, not at the poller's next tick.
	if deleted > 0 && r.onDeleted != nil {
		r.onDeleted()
	}
	return int(deleted), nil
}

// SafetyHoldPeriod is how long a deleted account's SOS record is held before
// it is purged. 90 days follows Tinder's published three-month safety window
// for closed accounts; it is a policy choice rather than a legal minimum, and
// the privacy policy must state it. Changing it changes only holds created
// afterwards; existing rows keep the purge_after they were given.
const SafetyHoldPeriod = 90 * 24 * time.Hour

func (r *postgresUserRepository) Delete(ctx context.Context, userID string) error {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	// One transaction for the whole auth side, so the account and the data
	// hanging off it disappear together or not at all. trusted_contacts and
	// sos_events have no FK to users (a deliberate logical FK, per
	// 0001_auth_schema's header), so the cascade does not reach them; they
	// are deleted explicitly and first. Every statement is a single-user
	// indexed delete, so the transaction holds a handful of row locks for
	// milliseconds and blocks nobody else.
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("repository: begin delete transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	if err := q.DeleteTrustedContactsForUser(ctx, parsed); err != nil {
		return fmt.Errorf("repository: delete trusted contacts: %w", err)
	}
	// The one thing kept: if this account ever triggered SOS, a minimal
	// record (who, and the events) goes into a safety hold that purges itself
	// after SafetyHoldPeriod. It must be copied BEFORE the live SOS rows are
	// deleted below, and in this same transaction, so there is no moment at
	// which the events are gone and the hold is not yet written. An account
	// with no SOS events produces no hold at all. See 0016_safety_holds.
	if _, err := q.CreateSafetyHoldForDeletedUser(ctx, sqlcgen.CreateSafetyHoldForDeletedUserParams{
		HoldFor: pgtype.Interval{Microseconds: SafetyHoldPeriod.Microseconds(), Valid: true},
		UserID:  parsed,
	}); err != nil {
		return fmt.Errorf("repository: create safety hold: %w", err)
	}
	if err := q.DeleteSOSEventsForUser(ctx, parsed); err != nil {
		return fmt.Errorf("repository: delete sos events: %w", err)
	}
	deleted, err := q.DeleteUser(ctx, parsed)
	if err != nil {
		return fmt.Errorf("repository: delete user: %w", err)
	}
	// Zero rows means someone else deleted this account first (two devices,
	// or a retry). Report it rather than carrying on: continuing would commit
	// a SECOND user-deleted event for an account that was already announced.
	// The rollback deferred above undoes the contact and SOS deletes too,
	// which were no-ops for the same reason.
	if deleted == 0 {
		return fmt.Errorf("repository: user %s: %w", userID, apperror.ErrNotFound)
	}
	// Announce it in the SAME transaction. Other modules keep their own
	// copies of this person (the meetup module's display cache holds their
	// name and photograph) and must be told; a row written here commits or
	// rolls back with the delete itself, so there is no outcome in which the
	// account is gone and nobody will ever hear about it. The outbox poller
	// delivers it, with retries, after commit.
	if err := q.EnqueueUserDeleted(ctx, parsed); err != nil {
		return fmt.Errorf("repository: enqueue user-deleted: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("repository: commit delete: %w: %w", apperror.ErrInternal, err)
	}
	// Not user-profile-updated: that event UPSERTs the meetup module's display
	// cache, so publishing it for a deleted user would put back the very name
	// and photo the user-deleted event is about to remove.
	if r.onDeleted != nil {
		r.onDeleted()
	}
	return nil
}

func (r *postgresUserRepository) DeleteExpiredSafetyHolds(ctx context.Context, batchSize int) (int, error) {
	n, err := r.q.DeleteExpiredSafetyHolds(ctx, int32(batchSize))
	if err != nil {
		return 0, fmt.Errorf("repository: delete expired safety holds: %w", err)
	}
	return int(n), nil
}
