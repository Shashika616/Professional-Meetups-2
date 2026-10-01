package auth

import (
	"context"
	"errors"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// FederatedProvider and its three constants live in types.go — they are part
// of this module's public request shapes, not an internal detail of this
// file.

// ResolveOrCreateIdentity is THE single entry point every federated login
// (Apple, Google, LinkedIn) calls, regardless of which screen or button
// triggered it — CompleteFederatedSignup and CompleteLinkedInOnboarding
// both call this rather than each rolling their own lookup-or-create logic,
// per ADR-014's Identity Resolution section: "there is deliberately no
// separate signup-handler-vs-signin-handler code path for federated
// methods — a second implementation of the same lookup is exactly how this
// kind of bug creeps in."
//
// ageConfirmedOver18 is only consulted when about to create a NEW account —
// resolving an existing one never re-checks it (an existing user with a
// stale/false confirmation value isn't locked out of their own account by
// a later call; the rejection only ever blocks account CREATION).
//
// profilePhotoURL is a deliberate small addition beyond the plan's literal
// signature (backend/level0-federated-identity-PLAN.md Step 3 omits it) —
// Apple/Google's VerifiedIdentity carries no photo at all (callers pass
// ""), but LinkedIn's userinfo response always does, and ADR-011's existing
// CompleteLinkedInOnboarding already persisted it at creation; dropping the
// parameter here would silently regress that for every new LinkedIn
// signup, which the plan's own "no breaking change" instruction rules out.
func (s *service) ResolveOrCreateIdentity(
	ctx context.Context, provider FederatedProvider, subject, email, name, profilePhotoURL string, ageConfirmedOver18 bool,
) (user repository.User, isNewUser bool, err error) {
	if provider == FederatedProviderLinkedIn {
		return s.resolveOrCreateLinkedIn(ctx, subject, name, profilePhotoURL, ageConfirmedOver18)
	}
	return s.resolveOrCreateAppleGoogle(ctx, provider, subject, email, name, ageConfirmedOver18)
}

func (s *service) resolveOrCreateLinkedIn(
	ctx context.Context, subject, name, profilePhotoURL string, ageConfirmedOver18 bool,
) (repository.User, bool, error) {
	existing, err := s.users.GetByLinkedInSub(ctx, subject)
	if err == nil {
		// A returning LinkedIn user: mirror their current LinkedIn photo, so
		// changing it there changes it here on the next sign-in.
		return s.syncLinkedInPhoto(ctx, existing, profilePhotoURL), false, nil
	}
	if !errors.Is(err, apperror.ErrNotFound) {
		return repository.User{}, false, err
	}

	if !ageConfirmedOver18 {
		return repository.User{}, false, errAgeConfirmationRequired
	}

	// LinkedIn direct signup still grants Level 1 immediately (ADR-014 §1,
	// unchanged from ADR-011) — computed via computeTrustLevel rather than
	// a literal 1 so this stays derived from the same single source of
	// truth every other trust-level write in this service uses.
	created, err := s.users.Create(ctx, repository.NewUser{
		LinkedInSub:        subject,
		FullName:           name,
		ProfilePhotoURL:    profilePhotoURL,
		TrustLevel:         computeTrustLevel(repository.User{LinkedInSub: subject}),
		AgeConfirmedOver18: true,
	})
	if err != nil {
		return repository.User{}, false, err
	}
	return created, true, nil
}

func (s *service) resolveOrCreateAppleGoogle(
	ctx context.Context, provider FederatedProvider, subject, email, name string, ageConfirmedOver18 bool,
) (repository.User, bool, error) {
	repoProvider, err := toRepositoryIdentityProvider(provider)
	if err != nil {
		return repository.User{}, false, err
	}

	existingIdentity, err := s.identities.GetByProviderSubject(ctx, repoProvider, subject)
	if err == nil {
		user, err := s.users.GetByID(ctx, existingIdentity.UserID)
		if err != nil {
			return repository.User{}, false, err
		}
		return user, false, nil
	}
	if !errors.Is(err, apperror.ErrNotFound) {
		return repository.User{}, false, err
	}

	if !ageConfirmedOver18 {
		return repository.User{}, false, errAgeConfirmationRequired
	}

	// Level 0 (ADR-014 §1): Apple/Google alone never grant trust, no matter
	// how many are linked — computeTrustLevel on a user with no
	// linkedin_sub always returns 0.
	created, err := s.users.Create(ctx, repository.NewUser{
		FullName:           name,
		TrustLevel:         computeTrustLevel(repository.User{}),
		AgeConfirmedOver18: true,
	})
	if err != nil {
		return repository.User{}, false, err
	}
	if _, err := s.identities.Insert(ctx, created.ID, repoProvider, subject, email); err != nil {
		return repository.User{}, false, err
	}
	return created, true, nil
}

// LinkIdentityToUser attaches a new identity to an ALREADY-authenticated
// user (Profile-initiated "Connect LinkedIn," or a future "add Apple/Google
// as backup sign-in"). Hard-rejects with apperror.ErrConflict if (provider,
// subject) already belongs to a DIFFERENT user — the underlying unique
// constraints (idx_users_linkedin_sub for LinkedIn, user_identities'
// UNIQUE(provider, subject) for Apple/Google) are what actually resolve
// that race; this function never silently merges two accounts. ADR-014's
// Identity Resolution section calls this out explicitly as "the one real
// abuse edge in this whole design" — silent merging would let anyone who
// can trigger a link claim someone else's account.
func (s *service) LinkIdentityToUser(ctx context.Context, userID string, provider FederatedProvider, subject string) error {
	user, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return err
	}

	if provider == FederatedProviderLinkedIn {
		// THIS DELIBERATELY NEVER WRITES FullName, AND MUST NOT START.
		//
		// Signup (resolveOrCreateLinkedIn, above) takes LinkedIn's name
		// because it is creating the account and there is nothing to
		// overwrite. Linking is the opposite case: the account already
		// exists, and the name on it is the user's — typed into profile
		// editing (ADR-023 §5), or carried in from whichever provider they
		// originally signed up with, including the Apple out-of-band hint
		// (Plan 22). Connecting LinkedIn is not a request to be renamed, and
		// a user who has no idea their LinkedIn profile says "A. Lovelace"
		// would have no way to explain why their name changed by itself.
		//
		// Making the two paths "consistent" by copying the name here is the
		// specific mistake this comment exists to prevent. The supported way
		// to act on a mismatch is LinkIdentity's SuggestedNameUpdate, which
		// asks the user and routes a yes through the existing self-edit
		// path — see service.go's LinkIdentity and
		// TestLinkIdentityToUser_LinkedIn_NeverOverwritesExistingFullName,
		// which fails if this branch ever gains a FullName write.
		//
		// The linkedin_sub is applied to the locked row by the repository
		// before this runs; afterVerification supplies the is_guest change
		// the same statement makes (gap-tracker #17).
		_, err := s.users.UpdateLinkedInSub(ctx, userID, subject, func(u repository.User) int {
			return computeTrustLevel(afterVerification(u))
		})
		return err
	}

	repoProvider, err := toRepositoryIdentityProvider(provider)
	if err != nil {
		return err
	}
	if _, err := s.identities.Insert(ctx, userID, repoProvider, subject, ""); err != nil {
		return err
	}

	// CHANGED BY ADR-002 §3. This used to be a bare Insert with the note
	// "linking Apple/Google never raises trust level (ADR-014 §1)". That is
	// no longer true: Apple and Google are two of the four real signup paths,
	// so a GUEST linking one stops being a guest and becomes Level 1.
	//
	// Skipped entirely for an account that was never a guest — for them this
	// really does change nothing, and an unnecessary write would publish a
	// pointless user-profile-updated event to the meetup module's cache.
	if !user.IsGuest {
		return nil
	}
	// The `user` read above is kept only for the !user.IsGuest short-circuit
	// just above — a skip-the-write optimisation, not part of the race fix.
	// It no longer supplies the snapshot the trust level is computed from.
	_, err = s.users.ClearGuestFlag(ctx, userID, func(u repository.User) int {
		return computeTrustLevel(afterVerification(u))
	})
	return err
}

func toRepositoryIdentityProvider(provider FederatedProvider) (repository.IdentityProvider, error) {
	switch provider {
	case FederatedProviderApple:
		return repository.IdentityProviderApple, nil
	case FederatedProviderGoogle:
		return repository.IdentityProviderGoogle, nil
	default:
		return "", fmt.Errorf("service: %q has no user_identities row — LinkedIn identity lives on users.linkedin_sub: %w", provider, apperror.ErrInvalidInput)
	}
}

// errAgeConfirmationRequired is returned by every signup path (federated or
// email-OTP) when about to create a new account without
// age_confirmed_over_18 set — a single shared message so the four paths
// (Apple, Google, LinkedIn, email-OTP) can't drift into inconsistent
// wording (ADR-014's mandatory, uniform 18+ gate).
var errAgeConfirmationRequired = fmt.Errorf("you must confirm you are 18 or older to create an account: %w", apperror.ErrInvalidInput)

// SignUpOrRecoverWithEmail backs the email-OTP path (ADR-014 decision
// #2/#3, Step 4; passwordless as of ADR-019 §1). If email already matches
// an existing user's VERIFIED personal_email, this is treated as account
// RECOVERY — not a duplicate
// create, not a hard reject — because the caller already proved inbox
// control via a successful OTP check before this is ever called (see
// CompleteEmailSignup). This is a deliberate design choice from ADR-014's
// Identity Resolution section, not an oversight for a future reader to
// "fix" into a hard reject: without it, a user who originally signed up via
// LinkedIn/Apple/Google would have no way to ever add this email path to
// that same account, and would end up with a confusing duplicate account
// instead. Since ADR-019 §1 removed passwords entirely, "recovery" here no
// longer sets any credential — the existing account IS the result, a plain
// no-op login, because the OTP proof of inbox control is itself the only
// credential this path has ever needed.
func (s *service) SignUpOrRecoverWithEmail(
	ctx context.Context, email string, ageConfirmedOver18 bool,
) (user repository.User, isNewUser bool, err error) {
	existing, err := s.users.GetByPersonalEmail(ctx, email)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, apperror.ErrNotFound) {
		return repository.User{}, false, err
	}

	if !ageConfirmedOver18 {
		return repository.User{}, false, errAgeConfirmationRequired
	}

	// Level 0 (ADR-014 §2): email alone never grants Level 1 — LinkedIn is
	// still required for that, regardless of entry path.
	created, err := s.users.Create(ctx, repository.NewUser{
		TrustLevel:         computeTrustLevel(repository.User{}),
		AgeConfirmedOver18: true,
	})
	if err != nil {
		return repository.User{}, false, err
	}

	// personal_email is set immediately, pre-verified (the caller already
	// proved control via OTP) — a head start toward Level 2 later, but not
	// toward Level 1 by itself (computeTrustLevel still returns 0 here
	// since linkedin_sub is empty).
	withEmail, err := s.users.UpdatePersonalEmail(ctx, created.ID, email, func(u repository.User) int {
		return computeTrustLevel(afterVerification(u))
	})
	if err != nil {
		return repository.User{}, false, err
	}
	return withEmail, true, nil
}

// syncLinkedInPhoto mirrors a LinkedIn photo onto an existing user, and is
// the one place that decides whether a write is warranted.
//
// # WHY THE PHOTO IS SYNCED WHEN THE NAME IS ONLY SUGGESTED
//
// This app sources profile photos from LinkedIn and nowhere else — there is
// no upload path, by design: a LinkedIn photo is the one a person curates to
// look professional, which is exactly what this product wants on a meetup
// card. That makes LinkedIn the source of truth for the photo, so mirroring
// it is the feature rather than an overwrite.
//
// A name is the opposite case and must keep asking (Plan 22,
// LinkIdentity.SuggestedNameUpdate): the user may have typed their own in
// profile editing (ADR-023 §5), and silently replacing it is the specific
// harm that plan exists to prevent. Do not "harmonize" these two.
//
// Two conditions guard the write, and both matter:
//
//   - An EMPTY incoming url is ignored. A LinkedIn response without a
//     picture must leave an existing photo alone, never blank it — losing a
//     photo because the provider omitted a field would be strictly worse
//     than a stale one.
//   - An UNCHANGED url is ignored. The write publishes a
//     user-profile-updated event that the meetup module consumes to refresh
//     its display cache, so a no-op write is real wasted work downstream.
//
// Errors are logged and swallowed: the caller is mid sign-in or mid link,
// and failing that because a cosmetic mirror could not be written would
// trade a whole session for an avatar.
func (s *service) syncLinkedInPhoto(ctx context.Context, user repository.User, photoURL string) repository.User {
	if photoURL == "" || photoURL == user.ProfilePhotoURL {
		return user
	}
	updated, err := s.users.UpdateProfilePhoto(ctx, user.ID, photoURL)
	if err != nil {
		s.logger.Error("linkedin profile photo sync failed",
			"user_id", user.ID, "error", err)
		return user
	}
	return updated
}
