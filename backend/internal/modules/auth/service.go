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
	"errors"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/modules/auth/sos"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
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
	UpdateTrustedContactRequest = sos.UpdateTrustedContactRequest
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

	// CompleteAccountClaim and ResendAccountClaimCode finish the ceremony a
	// federated signup starts when the provider's verified address is
	// already on an account (accountclaim.go). Both are unauthenticated,
	// like every other signup-shaped call here: the signed ticket plus the
	// mailed code ARE the credential.
	CompleteAccountClaim(ctx context.Context, req CompleteAccountClaimRequest) (SessionResult, error)
	ResendAccountClaimCode(ctx context.Context, ticket string) (StartVerificationResult, error)
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
	// SweepExpiredSafetyHolds purges safety holds whose purge_after has
	// passed (0016_safety_holds). Called hourly by RefreshTokenSweeper.
	SweepExpiredSafetyHolds(ctx context.Context) (purged int, err error)
	// SweepOTPBudgets deletes daily OTP budget rows before yesterday (#106).
	SweepOTPBudgets(ctx context.Context) (deleted int, err error)
	// SweepLocationRetention forgets last known locations older than 30
	// days and SOS events older than 90 (plan 30B, 3.3).
	SweepLocationRetention(ctx context.Context) (affected int, err error)

	// --- trusted contacts + SOS (sos sub-package) ---
	AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error)
	UpdateTrustedContact(ctx context.Context, req UpdateTrustedContactRequest) (TrustedContact, error)
	ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error)
	RemoveTrustedContact(ctx context.Context, req RemoveTrustedContactRequest) error
	TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error)
	// NotifyMeetupShare tells the caller's SELECTED trusted contacts about
	// one meetup. Driven by the meetup module (which owns the meetup facts)
	// through an adapter wired in cmd/monolith — see sos.NotifyMeetupShare
	// for why none of the message content comes from the client.
	NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) (notifiedContactIDs []string, err error)

	// GetLegalDocuments returns the current terms and privacy policy.
	GetLegalDocuments(ctx context.Context) (repository.LegalDocuments, error)
	// AcceptLegal records agreement to the current terms and privacy policy.
	AcceptLegal(ctx context.Context, userID, version, appVersion, platform string) error
	// HasAcceptedLegal says whether userID agreed to the current documents.
	HasAcceptedLegal(ctx context.Context, userID string) (bool, error)

	// SetProfilePhoto stores the caller's own picture and returns its path.
	SetProfilePhoto(ctx context.Context, userID string, raw []byte) (path string, err error)
	DeleteProfilePhoto(ctx context.Context, userID string) error
	// GetProfilePhoto returns a user's JPEG and etag; jpeg is nil when
	// knownEtag still matches.
	GetProfilePhoto(ctx context.Context, userID, knownEtag string) (jpeg []byte, etag string, err error)

	// DeleteAccount erases the caller's account for good (App Store
	// 5.1.1(v), Play's data-deletion policy), and announces it to every
	// other module via the user-deleted outbox. It touches only this
	// module's data; the "not while you have a live meetup" rule is the
	// meetup module's to enforce, and the gateway asks it first.
	DeleteAccount(ctx context.Context, userID string) error
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
	otpBudgets              repository.OTPBudgetRepository
	retention               repository.RetentionRepository
	photos                  repository.UserPhotoRepository
	legal                   repository.LegalRepository
	photoFetcher            PhotoFetcher
	limits                  *ratelimit.Shared
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
	Users             repository.UserRepository
	Identities        repository.UserIdentityRepository
	RefreshTokens     repository.RefreshTokenRepository
	VerificationCodes repository.VerificationCodeRepository
	// Photos stores users' pictures, and PhotoFetcher takes a new LinkedIn
	// account's picture once (plan 2.1).
	Photos       repository.UserPhotoRepository
	Legal        repository.LegalRepository
	PhotoFetcher PhotoFetcher
	// OTPBudgets enforces the daily per-target send and failed-guess caps
	// (#106). Nil disables them (unit tests); cmd/monolith always sets it.
	OTPBudgets repository.OTPBudgetRepository
	// Retention forgets old locations and SOS events (plan 30B, 3.3). Nil:
	// those sweeps do nothing (unit tests).
	Retention               repository.RetentionRepository
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
	// SOSMeetups finds the meetup an SOS message mentions. A port: the
	// meetup module owns meetups. Nil: messages have no meetup section.
	SOSMeetups sos.MeetupLookup
	// Limits counts trusted-contact changes and meetup shares across
	// instances (#81). Nil: none (unit tests); cmd/monolith always sets it.
	Limits *ratelimit.Shared
	Logger *slog.Logger
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
		otpBudgets:              deps.OTPBudgets,
		retention:               deps.Retention,
		photos:                  deps.Photos,
		legal:                   deps.Legal,
		photoFetcher:            deps.PhotoFetcher,
		limits:                  deps.Limits,
		knownCompanies:          deps.KnownCompanies,
		unverifiedCompanyClaims: deps.UnverifiedCompanyClaims,
		linkedin:                deps.LinkedIn,
		apple:                   deps.Apple,
		google:                  deps.Google,
		email:                   deps.Email,
		sms:                     deps.SMS,
		workEmailHMACKey:        deps.WorkEmailHMACKey,
		sos: sos.New(deps.Users, deps.TrustedContacts, deps.SOSEvents, deps.SMS, logger).
			WithLimits(deps.Limits).WithMeetups(deps.SOSMeetups),
		logger: logger,
	}
}

// --- trusted contacts + SOS: straight delegation to the sub-package ---

func (s *service) AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error) {
	// ADR-003. Checked here rather than inside the sos subpackage, which
	// stays a plain CRUD/alerting layer.
	if err := requireSafetyFeatureTrustLevel("adding a trusted contact", req.CallerTrustLevel); err != nil {
		return TrustedContact{}, err
	}
	return s.sos.AddTrustedContact(ctx, req)
}

func (s *service) UpdateTrustedContact(ctx context.Context, req UpdateTrustedContactRequest) (TrustedContact, error) {
	if err := requireSafetyFeatureTrustLevel("changing a trusted contact", req.CallerTrustLevel); err != nil {
		return TrustedContact{}, err
	}
	return s.sos.UpdateTrustedContact(ctx, req)
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

func (s *service) NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) ([]string, error) {
	return s.sos.NotifyMeetupShare(ctx, userID, share)
}

// DeleteAccount erases the caller's account.
//
// # IT TOUCHES ONLY THIS MODULE'S DATA
//
// Nothing here calls the meetup module. The account, its identities, tokens,
// verification codes, company claims, trusted contacts and SOS history go in
// ONE transaction (see the repository's Delete), and in that same transaction
// a user-deleted row is written to this module's outbox. Everything the
// meetup module holds about this person — including its cached copy of their
// name and photograph — is deleted by the meetup module itself when that
// event reaches it, with retries until it does.
//
// That is the shape these two need if they are ever separate services with
// separate databases: neither reaches into the other's tables, neither has to
// be up for the other to do its job, and the only contract between them is
// an event. A synchronous "purge your side, then I delete mine" call would
// have meant auth could not delete an account while meetup was down.
//
// # WHERE THE "NOT WHILE YOU HAVE A LIVE MEETUP" RULE LIVES
//
// Not here. Whether someone still owes others their presence is a question
// only the meetup module can answer, so the gateway — which composes both,
// as a BFF does — asks it before calling this. See the meetup module's
// CheckAccountDeletable.
//
// # IDEMPOTENT
//
// An account that is already gone is a SUCCESS, not a 404. userID comes from
// a verified JWT, so the only ways to reach this with no row are a retry
// after the first call already succeeded (a dropped response, a double tap)
// and a token that outlived its account. Both mean "your account is
// deleted", which is what was asked for; an error would turn a completed
// deletion into a visible failure and invite retrying forever.
func (s *service) DeleteAccount(ctx context.Context, userID string) error {
	if _, err := s.users.GetByID(ctx, userID); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return nil
		}
		return err
	}
	if err := s.users.Delete(ctx, userID); err != nil {
		// A concurrent delete of the same account (two devices, one tap
		// each) can win the race between the read above and this; the loser
		// has still got what it asked for.
		if errors.Is(err, apperror.ErrNotFound) {
			return nil
		}
		return err
	}
	s.logger.Info("account deleted", "user_id", userID)
	return nil
}
