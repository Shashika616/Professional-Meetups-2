package auth

import (
	"context"
	"fmt"
	"strings"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// CompleteFederatedSignup creates or resolves a Level 0 account via Sign in
// with Apple or Google Sign-In. Unlike LinkedIn's flow there is no
// server-to-server exchange: id_token arrives already signed by the
// provider, straight from their native SDK, and is verified purely
// cryptographically (including its nonce — see identity.Provider.Verify)
// before ResolveOrCreateIdentity, the one shared resolve-or-create function
// every federated login uses, ever sees it.
func (s *service) CompleteFederatedSignup(ctx context.Context, req CompleteFederatedSignupRequest) (SessionResult, error) {
	provider, err := s.federatedProvider(req.Provider)
	if err != nil {
		return SessionResult{}, err
	}

	verified, err := provider.Verify(ctx, req.IDToken, req.Nonce)
	if err != nil {
		// err may embed provider-specific verification detail (including
		// which check failed) — logged here in full, never handed to the
		// client, the same discipline LinkedIn's exchange errors use below.
		s.logger.Error("federated id_token verification failed", "provider", req.Provider, "error", err)
		return SessionResult{}, fmt.Errorf("sign-in failed, please try again: %w", apperror.ErrInvalidInput)
	}
	// The id_token itself is discarded after this call — never persisted,
	// same "verify, extract, discard" discipline as LinkedIn's access token.

	// The verified token's own name wins whenever it has one — that is the
	// authoritative value, signed by the provider, and it is what Google
	// always supplies. req.FullNameHint is consulted only when the token
	// carries no name, which today means Apple and Apple alone: its
	// id_token has no name claim at all, while its native SDK hands the
	// client givenName/familyName out-of-band on the credential object,
	// once, on the user's first authorization (Plan 22). That name was
	// being read and discarded before this.
	//
	// Both may still be empty (Apple on any LATER authorization returns no
	// name anywhere), in which case nothing changes: full_name is created
	// empty and the client renders its existing "Member" fallback.
	//
	// ResolveOrCreateIdentity only ever writes this at CREATION, so a hint
	// can never overwrite the name on an account that already exists — its
	// signature is deliberately unchanged, this is a call-site decision.
	name := verified.Name
	if name == "" {
		name = sanitizedNameHint(req.FullNameHint)
	}

	user, isNewUser, err := s.ResolveOrCreateIdentity(
		ctx, req.Provider, verified.Subject, verified.Email, name, "", req.AgeConfirmedOver18,
	)
	if err != nil {
		return SessionResult{}, err
	}

	return s.finishSignupSession(ctx, user, isNewUser)
}

// federatedProvider maps a request's provider to this service's constructed
// Provider — the only two values CompleteFederatedSignup ever accepts
// (LinkedIn direct signup is CompleteLinkedInOnboarding, not this method).
func (s *service) federatedProvider(p FederatedProvider) (identity.Provider, error) {
	switch p {
	case FederatedProviderApple:
		return s.apple, nil
	case FederatedProviderGoogle:
		return s.google, nil
	default:
		return nil, fmt.Errorf("unsupported identity provider for account creation: %v: %w", p, apperror.ErrInvalidInput)
	}
}

// CompleteLinkedInOnboarding creates or resolves a Level 1 account directly
// via LinkedIn — still unauthenticated, still the one path that grants Level
// 1 immediately. age_confirmed_over_18 is required and rejected server-side
// if false, same as every other signup path. Internally calls the same
// ResolveOrCreateIdentity every federated login uses, not a separate lookup.
func (s *service) CompleteLinkedInOnboarding(ctx context.Context, req CompleteLinkedInOnboardingRequest) (SessionResult, error) {
	token, err := s.linkedin.ExchangeCode(ctx, req.AuthorizationCode, req.RedirectURI)
	if err != nil {
		// err embeds LinkedIn's raw upstream response body — logged here with
		// full detail, but never handed to the client: that body is
		// untrusted-boundary-crossing implementation detail, not something
		// safe to echo back over the REST API.
		s.logger.Error("linkedin code exchange failed", "error", err)
		return SessionResult{}, fmt.Errorf("linkedin sign-in failed, please try again: %w", apperror.ErrInvalidInput)
	}

	// token is discarded after this call — never persisted.
	info, err := s.linkedin.FetchUserInfo(ctx, token)
	if err != nil {
		s.logger.Error("linkedin userinfo fetch failed", "error", err)
		return SessionResult{}, fmt.Errorf("linkedin sign-in failed, please try again: %w", apperror.ErrInvalidInput)
	}

	user, isNewUser, err := s.ResolveOrCreateIdentity(
		ctx, FederatedProviderLinkedIn, info.Sub, info.Email, info.Name, info.Picture, req.AgeConfirmedOver18,
	)
	if err != nil {
		return SessionResult{}, err
	}

	return s.finishSignupSession(ctx, user, isNewUser)
}

// finishSignupSession issues a session for a just-resolved-or-created user —
// the shared tail end of every signup method. The user-onboarded event is
// not published from here: UserRepository.Create publishes it at the point of
// the INSERT itself, since Create is only ever called to make a genuinely
// new account.
func (s *service) finishSignupSession(ctx context.Context, user repository.User, isNewUser bool) (SessionResult, error) {
	session, err := s.issueSession(ctx, user)
	if err != nil {
		return SessionResult{}, err
	}
	session.IsNewUser = isNewUser
	return session, nil
}

// LinkIdentity links an additional identity to the caller's
// already-authenticated account (the Profile "Connect LinkedIn" flow, or a
// future "add Apple/Google as backup sign-in"). Dispatches to the LinkedIn
// code-exchange or the Apple/Google id_token-verification path depending on
// req.Provider, then calls the one shared LinkIdentityToUser, which
// hard-rejects on a cross-user collision rather than silently merging two
// accounts.
func (s *service) LinkIdentity(ctx context.Context, req LinkIdentityRequest) (SessionResult, error) {
	var subject string
	// linkedInName is LinkedIn's own name for whoever just authorized, kept
	// only to compare against the account's current name once the link
	// succeeds (see the SuggestedNameUpdate block at the end). It is never
	// written anywhere by this method.
	var linkedInName string

	switch req.Provider {
	case FederatedProviderLinkedIn:
		token, err := s.linkedin.ExchangeCode(ctx, req.AuthorizationCode, req.RedirectURI)
		if err != nil {
			s.logger.Error("linkedin code exchange failed", "error", err)
			return SessionResult{}, fmt.Errorf("linkedin sign-in failed, please try again: %w", apperror.ErrInvalidInput)
		}
		// token is discarded after this call — never persisted.
		info, err := s.linkedin.FetchUserInfo(ctx, token)
		if err != nil {
			s.logger.Error("linkedin userinfo fetch failed", "error", err)
			return SessionResult{}, fmt.Errorf("linkedin sign-in failed, please try again: %w", apperror.ErrInvalidInput)
		}
		subject = info.Sub
		linkedInName = strings.TrimSpace(info.Name)

	case FederatedProviderApple, FederatedProviderGoogle:
		idProvider, err := s.federatedProvider(req.Provider)
		if err != nil {
			return SessionResult{}, err
		}
		verified, err := idProvider.Verify(ctx, req.IDToken, req.Nonce)
		if err != nil {
			s.logger.Error("federated id_token verification failed", "provider", req.Provider, "error", err)
			return SessionResult{}, fmt.Errorf("sign-in failed, please try again: %w", apperror.ErrInvalidInput)
		}
		subject = verified.Subject

	default:
		return SessionResult{}, fmt.Errorf("unsupported identity provider for LinkIdentity: %v: %w", req.Provider, apperror.ErrInvalidInput)
	}

	if err := s.LinkIdentityToUser(ctx, req.UserID, req.Provider, subject); err != nil {
		return SessionResult{}, err
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return SessionResult{}, err
	}
	session, err := s.issueSession(ctx, user)
	if err != nil {
		return SessionResult{}, err
	}

	// Offer, never impose (Plan 22). The link above deliberately left
	// full_name alone — connecting LinkedIn must not silently rewrite a name
	// the user already has, whether it came from their original signup or
	// they typed it themselves (ADR-023). But LinkedIn knowing them by a
	// different name is worth mentioning, so it is reported here and the
	// client asks. Empty when the names already agree, when LinkedIn has no
	// name, and on every non-LinkedIn branch, so the client has nothing to
	// ask about in the ordinary case.
	if linkedInName != "" && linkedInName != user.FullName {
		session.SuggestedNameUpdate = linkedInName
	}
	return session, nil
}
