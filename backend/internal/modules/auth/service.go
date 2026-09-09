// Package auth is the auth module: identity, verification (phone, personal
// email, corporate email), federated sign-in (Apple/Google/LinkedIn),
// sessions and refresh tokens, profile, the rating-average cache, and —
// through the sos sub-package — trusted contacts and SOS.
//
// Ported from ../Professional-Meetups/backend/services/auth (internal/
// service, internal/repository, internal/identity). The business rules are
// the source's, unchanged; what changed is the shape around them (ADR-001):
//
//   - The module exposes exactly ONE interface, Service (§2). Nothing outside
//     this package touches its repositories or its SQL, and this package
//     never imports another module. Re-extracting it later means writing a
//     gRPC server around this one interface, which is exactly what
//     internal/grpcapi already is.
//   - Its methods take and return plain Go structs (types.go), not protobuf
//     (§7). internal/grpcapi translates at the process boundary.
//   - They return plain wrapped apperror sentinels, not gRPC status errors.
//     The source called apperror.ToGRPCStatus inside the service because the
//     service WAS the gRPC server; here that translation belongs at the
//     boundary. Same sentinels, same messages, so the wire behavior a client
//     sees is unchanged.
//   - Session-issuing methods return identity facts, not a signed token
//     (§6) — see SessionResult.
//   - Events go out on the in-process bus, from the repository call sites
//     that used to write outbox rows (§4).
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/modules/auth/sos"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// RefreshTokenTTL is how long a refresh token stays valid before it must be
// rotated. Unlike the access-token TTL (a hardcoded security constant that
// now lives with the signer, in the gateway), this is a product/UX
// parameter — how often a mobile user must eventually re-authenticate — so
// it lives here with the module that owns refresh-token rows.
const RefreshTokenTTL = 30 * 24 * time.Hour

// Re-exported SOS types. The four trusted-contact/SOS operations are part of
// this module's one Service interface (they are AuthService RPCs in the
// source), while their implementation lives in the sos sub-package; aliases
// rather than wrapper types so there is exactly one definition of each and
// no conversion layer between the two halves of the same module.
type (
	TrustedContact              = sos.TrustedContact
	AddTrustedContactRequest    = sos.AddTrustedContactRequest
	RemoveTrustedContactRequest = sos.RemoveTrustedContactRequest
	MeetupShare                 = sos.MeetupShare
	TriggerSOSRequest           = sos.TriggerSOSRequest
	TriggerSOSResult            = sos.TriggerSOSResult
)

// Service is the auth module's entire surface — one method per AuthService
// RPC in the source's proto contract, in the same order. Every method that
// takes a UserID takes it from the gateway's verified JWT; a client never
// supplies its own.
type Service interface {
	// --- account creation / sign-in (unauthenticated at the gateway) ---
	CompleteFederatedSignup(ctx context.Context, req CompleteFederatedSignupRequest) (SessionResult, error)
	CompleteLinkedInOnboarding(ctx context.Context, req CompleteLinkedInOnboardingRequest) (SessionResult, error)
	StartEmailSignup(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error)
	CompleteEmailSignup(ctx context.Context, req CompleteEmailSignupRequest) (SessionResult, error)
	// GuestSignup creates a read-only guest account (trust Level 0) and
	// issues a real session for it (ADR-002 §3). Unauthenticated, like the
	// other three signup RPCs above.
	GuestSignup(ctx context.Context, req GuestSignupRequest) (SessionResult, error)
	StartEmailLogin(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error)
	CompleteEmailLogin(ctx context.Context, req VerifyCodeRequest) (SessionResult, error)
	RefreshSession(ctx context.Context, refreshToken string) (SessionResult, error)
	RevokeSession(ctx context.Context, refreshToken string) error

	// --- authenticated ---
	LinkIdentity(ctx context.Context, req LinkIdentityRequest) (SessionResult, error)
	StartPhoneVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error)
	VerifyPhoneCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error)
	StartPersonalEmailVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error)
	VerifyPersonalEmailCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error)
	SubmitPersonalDetails(ctx context.Context, req SubmitPersonalDetailsRequest) (SessionResult, error)
	StartCorporateEmailVerification(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error)
	VerifyCorporateEmailCode(ctx context.Context, req VerifyCodeRequest) (SessionResult, error)
	GetProfile(ctx context.Context, userID string) (Profile, error)
	CompleteProfileSetup(ctx context.Context, req CompleteProfileSetupRequest) (Profile, error)
	UpdateLastKnownLocation(ctx context.Context, req UpdateLastKnownLocationRequest) error

	// --- event consumer (rating_consumer.go) ---
	// ApplyRatingUpdate is called by the meetup module's rating-updated
	// event, wired in cmd/monolith. Not reachable over gRPC — no RPC writes
	// these columns.
	ApplyRatingUpdate(ctx context.Context, userID string, ratingAverage float64, ratingCount int, occurredAt time.Time) (applied bool, err error)

	// ApplyMeetupsCompletedUpdate is the same arrangement for the
	// meetups-completed event: driven by the meetup module, wired in
	// cmd/monolith, and deliberately not reachable over gRPC.
	ApplyMeetupsCompletedUpdate(ctx context.Context, userID string, meetupsCompleted int, occurredAt time.Time) (applied bool, err error)

	// --- background maintenance (sweeper.go) ---
	// SweepExpiredRefreshTokens deletes refresh-token rows that can never
	// authenticate anything again (§B3). Driven by RefreshTokenSweeper from
	// cmd/monolith, and likewise not reachable over gRPC — it is
	// housekeeping, not a client-facing operation. On the interface so the
	// sweeper can be constructed against Service rather than the concrete
	// type, matching how every other background loop in this process is
	// wired.
	SweepExpiredRefreshTokens(ctx context.Context) (deleted int, err error)
	// SweepAbandonedGuests deletes guest accounts with no refresh token left
	// and no way back in (plan 14 Part B). Driven by the same sweeper, on
	// the same tick, right after the token sweep.
	SweepAbandonedGuests(ctx context.Context) (deleted int, err error)

	// --- trusted contacts + SOS (sos sub-package) ---
	AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error)
	ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error)
	RemoveTrustedContact(ctx context.Context, req RemoveTrustedContactRequest) error
	TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error)
	// NotifyMeetupShare tells the caller's SELECTED trusted contacts about
	// one meetup. Driven by the meetup module (which owns the meetup facts)
	// through an adapter wired in cmd/monolith — see sos.NotifyMeetupShare
	// for why none of the message content comes from the client.
	NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) (int, error)
}

// service implements Service. Every dependency is passed explicitly via New —
// no framework, no globals. Note what is NOT here compared to the source's
// equivalent struct: no *jwt.Signer (ADR-001 §6 — this process never holds
// the private key), and no circuit breakers (ADR-001 §7).
type service struct {
	users                   repository.UserRepository
	identities              repository.UserIdentityRepository
	refreshTokens           repository.RefreshTokenRepository
	verificationCodes       repository.VerificationCodeRepository
	knownCompanies          repository.KnownCompanyRepository
	unverifiedCompanyClaims repository.UnverifiedCompanyClaimRepository
	linkedin                *linkedin.Client
	apple                   identity.Provider
	google                  identity.Provider
	email                   email.EmailSender
	sms                     sms.SmsSender
	// workEmailHMACKey keys hashWorkEmail (workemail.go) — held the way a
	// signing key is (a secrets/ mount, this process only), never logged,
	// never derived from anything client-supplied.
	workEmailHMACKey []byte

	sos    *sos.Service
	logger *slog.Logger
}

// Deps groups the auth module's dependencies. A struct rather than the
// source's 15 positional parameters: the source's New(...) call was already
// at the limit of what's readable, and this module gains rather than loses
// dependencies over time.
type Deps struct {
	Users                   repository.UserRepository
	Identities              repository.UserIdentityRepository
	RefreshTokens           repository.RefreshTokenRepository
	VerificationCodes       repository.VerificationCodeRepository
	KnownCompanies          repository.KnownCompanyRepository
	UnverifiedCompanyClaims repository.UnverifiedCompanyClaimRepository
	TrustedContacts         repository.TrustedContactRepository
	SOSEvents               repository.SOSEventRepository
	LinkedIn                *linkedin.Client
	Apple                   identity.Provider
	Google                  identity.Provider
	Email                   email.EmailSender
	SMS                     sms.SmsSender
	WorkEmailHMACKey        []byte
	Logger                  *slog.Logger
}

// New constructs the auth module's Service.
func New(deps Deps) Service {
	logger := deps.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &service{
		users:                   deps.Users,
		identities:              deps.Identities,
		refreshTokens:           deps.RefreshTokens,
		verificationCodes:       deps.VerificationCodes,
		knownCompanies:          deps.KnownCompanies,
		unverifiedCompanyClaims: deps.UnverifiedCompanyClaims,
		linkedin:                deps.LinkedIn,
		apple:                   deps.Apple,
		google:                  deps.Google,
		email:                   deps.Email,
		sms:                     deps.SMS,
		workEmailHMACKey:        deps.WorkEmailHMACKey,
		sos: sos.New(
			deps.Users, deps.TrustedContacts, deps.SOSEvents, deps.SMS, deps.Email,
			sos.Validator{PhoneNumber: validatePhoneNumber, Email: validateEmailShape},
			logger,
		),
		logger: logger,
	}
}

// --- trusted contacts + SOS: straight delegation to the sub-package ---

func (s *service) AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error) {
	// ADR-003. Checked here rather than inside the sos subpackage, which
	// stays a plain CRUD/alerting layer — the same reasoning as its
	// injected validator.
	if err := requireSafetyFeatureTrustLevel("adding a trusted contact", req.CallerTrustLevel); err != nil {
		return TrustedContact{}, err
	}
	return s.sos.AddTrustedContact(ctx, req)
}

func (s *service) ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error) {
	return s.sos.ListTrustedContacts(ctx, userID)
}

func (s *service) RemoveTrustedContact(ctx context.Context, req RemoveTrustedContactRequest) error {
	return s.sos.RemoveTrustedContact(ctx, req)
}

func (s *service) TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error) {
	// ADR-003 — see AddTrustedContact above.
	if err := requireSafetyFeatureTrustLevel("triggering SOS", req.CallerTrustLevel); err != nil {
		return TriggerSOSResult{}, err
	}
	return s.sos.TriggerSOS(ctx, req)
}

func (s *service) NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) (int, error) {
	return s.sos.NotifyMeetupShare(ctx, userID, share)
}

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

	// full_name may be "" here (Apple in particular only ever includes a name
	// on a user's very first authorization with this app) — the client
	// already knows to render a fallback ("Member").
	user, isNewUser, err := s.ResolveOrCreateIdentity(
		ctx, req.Provider, verified.Subject, verified.Email, verified.Name, "", req.AgeConfirmedOver18,
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
		ctx, FederatedProviderLinkedIn, info.Sub, "", info.Name, info.Picture, req.AgeConfirmedOver18,
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
	return s.issueSession(ctx, user)
}

// StartEmailSignup sends an OTP to email as the first step of the email-OTP
// signup flow. Unauthenticated — there is no user_id yet (the account may
// never even be created, see SignUpOrRecoverWithEmail's recovery path) — so
// this cannot reuse startVerification's userID-keyed Upsert/Get; it uses the
// target-keyed methods instead.
func (s *service) StartEmailSignup(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	if req.Purpose != VerificationPurposeEmailSignup {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartEmailSignup: %w", apperror.ErrInvalidInput)
	}
	return s.startTargetKeyedVerification(ctx, repository.VerificationPurposeEmailSignup, req.Target)
}

// StartEmailLogin sends an OTP to email as the first step of passwordless
// email login — symmetric to StartEmailSignup in shape (target-keyed, no
// user_id yet), but for a return visit rather than account creation.
// Deliberately does NOT check whether email belongs to an existing account
// before sending: doing so would let the Start step itself leak account
// existence, undercutting the same enumeration-safety CompleteEmailLogin's
// generic error message below is for.
func (s *service) StartEmailLogin(ctx context.Context, req StartVerificationRequest) (StartVerificationResult, error) {
	if req.Purpose != VerificationPurposeEmailLogin {
		return StartVerificationResult{}, fmt.Errorf("purpose mismatch for StartEmailLogin: %w", apperror.ErrInvalidInput)
	}
	return s.startTargetKeyedVerification(ctx, repository.VerificationPurposeEmailLogin, req.Target)
}

// startTargetKeyedVerification is the shared body of StartEmailSignup and
// StartEmailLogin — identical in the source too, line for line, minus the
// purpose constant; shared here rather than duplicated so the cooldown and
// expiry rules can't drift between the two.
func (s *service) startTargetKeyedVerification(
	ctx context.Context, purpose repository.VerificationPurpose, target string,
) (StartVerificationResult, error) {
	if target == "" {
		return StartVerificationResult{}, fmt.Errorf("target is required: %w", apperror.ErrInvalidInput)
	}

	existing, err := s.verificationCodes.GetByTarget(ctx, purpose, target)
	if err == nil {
		if age := time.Since(existing.CreatedAt); age < otpResendCooldown {
			return StartVerificationResult{}, fmt.Errorf("please wait before requesting another code: %w", apperror.ErrRateLimited)
		}
	} else if !errors.Is(err, apperror.ErrNotFound) {
		return StartVerificationResult{}, err
	}

	code, err := generateOTP()
	if err != nil {
		return StartVerificationResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.verificationCodes.UpsertForSignup(ctx, purpose, target, hashOTP(code), time.Now().Add(otpExpiry)); err != nil {
		return StartVerificationResult{}, err
	}

	if err := s.email.SendVerificationCode(ctx, target, code, email.PurposePersonalEmail); err != nil {
		s.logger.Error("verification code dispatch failed", "purpose", purpose, "error", err)
		return StartVerificationResult{}, fmt.Errorf("failed to send verification code, please try again: %w", apperror.ErrInternal)
	}

	return StartVerificationResult{ResendAfterSeconds: int32(otpResendCooldown.Seconds())}, nil
}

// CompleteEmailSignup verifies the OTP sent by StartEmailSignup, then calls
// SignUpOrRecoverWithEmail — which may create a new Level 0 user or recover
// an existing one. No password anywhere: proving inbox control via OTP is
// the entire credential, at signup and on every later login.
func (s *service) CompleteEmailSignup(ctx context.Context, req CompleteEmailSignupRequest) (SessionResult, error) {
	if err := s.verifyAndConsumeTargetKeyedCode(ctx, repository.VerificationPurposeEmailSignup, req.Email, req.Code); err != nil {
		return SessionResult{}, err
	}

	user, isNewUser, err := s.SignUpOrRecoverWithEmail(ctx, req.Email, req.AgeConfirmedOver18)
	if err != nil {
		return SessionResult{}, err
	}

	return s.finishSignupSession(ctx, user, isNewUser)
}

// CompleteEmailLogin verifies the OTP sent by StartEmailLogin against an
// ALREADY-existing account and, on success, issues a session. Returns the
// same generic "invalid email or code" error whether the account doesn't
// exist or the code is wrong — an account-enumeration-safe pattern. The OTP
// check runs unconditionally, whether or not the account exists, so a
// wrong-code attempt against a real account and any attempt against a
// nonexistent one cost the same.
func (s *service) CompleteEmailLogin(ctx context.Context, req VerifyCodeRequest) (SessionResult, error) {
	if req.Purpose != VerificationPurposeEmailLogin {
		return SessionResult{}, fmt.Errorf("purpose mismatch for CompleteEmailLogin: %w", apperror.ErrInvalidInput)
	}

	codeErr := s.verifyAndConsumeTargetKeyedCode(ctx, repository.VerificationPurposeEmailLogin, req.Target, req.Code)
	user, userErr := s.users.GetByPersonalEmail(ctx, req.Target)
	if codeErr != nil || userErr != nil {
		return SessionResult{}, fmt.Errorf("invalid email or code: %w", apperror.ErrUnauthorized)
	}

	return s.issueSession(ctx, user)
}

// verifyAndConsumeTargetKeyedCode mirrors verifyAndConsumeCode exactly,
// except keyed by (purpose, target) instead of (userID, purpose) — and is
// shared by both target-keyed purposes rather than duplicated per purpose.
// Unlike verifyAndConsumeCode there's no separate "target matches" check:
// GetByTarget already looks the row up BY target, so a mismatch can't occur
// here the way it can for the userID-keyed methods.
func (s *service) verifyAndConsumeTargetKeyedCode(ctx context.Context, purpose repository.VerificationPurpose, target, code string) error {
	pending, err := s.verificationCodes.GetByTarget(ctx, purpose, target)
	if err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return fmt.Errorf("no pending verification code, please request a new one: %w", apperror.ErrInvalidInput)
		}
		return err
	}

	if time.Now().After(pending.ExpiresAt) {
		_ = s.verificationCodes.DeleteByTarget(ctx, purpose, target)
		return fmt.Errorf("code expired, please request a new one: %w", apperror.ErrInvalidInput)
	}
	if pending.Attempts >= otpMaxAttempts {
		_ = s.verificationCodes.DeleteByTarget(ctx, purpose, target)
		return fmt.Errorf("too many attempts, please request a new code: %w", apperror.ErrInvalidInput)
	}

	if !otpMatches(pending.CodeHash, code) {
		updated, incErr := s.verificationCodes.IncrementAttemptsByTarget(ctx, purpose, target)
		if incErr == nil && updated.Attempts >= otpMaxAttempts {
			_ = s.verificationCodes.DeleteByTarget(ctx, purpose, target)
		}
		return fmt.Errorf("invalid code: %w", apperror.ErrInvalidInput)
	}

	return s.verificationCodes.DeleteByTarget(ctx, purpose, target)
}

// RefreshSession rotates a refresh token for a new pair. The presented token
// is invalidated whether or not it was valid to begin with.
//
// ADR-001 §6 splits this call in two: this module still owns validating and
// rotating the auth.refresh_tokens row and still mints the new refresh
// token, but the new ACCESS token is signed by the gateway from the UserID
// and TrustLevel returned here.
func (s *service) RefreshSession(ctx context.Context, refreshToken string) (SessionResult, error) {
	old, err := s.refreshTokens.FindByHash(ctx, hashToken(refreshToken))
	if err != nil {
		return SessionResult{}, err
	}

	// A replayed, already-rotated (or revoked) refresh token is the
	// signature of a STOLEN one, not a client bug: rotation is single-use
	// and transactional, so a well-behaved client physically cannot present
	// the same token twice — it discarded the old value the moment it
	// received the replacement.
	//
	// §B1: rejecting just this one request is not enough. If an attacker has
	// a copy of a token the legitimate client has since rotated, the
	// attacker also plausibly has the rest of that session's chain, and the
	// server has no way to tell which side of this exchange is the thief.
	// The standard response is to end the whole session family and make both
	// parties re-authenticate — the legitimate user is logged out too, which
	// is the correct trade-off: a forced re-login is a minor annoyance, a
	// silently-shared session is an account takeover.
	if old.RevokedAt != nil || old.ReplacedBy != nil {
		revoked, revokeErr := s.refreshTokens.RevokeAllForUser(ctx, old.UserID)
		if revokeErr != nil {
			// Logged, not propagated: the caller must still be rejected, and
			// returning the revocation's error instead would turn a
			// definite "no" into an ambiguous 500 that a client might retry.
			s.logger.Error("refresh token reuse detected but revoking the session family failed",
				"event", "refresh_token_reuse",
				"user_id", old.UserID,
				"error", revokeErr,
			)
		} else {
			// Deliberately loud, and deliberately without the token or its
			// hash: this is the one log line that says an account may be
			// compromised, and it is what an operator would alert on.
			s.logger.Warn("refresh token reuse detected — revoked the user's entire session family",
				"event", "refresh_token_reuse",
				"user_id", old.UserID,
				"sessions_revoked", revoked,
			)
		}
		return SessionResult{}, fmt.Errorf("refresh token already used: %w", apperror.ErrUnauthorized)
	}
	if time.Now().After(old.ExpiresAt) {
		return SessionResult{}, fmt.Errorf("refresh token expired: %w", apperror.ErrUnauthorized)
	}

	user, err := s.users.GetByID(ctx, old.UserID)
	if err != nil {
		return SessionResult{}, err
	}

	newRawToken, newHash, err := newRefreshToken()
	if err != nil {
		return SessionResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.refreshTokens.Rotate(ctx, old.ID, newHash, time.Now().Add(RefreshTokenTTL)); err != nil {
		return SessionResult{}, err
	}

	return SessionResult{
		UserID:          user.ID,
		RefreshToken:    newRawToken,
		FullName:        user.FullName,
		ProfilePhotoURL: user.ProfilePhotoURL,
		TrustLevel:      user.TrustLevel,
	}, nil
}

// RevokeSession revokes a refresh token (logout). Idempotent — revoking an
// already-revoked or unknown token is not an error.
func (s *service) RevokeSession(ctx context.Context, refreshToken string) error {
	return s.refreshTokens.Revoke(ctx, hashToken(refreshToken))
}

// issueSession persists a fresh refresh-token row for user and returns the
// facts the gateway needs to mint the access token (ADR-001 §6). The source's
// equivalent also signed a JWT here; this process cannot.
func (s *service) issueSession(ctx context.Context, user repository.User) (SessionResult, error) {
	rawToken, hash, err := newRefreshToken()
	if err != nil {
		return SessionResult{}, fmt.Errorf("%w: %w", apperror.ErrInternal, err)
	}

	if _, err := s.refreshTokens.Create(ctx, user.ID, hash, time.Now().Add(RefreshTokenTTL)); err != nil {
		return SessionResult{}, err
	}

	return SessionResult{
		UserID:          user.ID,
		RefreshToken:    rawToken,
		FullName:        user.FullName,
		ProfilePhotoURL: user.ProfilePhotoURL,
		TrustLevel:      user.TrustLevel,
	}, nil
}

// newRefreshToken generates a new random refresh token, returning both the
// raw value (returned to the client exactly once) and its SHA-256 hash — the
// only thing ever persisted.
func newRefreshToken() (raw, hash string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", fmt.Errorf("generate refresh token: %w", err)
	}
	raw = hex.EncodeToString(buf)
	return raw, hashToken(raw), nil
}

func hashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}
