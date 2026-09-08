package auth

// Request/response types for the auth module's Service interface, translated
// mechanically from the proto message shapes in
// ../Professional-Meetups/backend/proto/auth/v1/auth.proto — same fields,
// same meanings, expressed as plain Go structs.
//
// Why plain structs and not the generated protobuf types: ADR-001 §2 makes a
// module's single Go interface the boundary, and §7 keeps protobuf for the
// gateway<->monolith hop only ("not reused for anything module-to-module
// inside the monolith"). internal/grpcapi is the one place that translates
// between these and the wire types, which is exactly the layer that would be
// replaced by a real gRPC server if this module were ever re-extracted.
//
// Two deliberate divergences from a 1:1 translation, both documented at the
// field:
//   - SessionResult carries no access token (ADR-001 §6 — the gateway signs).
//   - The federated requests carry a Nonce (a security fix, see identity.go).

// FederatedProvider identifies which federated identity mechanism a call
// concerns. Deliberately a separate type from repository.IdentityProvider
// (the user_identities DB enum, Apple/Google only) — LinkedIn has no row in
// that table at all; its identity lives on users.linkedin_sub directly, both
// for direct signup and Profile-linking, so it needs a value here it
// deliberately doesn't have there.
type FederatedProvider string

const (
	FederatedProviderApple    FederatedProvider = "apple"
	FederatedProviderGoogle   FederatedProvider = "google"
	FederatedProviderLinkedIn FederatedProvider = "linkedin"
)

// VerificationPurpose is the module's own copy of the shared OTP purpose
// enum — one OTP mechanism, five purposes, not five mechanisms. It mirrors
// repository.VerificationPurpose value-for-value but is a distinct type, so
// the module's public interface doesn't hand callers a persistence-layer
// type.
//
// It is redundant with which method is called (StartPhoneVerification vs.
// StartPersonalEmailVerification, etc.) by design: the service layer asserts
// the two agree, catching a mismatched-purpose client bug rather than
// silently trusting the method choice alone.
type VerificationPurpose string

const (
	VerificationPurposeUnspecified    VerificationPurpose = ""
	VerificationPurposePhone          VerificationPurpose = "phone"
	VerificationPurposePersonalEmail  VerificationPurpose = "personal_email"
	VerificationPurposeCorporateEmail VerificationPurpose = "corporate_email"
	VerificationPurposeEmailSignup    VerificationPurpose = "email_signup"
	VerificationPurposeEmailLogin     VerificationPurpose = "email_login"
)

// SessionResult is what every session-issuing method returns — the identity
// facts the caller needs to mint a session, NOT a minted session.
//
// ADR-001 §6: there is deliberately no AccessToken field. The monolith never
// holds the JWT private key, so it cannot sign one; the gateway takes UserID
// and TrustLevel from here and produces the token itself. TrustLevel is
// therefore load-bearing on this type in a way it never was on the source's
// SessionResponse (where the auth service put it straight into the token it
// signed internally, so it never crossed a wire).
//
// RefreshToken IS here: unlike an access token, it is a database row this
// module owns and rotates, of which only the SHA-256 hash is ever stored, so
// the raw value has to come back from whoever generated it (phase plan Step
// 3, "the new refresh-token row's raw value").
type SessionResult struct {
	UserID          string
	RefreshToken    string
	IsNewUser       bool
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
}

// CompleteFederatedSignupRequest creates a Level 0 account via Sign in with
// Apple / Google Sign-In, or logs in if this (provider, subject) already has
// one. Provider must be apple or google — LinkedIn's own direct-signup path
// is CompleteLinkedInOnboarding.
type CompleteFederatedSignupRequest struct {
	Provider FederatedProvider
	IDToken  string
	// Nonce is the RAW, client-generated per-sign-in-attempt value whose
	// SHA-256 the id_token carries as its `nonce` claim — the pre-image, not
	// the claim itself (identity.Provider.Verify explains why that
	// distinction is the entire protection). NOT present in the source's
	// proto; added here as the security fix
	// docs/security-review-framework.md's Authenticity section requires.
	// Required: an empty nonce is rejected, not treated as "skip the check".
	Nonce              string
	AgeConfirmedOver18 bool
}

// CompleteLinkedInOnboardingRequest creates a Level 1 account directly via
// LinkedIn, or logs in if this linkedin_sub already has one. No PKCE
// verifier: LinkedIn's OIDC product rejects the token exchange outright when
// code_challenge/code_verifier are present, and this is a confidential
// client (the secret lives only in this process), which is what PKCE exists
// to substitute for on a public client.
type CompleteLinkedInOnboardingRequest struct {
	AuthorizationCode  string
	RedirectURI        string
	AgeConfirmedOver18 bool
}

// LinkIdentityRequest links an additional identity to the CALLER's
// already-authenticated account. UserID is always set by the gateway from
// the verified JWT, never client-supplied — the same rule for every
// authenticated method in this package.
type LinkIdentityRequest struct {
	UserID   string
	Provider FederatedProvider
	// Apple/Google branch: native-SDK id_token plus its nonce (see
	// CompleteFederatedSignupRequest.Nonce).
	IDToken string
	Nonce   string
	// LinkedIn branch: its flow is authorization-code based, never hands the
	// app an id_token, so it needs its own pair of fields on this one
	// generic request rather than a second method.
	AuthorizationCode string
	RedirectURI       string
}

// StartVerificationRequest starts any of the five OTP flows. UserID is "" for
// the two unauthenticated purposes (email_signup, email_login), where no
// account is known — or may exist — yet.
type StartVerificationRequest struct {
	UserID  string
	Purpose VerificationPurpose
	Target  string // phone number (E.164) or email address to verify
}

// StartVerificationResult is intentionally near-empty — it never echoes the
// code, or any indication of whether Target already exists on another
// account (a user-enumeration leak).
type StartVerificationResult struct {
	ResendAfterSeconds int32
}

// VerifyCodeRequest completes any of the OTP flows.
type VerifyCodeRequest struct {
	UserID  string
	Purpose VerificationPurpose
	Target  string // must match what the Start call was made with
	Code    string
	// CompanyName is only meaningful for the corporate-email purpose (the
	// name-vs-domain cross-check against known_companies); ignored for every
	// other purpose, and required in practice for corporate email —
	// VerifyCorporateEmailCode rejects an empty value itself.
	CompanyName string
}

// CompleteEmailSignupRequest verifies the OTP sent by StartEmailSignup and
// creates — or recovers — an account. There is no password field, and never
// will be: the email path is OTP-only.
type CompleteEmailSignupRequest struct {
	Email              string
	Code               string
	AgeConfirmedOver18 bool
}

// GuestSignupRequest carries only the 18+ attestation (ADR-002 §3). There is
// deliberately nothing else in it: a guest supplies no email, no phone, no
// name — the display handle is generated server-side, never client-supplied,
// so a caller cannot pick their own "Guest-" name or impersonate one.
type GuestSignupRequest struct {
	AgeConfirmedOver18 bool
}

// SubmitPersonalDetailsRequest is the one Level 2 step with no OTP — legal
// name and address are self-reported.
type SubmitPersonalDetailsRequest struct {
	UserID    string
	LegalName string
	Address   string
}

// CompleteProfileSetupRequest backs the mandatory post-auth screen every one
// of the four sign-up/login paths calls once, right after auth succeeds.
type CompleteProfileSetupRequest struct {
	UserID       string
	FullName     string // always required
	CompanyName  string // optional; only meaningful paired with CompanyEmail
	CompanyEmail string // optional; if set, kicks off corporate-email verification-start
}

// Profile is returned only to the authenticated caller about their own
// account (UserID is always gateway-set from the verified JWT). The four raw
// PII fields (PhoneNumber, PersonalEmail, LegalName, Address) are the
// owner's own data and are exposed via no other method and about no other
// user. Work email is a stronger rule: it has no raw field here and never
// will — it is never stored past the verification round-trip at all.
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
	// MeetupsCompleted is the profile's "MEETUPS" figure. Cached here,
	// owned by the meetup module — see UpsertMeetupsCompletedCache.
	MeetupsCompleted int
	PhoneNumber      string
	PersonalEmail    string
	LegalName        string
	Address          string

	// LinkedInConnected is a derived boolean, never the raw linkedin_sub.
	//
	// REQUIRED BY ADR-002, not optional polish: the client used to derive
	// "LinkedIn is connected" from trustLevel >= 1, which was sound under the
	// old ladder because Level 1 was reachable ONLY via LinkedIn. ADR-002 §2
	// makes every real signup path Level 1, so that inference now reports
	// true for an Apple/Google/email account that has never connected
	// LinkedIn — which would show the Level 2 checklist as further along than
	// it is and unlock rows the server rejects (requireLinkedIn, deliberately
	// unchanged). The client needs the real signal.
	LinkedInConnected bool

	// IsGuest lets the client render "you're browsing as a guest" chrome and
	// route a guest to signup instead of to the Level 2 checklist. Exposed
	// rather than left for the client to infer from TrustLevel == 0: those
	// two happen to coincide today, but they are different questions, and a
	// client that guesses one from the other silently breaks if the ladder
	// ever changes again (ADR-002 §2 changed it once already).
	IsGuest bool

	// CompanyName is exposed so the hosting-unlock page can prefill it when
	// a company was already registered once — the same reason CompanyDomain
	// is already here. Self-view only, like every other field on this struct.
	CompanyName string
}

// UpdateLastKnownLocationRequest carries the browse screen's on-demand
// location read — self-only data, no participant/trust-level gate.
type UpdateLastKnownLocationRequest struct {
	UserID string
	Lat    float64
	Lng    float64
}
