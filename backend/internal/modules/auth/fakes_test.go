package auth

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// fakeIdentityProvider stands in for AppleProvider/GoogleProvider — a fixed
// VerifiedIdentity per valid id_token string, or an error for anything else.
// Real signature/issuer/audience/expiry/NONCE verification is
// internal/modules/auth/identity's own concern (identity_test.go); this fake
// is only about exercising CompleteFederatedSignup's account-creation/login
// branching without a real JWKS round trip.
//
// It does reproduce two nonce behaviors, because the module's own callers
// have to get them right and a fake that ignored the parameter would hide
// that: an empty expectedNonce always fails (the check must not be
// skippable), and a token registered in requiredNonces only verifies when
// the caller presents that exact nonce.
type fakeIdentityProvider struct {
	validTokens map[string]identity.VerifiedIdentity
	// requiredNonces optionally pins the nonce a given id_token was minted
	// for; a token absent from this map accepts any non-empty nonce.
	requiredNonces map[string]string
	err            error
}

func (f *fakeIdentityProvider) Verify(_ context.Context, idToken, expectedNonce string) (identity.VerifiedIdentity, error) {
	if f.err != nil {
		return identity.VerifiedIdentity{}, f.err
	}
	if expectedNonce == "" {
		return identity.VerifiedIdentity{}, fmt.Errorf("fake: sign-in nonce is required")
	}
	v, ok := f.validTokens[idToken]
	if !ok {
		return identity.VerifiedIdentity{}, fmt.Errorf("fake: invalid id_token")
	}
	if want, pinned := f.requiredNonces[idToken]; pinned && want != expectedNonce {
		return identity.VerifiedIdentity{}, fmt.Errorf("fake: id_token nonce does not match this sign-in attempt")
	}
	return v, nil
}

type fakeUserRepository struct {
	byLinkedInSub map[string]repository.User
	byID          map[string]repository.User
	createErr     error
	createCalls   []repository.NewUser
	// photoUpdates records every profile-photo write, so a test can assert
	// that an UNCHANGED LinkedIn photo produces no write at all rather than
	// a redundant one (which would publish a pointless
	// user-profile-updated event to the meetup module's cache).
	photoUpdates []string
	// deleted records ids passed to Delete, so a test can assert the auth
	// row was removed — and that it was NOT removed when the meetup purge
	// refused or failed first.
	deleted []string
	// deleteErr, when set, is returned by Delete instead of deleting.
	deleteErr error
	// expiredHolds is what DeleteExpiredSafetyHolds reports removing.
	expiredHolds int
	nextID       int
	// ratingCacheUpdatedAt tracks the last-applied event timestamp per
	// user, mirroring the real rating_updated_at column — UpsertRatingCache
	// uses this to reproduce the ordering guard in tests.
	// hasRefreshToken stands in for the real anti-join against
	// auth.refresh_tokens — this fake owns no tokens, so a test seeds which
	// users still hold one.
	hasRefreshToken      map[string]bool
	ratingCacheUpdatedAt map[string]time.Time
	// meetupsCompletedUpdatedAt is the same thing for the meetups-completed
	// cache, mirroring meetups_completed_updated_at.
	meetupsCompletedUpdatedAt map[string]time.Time
}

func newFakeUserRepository() *fakeUserRepository {
	return &fakeUserRepository{
		byLinkedInSub:   map[string]repository.User{},
		byID:            map[string]repository.User{},
		hasRefreshToken: map[string]bool{},
	}
}

func (f *fakeUserRepository) GetByLinkedInSub(_ context.Context, linkedInSub string) (repository.User, error) {
	u, ok := f.byLinkedInSub[linkedInSub]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return u, nil
}

func (f *fakeUserRepository) GetByID(_ context.Context, id string) (repository.User, error) {
	u, ok := f.byID[id]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return u, nil
}

// GetByPersonalEmail linear-scans byID — fine at fake-repository/test
// scale, mirrors GetUserByPersonalEmail's real "personal_email presence IS
// verified" semantics with no separate boolean to check.
func (f *fakeUserRepository) GetByPersonalEmail(_ context.Context, email string) (repository.User, error) {
	for _, u := range f.byID {
		if u.PersonalEmail == email {
			return u, nil
		}
	}
	return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
}

// GetByWorkEmailHash linear-scans byID, mirroring GetByPersonalEmail's fake
// — fine at test scale, exercises the same "does any OTHER user already
// hold this hash" check VerifyCorporateEmailCode's reuse-abuse logic
// (ADR-019 §3) relies on.
func (f *fakeUserRepository) GetByWorkEmailHash(_ context.Context, workEmailHash string) (repository.User, error) {
	for _, u := range f.byID {
		if u.WorkEmailHash != "" && u.WorkEmailHash == workEmailHash {
			return u, nil
		}
	}
	return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
}

func (f *fakeUserRepository) UpdateFullName(_ context.Context, userID, fullName string) (repository.User, error) {
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.FullName = fullName
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) Delete(_ context.Context, userID string) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	if _, ok := f.byID[userID]; !ok {
		return fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	delete(f.byID, userID)
	f.deleted = append(f.deleted, userID)
	return nil
}

func (f *fakeUserRepository) DeleteExpiredSafetyHolds(_ context.Context, _ int) (int, error) {
	return f.expiredHolds, nil
}

func (f *fakeUserRepository) UpdateProfilePhoto(_ context.Context, userID, photoURL string) (repository.User, error) {
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.ProfilePhotoURL = photoURL
	f.photoUpdates = append(f.photoUpdates, photoURL)
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) Create(_ context.Context, u repository.NewUser) (repository.User, error) {
	if f.createErr != nil {
		return repository.User{}, f.createErr
	}
	// Mirrors migration 0017's partial unique index on
	// lower(personal_email): a second account cannot take an address the
	// first one already holds, and the comparison is case-insensitive
	// because that is what the index does. Without this the fake would
	// happily create the duplicates the whole claim flow exists to prevent,
	// and every test above it would be asserting against a database that
	// does not behave like the real one. The empty address is exempt, the
	// same way NULL is exempt from a partial index.
	if u.PersonalEmail != "" {
		for _, existing := range f.byID {
			if strings.EqualFold(existing.PersonalEmail, u.PersonalEmail) {
				return repository.User{}, fmt.Errorf("fake: an account already uses this email address: %w", apperror.ErrConflict)
			}
		}
	}
	f.createCalls = append(f.createCalls, u)
	f.nextID++
	created := repository.User{
		ID:                 fmt.Sprintf("user-%d", f.nextID),
		LinkedInSub:        u.LinkedInSub,
		FullName:           u.FullName,
		ProfilePhotoURL:    u.ProfilePhotoURL,
		TrustLevel:         u.TrustLevel,
		AccountStatus:      repository.AccountStatusActive,
		AgeConfirmedOver18: u.AgeConfirmedOver18,
		IsGuest:            u.IsGuest,
		PersonalEmail:      u.PersonalEmail,
	}
	// Mirrors the real CreateUser query: age_confirmed_at is set only when
	// age_confirmed_over_18 is true, never backdated, never set for false.
	if u.AgeConfirmedOver18 {
		now := time.Now()
		created.AgeConfirmedAt = &now
	}
	f.byLinkedInSub[u.LinkedInSub] = created
	f.byID[created.ID] = created
	return created, nil
}

// # THE recomputeTrustLevel CALLBACK IN THE FAKE (gap-tracker #17)
//
// Each of the six trust-level writers below applies its own field(s) to the
// fake's CURRENT stored row and then calls the caller's callback with that
// row, exactly as the Postgres implementations do against the row they hold
// a FOR UPDATE lock on. That is what makes the existing service-layer tests
// genuinely exercise the new closures rather than merely recompile.
//
// What this fake CANNOT prove: that the real row lock serialises concurrent
// transactions. There is no concurrency here to serialise. The tests below
// prove the recompute-from-current-state logic; only a real Postgres
// integration test could prove the locking.
//
// UpdatePhoneNumber/UpdatePersonalEmail simulate migration 0002's UNIQUE
// constraint — a linear scan for a conflicting value on a different user is
// fine at fake-repository scale and is what lets
// TestVerifyPhoneCode_ConflictOnAlreadyVerifiedNumber (etc) exercise the
// same race-condition mapping the real Postgres repository provides via
// pgErr.Code == "23505".
func (f *fakeUserRepository) UpdatePhoneNumber(_ context.Context, userID, phoneNumber string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	for id, u := range f.byID {
		if id != userID && u.PhoneNumber == phoneNumber {
			return repository.User{}, fmt.Errorf("fake: phone number already verified on a different account: %w", apperror.ErrConflict)
		}
	}
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.PhoneNumber = phoneNumber
	// Mirrors the real repository: the field is applied to the CURRENT row
	// first, then the trust level is computed from that — never handed in
	// precomputed from a snapshot the caller read earlier.
	u.TrustLevel = recomputeTrustLevel(u)
	// Mirrors the SQL: every verification-recording UPDATE clears is_guest.
	u.IsGuest = false
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) UpdatePersonalEmail(_ context.Context, userID, personalEmail string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	for id, u := range f.byID {
		if id != userID && u.PersonalEmail == personalEmail {
			return repository.User{}, fmt.Errorf("fake: personal email already verified on a different account: %w", apperror.ErrConflict)
		}
	}
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.PersonalEmail = personalEmail
	u.TrustLevel = recomputeTrustLevel(u)
	// Mirrors the SQL: every verification-recording UPDATE clears is_guest.
	u.IsGuest = false
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) UpdatePersonalDetails(_ context.Context, userID, legalName, address string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.LegalName = legalName
	u.Address = address
	u.TrustLevel = recomputeTrustLevel(u)
	// Mirrors the SQL: every verification-recording UPDATE clears is_guest.
	u.IsGuest = false
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) ClearGuestFlag(_ context.Context, userID string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.IsGuest = false
	u.TrustLevel = recomputeTrustLevel(u)
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) UpdateWorkEmailVerified(_ context.Context, userID, companyDomain string, verified bool, verifiedAt time.Time, workEmailHash, companyName string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	for id, u := range f.byID {
		if id != userID && u.WorkEmailHash != "" && u.WorkEmailHash == workEmailHash {
			return repository.User{}, fmt.Errorf("fake: work email hash already claimed by a different account: %w", apperror.ErrConflict)
		}
	}
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.CompanyDomain = companyDomain
	u.WorkEmailVerified = verified
	u.WorkEmailVerifiedAt = &verifiedAt
	u.WorkEmailHash = workEmailHash
	// Written in the same call as work_email_verified, mirroring the real
	// query — the two halves of the Level 3 condition are never apart.
	u.CompanyName = companyName
	u.TrustLevel = recomputeTrustLevel(u)
	f.save(u)
	return u, nil
}

// UpdateLinkedInSub simulates idx_users_linkedin_sub (migration 0001) the
// same way UpdatePhoneNumber/UpdatePersonalEmail simulate their own unique
// constraints above — a linear scan for a conflicting value on a different
// user, exercising the same real-Postgres-mapped ErrConflict path.
func (f *fakeUserRepository) UpdateLinkedInSub(_ context.Context, userID, linkedInSub string, recomputeTrustLevel func(repository.User) int) (repository.User, error) {
	for id, u := range f.byID {
		if id != userID && u.LinkedInSub == linkedInSub {
			return repository.User{}, fmt.Errorf("fake: linkedin account already linked to a different user: %w", apperror.ErrConflict)
		}
	}
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	u.LinkedInSub = linkedInSub
	u.TrustLevel = recomputeTrustLevel(u)
	// Mirrors the SQL: every verification-recording UPDATE clears is_guest.
	u.IsGuest = false
	f.save(u)
	return u, nil
}

// DeleteAbandonedGuests mirrors the real anti-join in memory: a guest with
// no refresh-token row at all, untouched for longer than retention. The
// fake owns no refresh tokens, so the caller seeds hasRefreshToken to say
// which users still have one.
func (f *fakeUserRepository) DeleteAbandonedGuests(_ context.Context, retention time.Duration, batchSize int) (int, error) {
	cutoff := time.Now().UTC().Add(-retention)
	deleted := 0
	for id, u := range f.byID {
		if deleted >= batchSize {
			break
		}
		if !u.IsGuest || f.hasRefreshToken[id] || !u.UpdatedAt.Before(cutoff) {
			continue
		}
		delete(f.byID, id)
		if u.LinkedInSub != "" {
			delete(f.byLinkedInSub, u.LinkedInSub)
		}
		deleted++
	}
	return deleted, nil
}

// UpsertRatingCache mirrors the real repository's ordering guard (ADR-018
// Decision 2) — the auth-side consumer test(s) exercise this directly
// rather than needing a real Postgres to prove the guard behaves.
func (f *fakeUserRepository) UpsertRatingCache(_ context.Context, userID string, ratingAverage float64, ratingCount int, occurredAt time.Time) (bool, error) {
	u, ok := f.byID[userID]
	if !ok {
		return false, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	if f.ratingCacheUpdatedAt != nil {
		if last, ok := f.ratingCacheUpdatedAt[userID]; ok && !occurredAt.After(last) {
			return false, nil
		}
	}
	u.RatingAverage = ratingAverage
	u.RatingCount = ratingCount
	f.save(u)
	if f.ratingCacheUpdatedAt == nil {
		f.ratingCacheUpdatedAt = map[string]time.Time{}
	}
	f.ratingCacheUpdatedAt[userID] = occurredAt
	return true, nil
}

// UpsertMeetupsCompletedCache — corrected 2026-09-08 to guard on the count
// itself, not occurredAt, matching the real repository's fix (see
// UpsertUserMeetupsCompletedCache's doc comment / auth/0005's SQL): a
// completed-meetup count is monotonically non-decreasing per user, so
// comparing values is strictly safer than comparing wall-clock timestamps
// under concurrent completions for the same user.
func (f *fakeUserRepository) UpsertMeetupsCompletedCache(_ context.Context, userID string, meetupsCompleted int, occurredAt time.Time) (bool, error) {
	u, ok := f.byID[userID]
	if !ok {
		return false, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	if meetupsCompleted <= u.MeetupsCompleted {
		return false, nil
	}
	u.MeetupsCompleted = meetupsCompleted
	f.save(u)
	if f.meetupsCompletedUpdatedAt == nil {
		f.meetupsCompletedUpdatedAt = map[string]time.Time{}
	}
	f.meetupsCompletedUpdatedAt[userID] = occurredAt
	return true, nil
}

func (f *fakeUserRepository) UpdateLastKnownLocation(_ context.Context, userID string, lat, lng float64) (repository.User, error) {
	u, ok := f.byID[userID]
	if !ok {
		return repository.User{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	now := time.Now()
	u.LastLocationLat = &lat
	u.LastLocationLng = &lng
	u.LastLocationUpdatedAt = &now
	f.save(u)
	return u, nil
}

func (f *fakeUserRepository) save(u repository.User) {
	f.byID[u.ID] = u
	if u.LinkedInSub != "" {
		f.byLinkedInSub[u.LinkedInSub] = u
	}
}

// fakeUserIdentityRepository keys rows by (provider, subject), mirroring
// migration 0004's UNIQUE(provider, subject) — an Insert for an existing
// key returns ErrConflict rather than silently overwriting.
type fakeUserIdentityRepository struct {
	byProviderSubject map[string]repository.UserIdentity
	nextID            int
}

func newFakeUserIdentityRepository() *fakeUserIdentityRepository {
	return &fakeUserIdentityRepository{byProviderSubject: map[string]repository.UserIdentity{}}
}

func identityKey(provider repository.IdentityProvider, subject string) string {
	return string(provider) + "|" + subject
}

func (f *fakeUserIdentityRepository) Insert(
	_ context.Context, userID string, provider repository.IdentityProvider, subject, email string,
) (repository.UserIdentity, error) {
	key := identityKey(provider, subject)
	if _, exists := f.byProviderSubject[key]; exists {
		return repository.UserIdentity{}, fmt.Errorf("fake: %s identity already linked: %w", provider, apperror.ErrConflict)
	}
	f.nextID++
	row := repository.UserIdentity{
		ID:       fmt.Sprintf("identity-%d", f.nextID),
		UserID:   userID,
		Provider: provider,
		Subject:  subject,
		Email:    email,
		LinkedAt: time.Now(),
	}
	f.byProviderSubject[key] = row
	return row, nil
}

func (f *fakeUserIdentityRepository) GetByProviderSubject(
	_ context.Context, provider repository.IdentityProvider, subject string,
) (repository.UserIdentity, error) {
	row, ok := f.byProviderSubject[identityKey(provider, subject)]
	if !ok {
		return repository.UserIdentity{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return row, nil
}

func (f *fakeUserIdentityRepository) ListForUser(_ context.Context, userID string) ([]repository.UserIdentity, error) {
	var out []repository.UserIdentity
	for _, row := range f.byProviderSubject {
		if row.UserID == userID {
			out = append(out, row)
		}
	}
	return out, nil
}

type fakeRefreshTokenRepository struct {
	byHash       map[string]repository.RefreshToken
	byID         map[string]repository.RefreshToken
	nextID       int
	createErr    error
	rotateErr    error
	revokeAllErr error
	// revokeAllCalls records every RevokeAllForUser call, so a test can
	// assert the reuse-detection path fired for the right user — and, just
	// as importantly, that it did NOT fire on a legitimate refresh.
	revokeAllCalls []string
}

func newFakeRefreshTokenRepository() *fakeRefreshTokenRepository {
	return &fakeRefreshTokenRepository{
		byHash: map[string]repository.RefreshToken{},
		byID:   map[string]repository.RefreshToken{},
	}
}

func (f *fakeRefreshTokenRepository) Create(_ context.Context, userID, tokenHash string, expiresAt time.Time) (repository.RefreshToken, error) {
	if f.createErr != nil {
		return repository.RefreshToken{}, f.createErr
	}
	f.nextID++
	rt := repository.RefreshToken{
		ID:        fmt.Sprintf("rt-%d", f.nextID),
		UserID:    userID,
		TokenHash: tokenHash,
		IssuedAt:  time.Now(),
		ExpiresAt: expiresAt,
	}
	f.byHash[tokenHash] = rt
	f.byID[rt.ID] = rt
	return rt, nil
}

func (f *fakeRefreshTokenRepository) FindByHash(_ context.Context, tokenHash string) (repository.RefreshToken, error) {
	rt, ok := f.byHash[tokenHash]
	if !ok {
		return repository.RefreshToken{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return rt, nil
}

func (f *fakeRefreshTokenRepository) Rotate(_ context.Context, oldID, newTokenHash string, newExpiresAt time.Time) (string, error) {
	if f.rotateErr != nil {
		return "", f.rotateErr
	}
	old, ok := f.byID[oldID]
	if !ok {
		return "", fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}

	f.nextID++
	newID := fmt.Sprintf("rt-%d", f.nextID)
	newRT := repository.RefreshToken{
		ID:        newID,
		UserID:    old.UserID,
		TokenHash: newTokenHash,
		IssuedAt:  time.Now(),
		ExpiresAt: newExpiresAt,
	}

	old.ReplacedBy = &newID
	f.byID[oldID] = old
	f.byHash[old.TokenHash] = old
	f.byID[newID] = newRT
	f.byHash[newTokenHash] = newRT

	return newID, nil
}

func (f *fakeRefreshTokenRepository) Revoke(_ context.Context, tokenHash string) error {
	rt, ok := f.byHash[tokenHash]
	if !ok {
		return nil // idempotent: unknown token is not an error
	}
	now := time.Now()
	rt.RevokedAt = &now
	f.byHash[tokenHash] = rt
	f.byID[rt.ID] = rt
	return nil
}

// RevokeAllForUser mirrors the real UPDATE's semantics: every row for the
// user whose revoked_at IS NULL is stamped, and the count returned is how
// many actually changed.
func (f *fakeRefreshTokenRepository) RevokeAllForUser(_ context.Context, userID string) (int, error) {
	if f.revokeAllErr != nil {
		return 0, f.revokeAllErr
	}
	f.revokeAllCalls = append(f.revokeAllCalls, userID)

	now := time.Now()
	revoked := 0
	for id, rt := range f.byID {
		if rt.UserID != userID || rt.RevokedAt != nil {
			continue
		}
		stamped := now
		rt.RevokedAt = &stamped
		f.byID[id] = rt
		f.byHash[rt.TokenHash] = rt
		revoked++
	}
	return revoked, nil
}

// DeleteExpired mirrors the real sweep's eligibility rules (revoked, or
// expired longer ago than retention) and its batch cap.
func (f *fakeRefreshTokenRepository) DeleteExpired(_ context.Context, retention time.Duration, batchSize int) (int, error) {
	cutoff := time.Now().Add(-retention)
	deleted := 0
	for id, rt := range f.byID {
		if deleted >= batchSize {
			break
		}
		if rt.RevokedAt == nil && !rt.ExpiresAt.Before(cutoff) {
			continue
		}
		delete(f.byID, id)
		delete(f.byHash, rt.TokenHash)
		deleted++
	}
	return deleted, nil
}

// fakeVerificationCodeRepository keys rows by (userID, purpose), mirroring
// migration 0002's UNIQUE(user_id, purpose) — an Upsert for an existing key
// overwrites rather than adding a second row.
type fakeVerificationCodeRepository struct {
	// Guards both maps. The real repository's atomicity is Postgres's; a
	// map has none, so without this a test driving ClaimAttempt
	// concurrently would report a data race instead of the behaviour it is
	// trying to assert. Holding it across the whole of ClaimAttempt is also
	// what makes the attempt cap atomic here, which is the property the
	// claim exists for (V-1).
	mu         sync.Mutex
	rows       map[string]repository.VerificationCode
	targetRows map[string]repository.VerificationCode
}

func newFakeVerificationCodeRepository() *fakeVerificationCodeRepository {
	return &fakeVerificationCodeRepository{
		rows:       map[string]repository.VerificationCode{},
		targetRows: map[string]repository.VerificationCode{},
	}
}

func verificationCodeKey(userID string, purpose repository.VerificationPurpose) string {
	return userID + "|" + string(purpose)
}

func (f *fakeVerificationCodeRepository) Upsert(
	_ context.Context, userID string, purpose repository.VerificationPurpose, target, codeHash string, expiresAt time.Time,
) (repository.VerificationCode, error) {
	row := repository.VerificationCode{
		ID:        verificationCodeKey(userID, purpose),
		UserID:    userID,
		Purpose:   purpose,
		Target:    target,
		CodeHash:  codeHash,
		Attempts:  0,
		ExpiresAt: expiresAt,
		CreatedAt: time.Now(),
	}
	f.rows[verificationCodeKey(userID, purpose)] = row
	return row, nil
}

func (f *fakeVerificationCodeRepository) Get(_ context.Context, userID string, purpose repository.VerificationPurpose) (repository.VerificationCode, error) {
	row, ok := f.rows[verificationCodeKey(userID, purpose)]
	if !ok {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return row, nil
}

func (f *fakeVerificationCodeRepository) IncrementAttempts(_ context.Context, userID string, purpose repository.VerificationPurpose) (repository.VerificationCode, error) {
	key := verificationCodeKey(userID, purpose)
	row, ok := f.rows[key]
	if !ok {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	row.Attempts++
	f.rows[key] = row
	return row, nil
}

func (f *fakeVerificationCodeRepository) Delete(_ context.Context, userID string, purpose repository.VerificationPurpose) error {
	delete(f.rows, verificationCodeKey(userID, purpose))
	return nil
}

// ClaimAttempt mirrors the real UPDATE: the cap and the expiry are checked
// and the increment applied under one lock, so no two callers can both see
// the same pre-increment value. A fake that incremented without the cap
// would let the very race V-1 is about pass its own test.
func (f *fakeVerificationCodeRepository) ClaimAttempt(
	_ context.Context, userID string, purpose repository.VerificationPurpose, maxAttempts int,
) (repository.VerificationCode, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := verificationCodeKey(userID, purpose)
	row, ok := f.rows[key]
	if !ok || row.Attempts >= maxAttempts || !time.Now().Before(row.ExpiresAt) {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	row.Attempts++
	f.rows[key] = row
	return row, nil
}

// Consume mirrors the real conditional DELETE: it removes the row only
// while codeHash still matches, so a correct code cannot be spent twice.
func (f *fakeVerificationCodeRepository) Consume(
	_ context.Context, userID string, purpose repository.VerificationPurpose, codeHash string,
) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := verificationCodeKey(userID, purpose)
	row, ok := f.rows[key]
	if !ok || row.CodeHash != codeHash {
		return fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	delete(f.rows, key)
	return nil
}

func (f *fakeVerificationCodeRepository) ClaimAttemptByTarget(
	_ context.Context, purpose repository.VerificationPurpose, target string, maxAttempts int,
) (repository.VerificationCode, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := verificationCodeTargetKey(purpose, target)
	row, ok := f.targetRows[key]
	if !ok || row.Attempts >= maxAttempts || !time.Now().Before(row.ExpiresAt) {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	row.Attempts++
	f.targetRows[key] = row
	return row, nil
}

func (f *fakeVerificationCodeRepository) ConsumeByTarget(
	_ context.Context, purpose repository.VerificationPurpose, target, codeHash string,
) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := verificationCodeTargetKey(purpose, target)
	row, ok := f.targetRows[key]
	if !ok || row.CodeHash != codeHash {
		return fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	delete(f.targetRows, key)
	return nil
}

// verificationCodeTargetKey/*ByTarget methods mirror Upsert/Get/
// IncrementAttempts/Delete exactly, keyed by (purpose, target) instead of
// (userID, purpose) — kept on a separate targetRows map rather than
// reusing rows, so a test userID can never collide with a target string.
func verificationCodeTargetKey(purpose repository.VerificationPurpose, target string) string {
	return string(purpose) + "|" + target
}

func (f *fakeVerificationCodeRepository) UpsertForSignup(
	_ context.Context, purpose repository.VerificationPurpose, target, codeHash string, expiresAt time.Time,
) (repository.VerificationCode, error) {
	row := repository.VerificationCode{
		ID:        verificationCodeTargetKey(purpose, target),
		Purpose:   purpose,
		Target:    target,
		CodeHash:  codeHash,
		Attempts:  0,
		ExpiresAt: expiresAt,
		CreatedAt: time.Now(),
	}
	f.targetRows[verificationCodeTargetKey(purpose, target)] = row
	return row, nil
}

func (f *fakeVerificationCodeRepository) GetByTarget(_ context.Context, purpose repository.VerificationPurpose, target string) (repository.VerificationCode, error) {
	row, ok := f.targetRows[verificationCodeTargetKey(purpose, target)]
	if !ok {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return row, nil
}

func (f *fakeVerificationCodeRepository) IncrementAttemptsByTarget(_ context.Context, purpose repository.VerificationPurpose, target string) (repository.VerificationCode, error) {
	key := verificationCodeTargetKey(purpose, target)
	row, ok := f.targetRows[key]
	if !ok {
		return repository.VerificationCode{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	row.Attempts++
	f.targetRows[key] = row
	return row, nil
}

func (f *fakeVerificationCodeRepository) DeleteByTarget(_ context.Context, purpose repository.VerificationPurpose, target string) error {
	delete(f.targetRows, verificationCodeTargetKey(purpose, target))
	return nil
}

// fakeKnownCompanyRepository is a plain in-memory map keyed by
// name_normalized, mirroring known_companies (migration 0007, ADR-019 §3).
type fakeKnownCompanyRepository struct {
	byNameNormalized map[string]repository.KnownCompany
}

func newFakeKnownCompanyRepository() *fakeKnownCompanyRepository {
	return &fakeKnownCompanyRepository{byNameNormalized: map[string]repository.KnownCompany{}}
}

func (f *fakeKnownCompanyRepository) GetByNameNormalized(_ context.Context, nameNormalized string) (repository.KnownCompany, error) {
	row, ok := f.byNameNormalized[nameNormalized]
	if !ok {
		return repository.KnownCompany{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return row, nil
}

// fakeUnverifiedCompanyClaimRepository just records every Insert call —
// tests assert against claims directly, mirroring the manual-review queue
// (ADR-019 §3) with no reviewer logic of its own to fake.
type fakeUnverifiedCompanyClaimRepository struct {
	claims []repository.UnverifiedCompanyClaim
}

func (f *fakeUnverifiedCompanyClaimRepository) Insert(_ context.Context, claim repository.UnverifiedCompanyClaim) error {
	f.claims = append(f.claims, claim)
	return nil
}

// fakeTrustedContactRepository is an in-memory stand-in for
// repository.TrustedContactRepository, including the #80 consent state and
// the invitation caps.
type fakeTrustedContactRepository struct {
	byID          map[string]repository.TrustedContact
	nextID        int
	pendingTokens map[string]string // token hash -> contact id
	invites       []fakeInvite
	// requesterNames is what Confirm reports, by user id.
	requesterNames map[string]string
}

type fakeInvite struct {
	userID, phoneHash string
	sentAt            time.Time
}

func newFakeTrustedContactRepository() *fakeTrustedContactRepository {
	return &fakeTrustedContactRepository{
		byID:           map[string]repository.TrustedContact{},
		pendingTokens:  map[string]string{},
		requesterNames: map[string]string{},
	}
}

// Insert seeds an ALREADY-CONFIRMED contact — the state every contact added
// before consent existed is in (migration 0024, D2). Test-only; it is not
// part of the repository interface.
func (f *fakeTrustedContactRepository) Insert(_ context.Context, userID, name, phoneNumber, email string) (repository.TrustedContact, error) {
	f.nextID++
	c := repository.TrustedContact{
		ID: fmt.Sprintf("contact-%d", f.nextID), UserID: userID, Name: name,
		PhoneNumber: phoneNumber, Email: email, CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	f.byID[c.ID] = c
	return c, nil
}

func (f *fakeTrustedContactRepository) InsertPending(_ context.Context, c repository.NewPendingContact) (repository.TrustedContact, error) {
	existing := 0
	for _, tc := range f.byID {
		if tc.UserID == c.UserID {
			existing++
		}
	}
	if existing >= c.MaxContacts {
		return repository.TrustedContact{}, fmt.Errorf("fake: %w", repository.ErrTooManyTrustedContacts)
	}
	since := time.Now().Add(-c.CapWindow)
	byUser, toPhone := 0, 0
	for _, inv := range f.invites {
		if inv.sentAt.Before(since) {
			continue
		}
		if inv.userID == c.UserID {
			byUser++
		}
		if inv.phoneHash == c.PhoneHash {
			toPhone++
		}
	}
	if byUser >= c.MaxInvitesPerUser || toPhone >= c.MaxInvitesPerPhone {
		return repository.TrustedContact{}, fmt.Errorf("fake: %w", repository.ErrContactInviteLimit)
	}

	f.nextID++
	tc := repository.TrustedContact{
		ID: fmt.Sprintf("contact-%d", f.nextID), UserID: c.UserID, Name: c.Name,
		PhoneNumber: c.PhoneNumber, Email: c.Email, CreatedAt: time.Now(), UpdatedAt: time.Now(),
		PendingUntil: c.ExpiresAt,
	}
	f.byID[tc.ID] = tc
	f.pendingTokens[c.TokenHash] = tc.ID
	f.invites = append(f.invites, fakeInvite{userID: c.UserID, phoneHash: c.PhoneHash, sentAt: time.Now()})
	return tc, nil
}

func (f *fakeTrustedContactRepository) ListForUser(_ context.Context, userID string) ([]repository.TrustedContact, error) {
	var out []repository.TrustedContact
	for _, c := range f.byID {
		if c.UserID == userID {
			out = append(out, c)
		}
	}
	return out, nil
}

func (f *fakeTrustedContactRepository) Confirm(_ context.Context, tokenHash string) (string, error) {
	id, ok := f.pendingTokens[tokenHash]
	if !ok {
		return "", fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	c := f.byID[id]
	if !time.Now().Before(c.PendingUntil) {
		return "", fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	delete(f.pendingTokens, tokenHash)
	c.PendingUntil = time.Time{}
	f.byID[id] = c
	return f.requesterNames[c.UserID], nil
}

func (f *fakeTrustedContactRepository) DeleteInvitesSentBefore(_ context.Context, before time.Time, _ int) (int, error) {
	kept := f.invites[:0]
	deleted := 0
	for _, inv := range f.invites {
		if inv.sentAt.Before(before) {
			deleted++
			continue
		}
		kept = append(kept, inv)
	}
	f.invites = kept
	return deleted, nil
}

func (f *fakeTrustedContactRepository) Delete(_ context.Context, contactID, userID string) error {
	c, ok := f.byID[contactID]
	if !ok || c.UserID != userID {
		return fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	delete(f.byID, contactID)
	for hash, id := range f.pendingTokens { // ON DELETE CASCADE
		if id == contactID {
			delete(f.pendingTokens, hash)
		}
	}
	return nil
}

// fakeSOSEventRepository is an in-memory stand-in for
// repository.SOSEventRepository (ADR-026 §4, migration 0023 claims).
type fakeSOSEventRepository struct {
	events    []repository.SOSEvent
	completed []bool
	keys      map[string]int // userID + "|" + client request id -> index
	triggered []time.Time
	err       error
}

func (f *fakeSOSEventRepository) Claim(_ context.Context, c repository.SOSClaim) (repository.SOSOutcome, error) {
	if f.err != nil {
		return repository.SOSOutcome{}, f.err
	}
	if f.keys == nil {
		f.keys = map[string]int{}
	}
	if c.ClientRequestID != "" {
		if i, ok := f.keys[c.Event.UserID+"|"+c.ClientRequestID]; ok {
			return f.outcome(i), nil
		}
	}
	since := time.Now().Add(-c.Window)
	count := 0
	for i, e := range f.events {
		if e.UserID == c.Event.UserID && f.triggered[i].After(since) {
			count++
		}
	}
	if count >= c.MaxPerWindow {
		return repository.SOSOutcome{}, fmt.Errorf("fake: %w", repository.ErrSOSLimit)
	}
	f.events = append(f.events, c.Event)
	f.completed = append(f.completed, false)
	f.triggered = append(f.triggered, time.Now())
	i := len(f.events) - 1
	if c.ClientRequestID != "" {
		f.keys[c.Event.UserID+"|"+c.ClientRequestID] = i
	}
	return repository.SOSOutcome{EventID: fmt.Sprintf("sos-%d", i)}, nil
}

func (f *fakeSOSEventRepository) Complete(_ context.Context, eventID string, contactsNotified int) error {
	var i int
	if _, err := fmt.Sscanf(eventID, "sos-%d", &i); err != nil || i >= len(f.events) {
		return fmt.Errorf("fake: unknown sos event %q", eventID)
	}
	f.events[i].ContactsNotified = contactsNotified
	f.completed[i] = true
	return nil
}

func (f *fakeSOSEventRepository) Outcome(_ context.Context, userID, clientRequestID string) (repository.SOSOutcome, error) {
	i, ok := f.keys[userID+"|"+clientRequestID]
	if !ok {
		return repository.SOSOutcome{}, fmt.Errorf("fake: %w", apperror.ErrNotFound)
	}
	return f.outcome(i), nil
}

func (f *fakeSOSEventRepository) outcome(i int) repository.SOSOutcome {
	return repository.SOSOutcome{
		EventID:          fmt.Sprintf("sos-%d", i),
		Duplicate:        true,
		Completed:        f.completed[i],
		ContactsNotified: f.events[i].ContactsNotified,
	}
}

// fakeEmailSender/fakeSmsSender capture what would have been sent, so tests
// can assert the logged/dispatched code matches what verifies successfully
// — same rigor the addendum's integration tests ask for, applied at the
// unit level too.
type fakeEmailSender struct {
	sent []struct {
		to, code string
		purpose  email.Purpose
	}
	err error

	alertsSent []struct{ to, message string }
	alertErr   error
	// alertCallCount/alertFailFirstN (2026-08-31 round-3 hardening) — let a
	// test simulate a transient-then-recovers failure: the first
	// alertFailFirstN calls to SendAlert return alertErr, every call after
	// that succeeds. alertFailFirstN == 0 preserves the original behavior
	// (alertErr, if set, fails every call — sustained failure, e.g. for a
	// breaker-opens test).
	alertCallCount  int
	alertFailFirstN int
}

func (f *fakeEmailSender) SendVerificationCode(_ context.Context, to, code string, purpose email.Purpose) error {
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, struct {
		to, code string
		purpose  email.Purpose
	}{to, code, purpose})
	return nil
}

func (f *fakeEmailSender) lastCode() string {
	if len(f.sent) == 0 {
		return ""
	}
	return f.sent[len(f.sent)-1].code
}

func (f *fakeEmailSender) SendAlert(_ context.Context, to, message string) error {
	f.alertCallCount++
	if f.alertErr != nil && (f.alertFailFirstN == 0 || f.alertCallCount <= f.alertFailFirstN) {
		return f.alertErr
	}
	f.alertsSent = append(f.alertsSent, struct{ to, message string }{to, message})
	return nil
}

type fakeSmsSender struct {
	sent []struct{ to, code string }
	err  error

	alertsSent []struct{ to, message string }
	alertErr   error
	// See fakeEmailSender's identical fields for what these do.
	alertCallCount  int
	alertFailFirstN int
}

func (f *fakeSmsSender) SendVerificationCode(_ context.Context, to, code string) error {
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, struct{ to, code string }{to, code})
	return nil
}

func (f *fakeSmsSender) lastCode() string {
	if len(f.sent) == 0 {
		return ""
	}
	return f.sent[len(f.sent)-1].code
}

func (f *fakeSmsSender) SendAlert(_ context.Context, to, message string) error {
	f.alertCallCount++
	if f.alertErr != nil && (f.alertFailFirstN == 0 || f.alertCallCount <= f.alertFailFirstN) {
		return f.alertErr
	}
	f.alertsSent = append(f.alertsSent, struct{ to, message string }{to, message})
	return nil
}

// fakePublisher/PublishUserOnboarded are gone (ADR-018) — the service
// layer no longer holds an events.Publisher dependency at all, so nothing
// constructs one for tests either. fakeUserRepository.createCalls is what
// tests now assert against for "was an onboarding event queued": Create
// is only ever called to make a genuinely new account, and the real
// repository (users_postgres.go) writes the outbox row transactionally
// inside Create itself — one createCalls entry IS one onboarding event,
// by construction.
