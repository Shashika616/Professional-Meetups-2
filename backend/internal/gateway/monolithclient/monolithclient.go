// Package monolithclient wraps the generated gRPC clients for the monolith.
// Handlers call this package's typed methods, never the generated stub
// directly, so gRPC-specific error handling and connection management live
// in one place.
//
// Replaces the sibling repo's three separate client packages (authclient,
// meetupclient, billingclient) with one: the gateway has one gRPC target now
// (ADR-001 §1). Phases 2 and 3 add the meetup and billing method sets to
// this same Client, over this same connection.
package monolithclient

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/internalauth"
	"professional-meetups-monolith/backend/internal/platform/logging"
	analyticsv1 "professional-meetups-monolith/backend/internal/proto/analytics/v1"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
	billingv1 "professional-meetups-monolith/backend/internal/proto/billing/v1"
	meetupv1 "professional-meetups-monolith/backend/internal/proto/meetup/v1"
	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
)

// connectTimeout bounds how long New waits for the initial connection before
// failing fast — a process that can't reach its dependencies should crash at
// startup, not accept traffic and fail every request.
const connectTimeout = 5 * time.Second

// Session is this package's own representation of what a session-issuing
// call returns, decoupled from the generated protobuf type.
//
// ADR-001 §6: there is no AccessToken field, because the monolith doesn't
// return one — the gateway signs it (see handlers.sessionFromClient).
// TrustLevel is here for exactly that reason: it's the second claim in the
// token the gateway is about to mint.
type Session struct {
	UserID          string
	RefreshToken    string
	IsNewUser       bool
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
	// SuggestedNameUpdate is non-empty only after a LinkedIn link whose
	// name differs from the account's own (Plan 22) — a suggestion for the
	// app to offer, never a change the server made.
	SuggestedNameUpdate string
}

// Profile is this package's own representation of GetProfile's (and
// CompleteProfileSetup's) response. The four raw fields (PhoneNumber,
// PersonalEmail, LegalName, Address) are returned only about the caller's
// own account — userID always comes from the verified JWT — and must never
// be exposed via any other route or about any other user. Work email has no
// raw field here and never will.
type Profile struct {
	UserID                  string
	FullName                string
	ProfilePhotoURL         string
	TrustLevel              int
	PhoneVerified           bool
	PersonalEmailVerified   bool
	PersonalDetailsComplete bool
	CompanyDomain           string
	WorkEmailVerified       bool
	RatingAverage           float64
	RatingCount             int
	MeetupsCompleted        int
	PhoneNumber             string
	PersonalEmail           string
	LegalName               string
	Address                 string
	LinkedInConnected       bool
	IsGuest                 bool
	CompanyName             string
}

// TrustedContact is this package's own representation of a trusted contact.
type TrustedContact struct {
	ID                   string
	Name                 string
	PhoneNumber          string
	CreatedAtUnixSeconds int64
}

// SOSFix is the phone's location for an SOS: nil coordinates when it has
// none, and CapturedAtUnix and Source empty from older app builds.
type SOSFix struct {
	Latitude, Longitude *float64
	CapturedAtUnix      *int64
	Source              string
}

// Client is the gateway's view of the monolith. Every method that takes a
// userID takes it from the caller (internal/gateway/handlers) having read it
// off the verified JWT — never a client-supplied value.
type Client interface {
	// CompleteFederatedSignup creates a Level 0 account, or logs in if this
	// (provider, subject) already has one. provider is the REST wire string
	// ("apple"/"google") — mapped to the proto enum here, not in the
	// handlers, so that mapping lives in exactly one place. nonce is the
	// client-generated per-attempt value bound to the id_token (see the
	// proto's own comment); required.
	// fullNameHint is the provider's out-of-band name (Apple only in
	// practice; "" from every other caller) — see the proto field.
	CompleteFederatedSignup(ctx context.Context, provider, idToken, nonce string, ageConfirmedOver18 bool, fullNameHint string) (Session, error)
	CompleteLinkedInOnboarding(ctx context.Context, authorizationCode, redirectURI string, ageConfirmedOver18 bool) (Session, error)
	// LinkIdentity links an identity to the caller's already-authenticated
	// account. idToken/nonce are used for apple/google, authorizationCode/
	// redirectURI for linkedin — the caller passes only the set relevant to
	// provider, the rest is ignored server-side.
	LinkIdentity(ctx context.Context, userID, provider, idToken, nonce, authorizationCode, redirectURI string) (Session, error)
	StartEmailSignup(ctx context.Context, email string) (resendAfterSeconds int32, err error)
	CompleteEmailSignup(ctx context.Context, email, code string, ageConfirmedOver18 bool) (Session, error)
	// GuestSignup creates a read-only guest account (ADR-002 §3).
	GuestSignup(ctx context.Context, ageConfirmedOver18 bool) (Session, error)
	StartEmailLogin(ctx context.Context, email string) (resendAfterSeconds int32, err error)
	CompleteEmailLogin(ctx context.Context, email, code string) (Session, error)

	// CompleteAccountClaim and ResendAccountClaimCode finish what the two
	// federated signup calls above start when they return an
	// *AccountClaimRequiredError (accountclaim.go). ResendAccountClaimCode
	// returns the new cooldown in seconds.
	CompleteAccountClaim(ctx context.Context, ticket, code string) (Session, error)
	ResendAccountClaimCode(ctx context.Context, ticket string) (int32, error)
	RefreshSession(ctx context.Context, refreshToken string) (Session, error)
	// RevokeSession is idempotent — revoking an already-revoked or unknown
	// token is not an error.
	RevokeSession(ctx context.Context, refreshToken string) error

	StartPhoneVerification(ctx context.Context, userID, phoneNumber string) (resendAfterSeconds int32, err error)
	VerifyPhoneCode(ctx context.Context, userID, phoneNumber, code string) (Session, error)
	StartPersonalEmailVerification(ctx context.Context, userID, email string) (resendAfterSeconds int32, err error)
	VerifyPersonalEmailCode(ctx context.Context, userID, email, code string) (Session, error)
	SubmitPersonalDetails(ctx context.Context, userID, legalName, address string) (Session, error)
	StartCorporateEmailVerification(ctx context.Context, userID, email string) (resendAfterSeconds int32, err error)
	VerifyCorporateEmailCode(ctx context.Context, userID, email, code, companyName string) (Session, error)
	GetProfile(ctx context.Context, userID string) (Profile, error)
	// GetLegalDocuments returns the current terms and privacy policy.
	GetLegalDocuments(ctx context.Context) (LegalDocuments, error)
	// AcceptLegal records agreement to the given version of the documents.
	AcceptLegal(ctx context.Context, userID, version string) error
	// HasAcceptedLegal says whether the caller agreed to the current version.
	HasAcceptedLegal(ctx context.Context, userID string) (bool, error)

	// SetProfilePhoto stores the caller's picture and returns its path.
	SetProfilePhoto(ctx context.Context, userID string, image []byte) (path string, err error)
	DeleteProfilePhoto(ctx context.Context, userID string) error
	// GetProfilePhoto returns a JPEG and its etag; jpeg is empty when
	// knownEtag still matches.
	GetProfilePhoto(ctx context.Context, userID, knownEtag string) (jpeg []byte, etag string, err error)
	CompleteProfileSetup(ctx context.Context, userID, fullName, companyName, companyEmail string) (Profile, error)

	UpdateLastKnownLocation(ctx context.Context, userID string, lat, lng float64) error
	// CheckAccountDeletable asks the meetup service whether the caller
	// still owes anyone their presence. AlreadyExists -> HTTP 409 with a
	// message that says what is outstanding and how to clear it.
	CheckAccountDeletable(ctx context.Context, userID string) error
	// DeleteAccount erases the caller's account in the auth service,
	// which announces it to the rest of the system itself. Idempotent.
	DeleteAccount(ctx context.Context, userID string) error

	AddTrustedContact(ctx context.Context, userID, name, phoneNumber string, callerTrustLevel int32) (TrustedContact, error)
	UpdateTrustedContact(ctx context.Context, userID, contactID, name, phoneNumber string, callerTrustLevel int32) (TrustedContact, error)
	ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error)
	RemoveTrustedContact(ctx context.Context, userID, contactID string) error
	// TriggerSOS returns how many trusted contacts were actually alerted.
	// lat/lng are nil when the device had no usable fix (#78): the
	// alert still goes out and says the location is unavailable.
	// clientRequestID is shared by an attempt and its automatic retry, so
	// the retry cannot alert everyone twice. Empty from older app builds.
	TriggerSOS(ctx context.Context, userID, contextMessage, clientRequestID string, fix SOSFix, callerTrustLevel int32) (contactsNotified int32, err error)

	// --- meetup module (Phase 2) — same connection, same interceptor ---
	CreateMeetup(ctx context.Context, hostUserID string, hostTrustLevel int32, intent string, windowStart, windowEnd int64, lat, lng float64, label string, capacity int32, charge CreateCharge) (Meetup, error)
	// intent "" means every intent; withinDays 0 means no time restriction.
	ListOpenMeetups(ctx context.Context, userID, intent, cursor string, pageSize int32, viewerLat, viewerLng float64, viewerTrustLevel, withinDays int32) ([]Meetup, string, error)
	GetMeetup(ctx context.Context, meetupID, userID string, viewerTrustLevel int32) (Meetup, error)
	ListMyMeetups(ctx context.Context, userID, hostedCursor, requestedCursor string) (hosted, requested []Meetup, hostedNextCursor string, hostedHasMore bool, requestedNextCursor string, requestedHasMore bool, err error)
	ListActiveMeetups(ctx context.Context, userID string) ([]Meetup, error)
	// CheckSchedule returns the meetup userID is already committed to in
	// the window, and false when it is free (ADR-005, advisory).
	CheckSchedule(ctx context.Context, userID string, windowStart, windowEnd int64) (Meetup, bool, error)
	ListMeetupRequests(ctx context.Context, meetupID, hostUserID string) ([]MeetupRequest, error)
	RequestToJoin(ctx context.Context, meetupID, requesterID string, requesterTrustLevel int32) (MeetupRequest, error)
	WithdrawRequest(ctx context.Context, requestID, requesterID, note string) error
	RespondToRequest(ctx context.Context, requestID, hostUserID string, accept bool) (MeetupRequest, error)
	RegisterDeviceToken(ctx context.Context, userID, fcmToken string) error
	UnregisterDeviceToken(ctx context.Context, userID, fcmToken string) error
	GetSafetyState(ctx context.Context, meetupID, userID string) (SafetyState, error)
	AcknowledgeSafetyChecklist(ctx context.Context, meetupID, userID string) (SafetyState, error)
	ShareWithContacts(ctx context.Context, meetupID, userID string, contactIDs []string) (SafetyState, error)
	CheckIn(ctx context.Context, meetupID, userID string) (SafetyState, error)
	DeclineCheckIn(ctx context.Context, meetupID, userID, reason string) (SafetyState, error)
	SubmitMeetupFeedback(ctx context.Context, meetupID, userID string, happened bool, feltSafe, profileAccurate, wouldMeetAgain *bool, notes *string) error
	ListNotifications(ctx context.Context, userID string) ([]UserNotification, error)
	ListMeetupParticipants(ctx context.Context, meetupID, viewerID string, viewerTrustLevel int32) (MeetupParticipants, error)
	// GetMemberActivity — another member's recent meetups as the viewer may
	// see them; PermissionDenied when the viewer may not open that member.
	GetMemberActivity(ctx context.Context, viewerID string, viewerTrustLevel int32, targetID string) (MemberActivity, error)
	ListRatableParticipants(ctx context.Context, meetupID, viewerID string, viewerTrustLevel int32) (RatableParticipants, error)
	SubmitMeetupReview(ctx context.Context, meetupID, raterUserID string, overallScore int32, notes *string, participants []ReviewParticipantInput) error
	GetMeetupReview(ctx context.Context, meetupID, viewerID string) (MeetupReview, error)
	SubmitRating(ctx context.Context, meetupID, raterUserID, ratedUserID string, score int32) error
	CloseMeetup(ctx context.Context, meetupID, hostUserID string) (Meetup, error)
	CancelMeetup(ctx context.Context, meetupID, hostUserID, reason string) error

	// --- billing module (plan 29A) — same connection, same interceptors ---
	GetWallet(ctx context.Context, userID string, trustLevel int32) (Wallet, error)
	ListLedger(ctx context.Context, userID, cursor string, pageSize int32) (LedgerPage, error)
	Quote(ctx context.Context, userID string, trustLevel, capacity int32, windowStart int64) (Quote, error)
	GetEntitlements(ctx context.Context, userID string, trustLevel int32) (Entitlements, error)

	// --- billing store routes (plan 29B) ---
	VerifyPurchase(ctx context.Context, userID string, trustLevel int32, platform, productID, token string) (PurchaseResult, error)
	GetSubscription(ctx context.Context, userID string) (Subscription, error)
	// GetCatalog is filtered for userID ("" when not signed in).
	GetCatalog(ctx context.Context, userID string) (Catalog, error)
	// The webhooks pass the store's request through untouched; billing
	// verifies it. processed is false for a repeat.
	HandleAppleNotification(ctx context.Context, signedPayload string) (processed bool, err error)
	HandleGoogleNotification(ctx context.Context, authorization, messageID, dataBase64 string) (processed bool, err error)

	// ScrapeMonolithMetrics returns the monolith's Prometheus registry as
	// text (plan 29D), for GET /metrics/monolith.
	ScrapeMonolithMetrics(ctx context.Context) ([]byte, error)

	// GetAppConfig evaluates the feature flags for userID ("" for an
	// anonymous caller) — GET /v1/app-config (plan 29 §2).
	GetAppConfig(ctx context.Context, userID string) (AppConfig, error)

	// CheckHealth asks the monolith's gRPC health service whether it is
	// serving — what the gateway's /readyz reports (§D3). Separate from the
	// business RPCs because it must work (and be callable) without any user
	// context at all.
	CheckHealth(ctx context.Context) error

	// RunScheduledWork runs every periodic sweep once and reports how many
	// of them failed. Driven by Cloud Scheduler through
	// POST /internal/cron/tick, which is what keeps the lifecycle sweeps,
	// the outbox pollers and the retention passes running while the service
	// scales to zero (service.yaml, runbook §10).
	//
	// Like CheckHealth, it carries no user context: it is operator work, not
	// anybody's request. group is "" (the core sweeps) or "analytics".
	RunScheduledWork(ctx context.Context, group string) (ScheduledWorkReport, error)

	// IngestAnalytics forwards one event batch (plan 29D). userID is from
	// the verified token, "" when signed out.
	IngestAnalytics(ctx context.Context, userID string, b AnalyticsBatch) (AnalyticsResult, error)
	// SetAnalyticsConsent stores a signed-in user's opt-out.
	SetAnalyticsConsent(ctx context.Context, userID string, optedOut bool) error

	Close() error
}

// ScheduledWorkReport is one tick's outcome, for the response body and the
// gateway's log line.
type ScheduledWorkReport struct {
	Results []SweepOutcome `json:"results"`
	Failed  int            `json:"failed"`
}

// SweepOutcome is one sweep's result within a tick.
type SweepOutcome struct {
	Name     string `json:"name"`
	Affected int64  `json:"affected"`
	Error    string `json:"error,omitempty"`
}

type grpcClient struct {
	conn    *grpc.ClientConn
	auth    authv1.AuthServiceClient
	meetup  meetupv1.MeetupServiceClient
	billing billingv1.BillingServiceClient
	// analytics is plan 29D's ingest and consent.
	analytics analyticsv1.AnalyticsServiceClient
	health    healthpb.HealthClient
	ops       opsv1.OpsServiceClient
}

// New connects to the monolith at addr (e.g. "monolith:9090"), blocking
// until the connection is ready or connectTimeout elapses.
//
// sharedSecret authenticates this process to the monolith (ADR-001's
// 2026-09-04 correction). It is attached by a connection-level interceptor
// rather than per call site, so a method added to this client later cannot
// forget it — the failure mode of the alternative is a new RPC that works in
// a test with the interceptor stubbed out and 401s in production.
func New(addr, sharedSecret string) (Client, error) {
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		// Plan 29D: a client span per call, and W3C traceparent onto the
		// wire, so the monolith's spans join the gateway's trace.
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
		grpc.WithChainUnaryInterceptor(
			internalauth.UnaryClientInterceptor(sharedSecret),
			// X-App-Version / X-Platform, onto every call (plan 29 §2).
			clientinfo.UnaryClientInterceptor(),
			// X-Request-ID, so the monolith logs the gateway's id too.
			logging.UnaryClientInterceptor(),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("monolithclient: create grpc client for %s: %w", addr, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()

	conn.Connect()
	for {
		state := conn.GetState()
		if state == connectivity.Ready {
			break
		}
		if !conn.WaitForStateChange(ctx, state) {
			_ = conn.Close()
			return nil, fmt.Errorf("monolithclient: connect to monolith at %s: %w", addr, ctx.Err())
		}
	}

	return &grpcClient{
		conn:      conn,
		auth:      authv1.NewAuthServiceClient(conn),
		meetup:    meetupv1.NewMeetupServiceClient(conn),
		billing:   billingv1.NewBillingServiceClient(conn),
		analytics: analyticsv1.NewAnalyticsServiceClient(conn),
		health:    healthpb.NewHealthClient(conn),
		ops:       opsv1.NewOpsServiceClient(conn),
	}, nil
}

// CheckHealth queries the monolith's standard gRPC health service.
//
// The empty service name means "the server as a whole", which is what the
// monolith registers under — and which it deliberately reports as SERVING
// only once its listener is actually accepting, not merely once the process
// has started.
func (c *grpcClient) CheckHealth(ctx context.Context) error {
	resp, err := c.health.Check(ctx, &healthpb.HealthCheckRequest{Service: ""})
	if err != nil {
		return fmt.Errorf("monolithclient: health check: %w", err)
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		return fmt.Errorf("monolithclient: monolith reports %s", resp.GetStatus())
	}
	return nil
}

// RunScheduledWork drives one tick of the monolith's periodic sweeps.
//
// A sweep that fails comes back inside the report, not as an error: the
// error return is for "the tick could not be run at all". The handler needs
// to tell those apart, because only the second means retrying the whole tick
// is the right response.
func (c *grpcClient) RunScheduledWork(ctx context.Context, group string) (ScheduledWorkReport, error) {
	resp, err := c.ops.RunScheduledWork(ctx, &opsv1.RunScheduledWorkRequest{Group: group})
	if err != nil {
		return ScheduledWorkReport{}, fmt.Errorf("monolithclient: run scheduled work: %w", err)
	}

	report := ScheduledWorkReport{
		Results: make([]SweepOutcome, 0, len(resp.GetResults())),
		Failed:  int(resp.GetFailed()),
	}
	for _, r := range resp.GetResults() {
		report.Results = append(report.Results, SweepOutcome{
			Name:     r.GetName(),
			Affected: r.GetAffected(),
			Error:    r.GetError(),
		})
	}
	return report, nil
}

func (c *grpcClient) Close() error {
	return c.conn.Close()
}

// providerFromWire maps the REST wire string to the proto enum — the one
// place that mapping happens, not duplicated in the handlers too.
func providerFromWire(provider string) (authv1.IdentityProviderProto, error) {
	switch provider {
	case "apple":
		return authv1.IdentityProviderProto_IDENTITY_PROVIDER_APPLE, nil
	case "google":
		return authv1.IdentityProviderProto_IDENTITY_PROVIDER_GOOGLE, nil
	case "linkedin":
		return authv1.IdentityProviderProto_IDENTITY_PROVIDER_LINKEDIN, nil
	default:
		return authv1.IdentityProviderProto_IDENTITY_PROVIDER_UNSPECIFIED, fmt.Errorf("monolithclient: unknown identity provider %q", provider)
	}
}

func (c *grpcClient) CompleteFederatedSignup(
	ctx context.Context, provider, idToken, nonce string, ageConfirmedOver18 bool, fullNameHint string,
) (Session, error) {
	providerProto, err := providerFromWire(provider)
	if err != nil {
		return Session{}, err
	}

	resp, err := c.auth.CompleteFederatedSignup(ctx, &authv1.CompleteFederatedSignupRequest{
		Provider:            providerProto,
		IdToken:             idToken,
		Nonce:               nonce,
		AgeConfirmedOver_18: ageConfirmedOver18,
		FullNameHint:        fullNameHint,
	})
	if err != nil {
		return Session{}, withAccountClaim(err)
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) CompleteLinkedInOnboarding(
	ctx context.Context, authorizationCode, redirectURI string, ageConfirmedOver18 bool,
) (Session, error) {
	resp, err := c.auth.CompleteLinkedInOnboarding(ctx, &authv1.CompleteLinkedInOnboardingRequest{
		AuthorizationCode:   authorizationCode,
		RedirectUri:         redirectURI,
		AgeConfirmedOver_18: ageConfirmedOver18,
	})
	if err != nil {
		return Session{}, withAccountClaim(err)
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) LinkIdentity(
	ctx context.Context, userID, provider, idToken, nonce, authorizationCode, redirectURI string,
) (Session, error) {
	providerProto, err := providerFromWire(provider)
	if err != nil {
		return Session{}, err
	}

	resp, err := c.auth.LinkIdentity(ctx, &authv1.LinkIdentityRequest{
		UserId:            userID,
		Provider:          providerProto,
		IdToken:           idToken,
		Nonce:             nonce,
		AuthorizationCode: authorizationCode,
		RedirectUri:       redirectURI,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) StartEmailSignup(ctx context.Context, email string) (int32, error) {
	resp, err := c.auth.StartEmailSignup(ctx, &authv1.StartVerificationRequest{
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_EMAIL_SIGNUP,
		Target:  email,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}

func (c *grpcClient) CompleteEmailSignup(
	ctx context.Context, email, code string, ageConfirmedOver18 bool,
) (Session, error) {
	resp, err := c.auth.CompleteEmailSignup(ctx, &authv1.CompleteEmailSignupRequest{
		Email:               email,
		Code:                code,
		AgeConfirmedOver_18: ageConfirmedOver18,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) GuestSignup(ctx context.Context, ageConfirmedOver18 bool) (Session, error) {
	resp, err := c.auth.GuestSignup(ctx, &authv1.GuestSignupRequest{
		AgeConfirmedOver_18: ageConfirmedOver18,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) StartEmailLogin(ctx context.Context, email string) (int32, error) {
	resp, err := c.auth.StartEmailLogin(ctx, &authv1.StartVerificationRequest{
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_EMAIL_LOGIN,
		Target:  email,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}

func (c *grpcClient) CompleteEmailLogin(ctx context.Context, email, code string) (Session, error) {
	resp, err := c.auth.CompleteEmailLogin(ctx, &authv1.VerifyCodeRequest{
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_EMAIL_LOGIN,
		Target:  email,
		Code:    code,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) RefreshSession(ctx context.Context, refreshToken string) (Session, error) {
	resp, err := c.auth.RefreshSession(ctx, &authv1.RefreshSessionRequest{RefreshToken: refreshToken})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) RevokeSession(ctx context.Context, refreshToken string) error {
	_, err := c.auth.RevokeSession(ctx, &authv1.RevokeSessionRequest{RefreshToken: refreshToken})
	return err
}

func (c *grpcClient) StartPhoneVerification(ctx context.Context, userID, phoneNumber string) (int32, error) {
	resp, err := c.auth.StartPhoneVerification(ctx, &authv1.StartVerificationRequest{
		UserId:  userID,
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_PHONE,
		Target:  phoneNumber,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}

func (c *grpcClient) VerifyPhoneCode(ctx context.Context, userID, phoneNumber, code string) (Session, error) {
	resp, err := c.auth.VerifyPhoneCode(ctx, &authv1.VerifyCodeRequest{
		UserId:  userID,
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_PHONE,
		Target:  phoneNumber,
		Code:    code,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) StartPersonalEmailVerification(ctx context.Context, userID, email string) (int32, error) {
	resp, err := c.auth.StartPersonalEmailVerification(ctx, &authv1.StartVerificationRequest{
		UserId:  userID,
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_PERSONAL_EMAIL,
		Target:  email,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}

func (c *grpcClient) VerifyPersonalEmailCode(ctx context.Context, userID, email, code string) (Session, error) {
	resp, err := c.auth.VerifyPersonalEmailCode(ctx, &authv1.VerifyCodeRequest{
		UserId:  userID,
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_PERSONAL_EMAIL,
		Target:  email,
		Code:    code,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) SubmitPersonalDetails(ctx context.Context, userID, legalName, address string) (Session, error) {
	resp, err := c.auth.SubmitPersonalDetails(ctx, &authv1.SubmitPersonalDetailsRequest{
		UserId:    userID,
		LegalName: legalName,
		Address:   address,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

func (c *grpcClient) StartCorporateEmailVerification(ctx context.Context, userID, email string) (int32, error) {
	resp, err := c.auth.StartCorporateEmailVerification(ctx, &authv1.StartVerificationRequest{
		UserId:  userID,
		Purpose: authv1.VerificationPurpose_VERIFICATION_PURPOSE_CORPORATE_EMAIL,
		Target:  email,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetResendAfterSeconds(), nil
}

func (c *grpcClient) VerifyCorporateEmailCode(ctx context.Context, userID, email, code, companyName string) (Session, error) {
	resp, err := c.auth.VerifyCorporateEmailCode(ctx, &authv1.VerifyCodeRequest{
		UserId:      userID,
		Purpose:     authv1.VerificationPurpose_VERIFICATION_PURPOSE_CORPORATE_EMAIL,
		Target:      email,
		Code:        code,
		CompanyName: companyName,
	})
	if err != nil {
		return Session{}, err
	}
	return sessionFromProto(resp), nil
}

// LegalDocuments is the current terms and privacy policy.
type LegalDocuments struct {
	Version string `json:"version"`
	Terms   string `json:"terms"`
	Privacy string `json:"privacy"`
}

func (c *grpcClient) GetLegalDocuments(ctx context.Context) (LegalDocuments, error) {
	resp, err := c.auth.GetLegalDocuments(ctx, &authv1.GetLegalDocumentsRequest{})
	if err != nil {
		return LegalDocuments{}, err
	}
	return LegalDocuments{Version: resp.GetVersion(), Terms: resp.GetTerms(), Privacy: resp.GetPrivacy()}, nil
}

func (c *grpcClient) AcceptLegal(ctx context.Context, userID, version string) error {
	_, err := c.auth.AcceptLegal(ctx, &authv1.AcceptLegalRequest{UserId: userID, Version: version})
	return err
}

func (c *grpcClient) HasAcceptedLegal(ctx context.Context, userID string) (bool, error) {
	resp, err := c.auth.HasAcceptedLegal(ctx, &authv1.HasAcceptedLegalRequest{UserId: userID})
	if err != nil {
		return false, err
	}
	return resp.GetAccepted(), nil
}

func (c *grpcClient) SetProfilePhoto(ctx context.Context, userID string, image []byte) (string, error) {
	resp, err := c.auth.SetProfilePhoto(ctx, &authv1.SetProfilePhotoRequest{UserId: userID, Image: image})
	if err != nil {
		return "", err
	}
	return resp.GetPhotoPath(), nil
}

func (c *grpcClient) DeleteProfilePhoto(ctx context.Context, userID string) error {
	_, err := c.auth.DeleteProfilePhoto(ctx, &authv1.DeleteProfilePhotoRequest{UserId: userID})
	return err
}

func (c *grpcClient) GetProfilePhoto(ctx context.Context, userID, knownEtag string) ([]byte, string, error) {
	resp, err := c.auth.GetProfilePhoto(ctx, &authv1.GetProfilePhotoRequest{UserId: userID, KnownEtag: knownEtag})
	if err != nil {
		return nil, "", err
	}
	return resp.GetJpeg(), resp.GetEtag(), nil
}

func (c *grpcClient) GetProfile(ctx context.Context, userID string) (Profile, error) {
	resp, err := c.auth.GetProfile(ctx, &authv1.GetProfileRequest{UserId: userID})
	if err != nil {
		return Profile{}, err
	}
	return profileFromProto(resp), nil
}

func (c *grpcClient) CompleteProfileSetup(ctx context.Context, userID, fullName, companyName, companyEmail string) (Profile, error) {
	resp, err := c.auth.CompleteProfileSetup(ctx, &authv1.CompleteProfileSetupRequest{
		UserId:       userID,
		FullName:     fullName,
		CompanyName:  companyName,
		CompanyEmail: companyEmail,
	})
	if err != nil {
		return Profile{}, err
	}
	return profileFromProto(resp), nil
}

func (c *grpcClient) UpdateLastKnownLocation(ctx context.Context, userID string, lat, lng float64) error {
	_, err := c.auth.UpdateLastKnownLocation(ctx, &authv1.UpdateLastKnownLocationRequest{
		UserId: userID, Lat: lat, Lng: lng,
	})
	return err
}

func (c *grpcClient) CheckAccountDeletable(ctx context.Context, userID string) error {
	_, err := c.meetup.CheckAccountDeletable(ctx, &meetupv1.CheckAccountDeletableRequest{UserId: userID})
	return err
}

func (c *grpcClient) DeleteAccount(ctx context.Context, userID string) error {
	_, err := c.auth.DeleteAccount(ctx, &authv1.DeleteAccountRequest{UserId: userID})
	return err
}

func (c *grpcClient) AddTrustedContact(ctx context.Context, userID, name, phoneNumber string, callerTrustLevel int32) (TrustedContact, error) {
	resp, err := c.auth.AddTrustedContact(ctx, &authv1.AddTrustedContactRequest{
		UserId: userID, Name: name, PhoneNumber: phoneNumber,
		CallerTrustLevel: callerTrustLevel,
	})
	if err != nil {
		return TrustedContact{}, err
	}
	return trustedContactFromProto(resp), nil
}

func (c *grpcClient) UpdateTrustedContact(ctx context.Context, userID, contactID, name, phoneNumber string, callerTrustLevel int32) (TrustedContact, error) {
	resp, err := c.auth.UpdateTrustedContact(ctx, &authv1.UpdateTrustedContactRequest{
		UserId: userID, ContactId: contactID, Name: name, PhoneNumber: phoneNumber,
		CallerTrustLevel: callerTrustLevel,
	})
	if err != nil {
		return TrustedContact{}, err
	}
	return trustedContactFromProto(resp), nil
}

func (c *grpcClient) ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error) {
	resp, err := c.auth.ListTrustedContacts(ctx, &authv1.ListTrustedContactsRequest{UserId: userID})
	if err != nil {
		return nil, err
	}
	contacts := make([]TrustedContact, 0, len(resp.GetContacts()))
	for _, c := range resp.GetContacts() {
		contacts = append(contacts, trustedContactFromProto(c))
	}
	return contacts, nil
}

func (c *grpcClient) RemoveTrustedContact(ctx context.Context, userID, contactID string) error {
	_, err := c.auth.RemoveTrustedContact(ctx, &authv1.RemoveTrustedContactRequest{
		UserId: userID, ContactId: contactID,
	})
	return err
}

func (c *grpcClient) TriggerSOS(ctx context.Context, userID, contextMessage, clientRequestID string, fix SOSFix, callerTrustLevel int32) (int32, error) {
	resp, err := c.auth.TriggerSOS(ctx, &authv1.TriggerSOSRequest{
		UserId: userID, ContextMessage: contextMessage, Latitude: fix.Latitude, Longitude: fix.Longitude,
		CapturedAtUnixSeconds: fix.CapturedAtUnix, LocationSource: fix.Source,
		CallerTrustLevel: callerTrustLevel, ClientRequestId: clientRequestID,
	})
	if err != nil {
		return 0, err
	}
	return resp.GetContactsNotified(), nil
}

func trustedContactFromProto(resp *authv1.TrustedContactResponse) TrustedContact {
	return TrustedContact{
		ID:                   resp.GetId(),
		Name:                 resp.GetName(),
		PhoneNumber:          resp.GetPhoneNumber(),
		CreatedAtUnixSeconds: resp.GetCreatedAtUnixSeconds(),
	}
}

func profileFromProto(resp *authv1.ProfileResponse) Profile {
	return Profile{
		UserID:                  resp.GetUserId(),
		FullName:                resp.GetFullName(),
		ProfilePhotoURL:         resp.GetProfilePhotoUrl(),
		TrustLevel:              int(resp.GetTrustLevel()),
		PhoneVerified:           resp.GetPhoneVerified(),
		PersonalEmailVerified:   resp.GetPersonalEmailVerified(),
		PersonalDetailsComplete: resp.GetPersonalDetailsComplete(),
		CompanyDomain:           resp.GetCompanyDomain(),
		WorkEmailVerified:       resp.GetWorkEmailVerified(),
		RatingAverage:           resp.GetRatingAverage(),
		RatingCount:             int(resp.GetRatingCount()),
		MeetupsCompleted:        int(resp.GetMeetupsCompleted()),
		PhoneNumber:             resp.GetPhoneNumber(),
		PersonalEmail:           resp.GetPersonalEmail(),
		LegalName:               resp.GetLegalName(),
		Address:                 resp.GetAddress(),
		LinkedInConnected:       resp.GetLinkedinConnected(),
		IsGuest:                 resp.GetIsGuest(),
		CompanyName:             resp.GetCompanyName(),
	}
}

func sessionFromProto(resp *authv1.SessionResponse) Session {
	return Session{
		UserID:          resp.GetUserId(),
		RefreshToken:    resp.GetRefreshToken(),
		IsNewUser:       resp.GetIsNewUser(),
		FullName:        resp.GetFullName(),
		ProfilePhotoURL: resp.GetProfilePhotoUrl(),
		TrustLevel:      int(resp.GetTrustLevel()),

		SuggestedNameUpdate: resp.GetSuggestedNameUpdate(),
	}
}

// MemberActivity mirrors meetupv1.GetMemberActivityResponse in gateway
// terms: wire-format intent/status strings, Unix seconds for times.
type MemberActivity struct {
	RecentMeetups []MemberMeetup
	Reviews       []MemberReview
	// IdentityHidden: leave the member's name and photo out (#103).
	IdentityHidden bool
}

// MemberMeetup is one finished meetup the member hosted.
type MemberMeetup struct {
	Intent           string
	Status           string
	DayUnixSeconds   int64
	LocationLabel    string
	ParticipantCount int32
	OverallAverage   float64
	ReviewCount      int32
}

// MemberReview is one anonymous review. See meetup.MemberReview.
type MemberReview struct {
	Score int32
	Text  string
	Month string
}

func (c *grpcClient) ScrapeMonolithMetrics(ctx context.Context) ([]byte, error) {
	resp, err := c.ops.ScrapeMetrics(ctx, &opsv1.ScrapeMetricsRequest{})
	if err != nil {
		return nil, err
	}
	return resp.GetText(), nil
}
