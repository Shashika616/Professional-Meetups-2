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
		return existing, false, nil
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
		hypothetical := user
		hypothetical.LinkedInSub = subject
		_, err := s.users.UpdateLinkedInSub(ctx, userID, subject, computeTrustLevel(hypothetical))
		return err
	}

	repoProvider, err := toRepositoryIdentityProvider(provider)
	if err != nil {
		return err
	}
	// Linking Apple/Google in any combination never raises trust level
	// (ADR-014 §1) — no trust_level write needed here, unlike the LinkedIn
	// branch above.
	_, err = s.identities.Insert(ctx, userID, repoProvider, subject, "")
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
	hypothetical := created
	hypothetical.PersonalEmail = email
	withEmail, err := s.users.UpdatePersonalEmail(ctx, created.ID, email, computeTrustLevel(hypothetical))
	if err != nil {
		return repository.User{}, false, err
	}
	return withEmail, true, nil
}
