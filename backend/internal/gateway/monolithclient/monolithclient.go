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

	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"

	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
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
	PhoneNumber             string
	PersonalEmail           string
	LegalName               string
	Address                 string
}

// TrustedContact is this package's own representation of a trusted contact.
type TrustedContact struct {
	ID                   string
	Name                 string
	PhoneNumber          string
	Email                string
	CreatedAtUnixSeconds int64
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
	CompleteFederatedSignup(ctx context.Context, provider, idToken, nonce string, ageConfirmedOver18 bool) (Session, error)
	CompleteLinkedInOnboarding(ctx context.Context, authorizationCode, redirectURI string, ageConfirmedOver18 bool) (Session, error)
	// LinkIdentity links an identity to the caller's already-authenticated
	// account. idToken/nonce are used for apple/google, authorizationCode/
	// redirectURI for linkedin — the caller passes only the set relevant to
	// provider, the rest is ignored server-side.
	LinkIdentity(ctx context.Context, userID, provider, idToken, nonce, authorizationCode, redirectURI string) (Session, error)
	StartEmailSignup(ctx context.Context, email string) (resendAfterSeconds int32, err error)
	CompleteEmailSignup(ctx context.Context, email, code string, ageConfirmedOver18 bool) (Session, error)
	StartEmailLogin(ctx context.Context, email string) (resendAfterSeconds int32, err error)
	CompleteEmailLogin(ctx context.Context, email, code string) (Session, error)
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
	CompleteProfileSetup(ctx context.Context, userID, fullName, companyName, companyEmail string) (Profile, error)

	UpdateLastKnownLocation(ctx context.Context, userID string, lat, lng float64) error

	AddTrustedContact(ctx context.Context, userID, name, phoneNumber, email string) (TrustedContact, error)
	ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error)
	RemoveTrustedContact(ctx context.Context, userID, contactID string) error
	// TriggerSOS returns how many trusted contacts were actually alerted.
	TriggerSOS(ctx context.Context, userID, contextMessage string, lat, lng float64) (contactsNotified int32, err error)

	Close() error
}

type grpcClient struct {
	conn *grpc.ClientConn
	auth authv1.AuthServiceClient
}

// New connects to the monolith at addr (e.g. "monolith:9090"), blocking
// until the connection is ready or connectTimeout elapses.
func New(addr string) (Client, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
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

	return &grpcClient{conn: conn, auth: authv1.NewAuthServiceClient(conn)}, nil
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
	ctx context.Context, provider, idToken, nonce string, ageConfirmedOver18 bool,
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
	})
	if err != nil {
		return Session{}, err
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
		return Session{}, err
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

func (c *grpcClient) AddTrustedContact(ctx context.Context, userID, name, phoneNumber, email string) (TrustedContact, error) {
	resp, err := c.auth.AddTrustedContact(ctx, &authv1.AddTrustedContactRequest{
		UserId: userID, Name: name, PhoneNumber: phoneNumber, Email: email,
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

func (c *grpcClient) TriggerSOS(ctx context.Context, userID, contextMessage string, lat, lng float64) (int32, error) {
	resp, err := c.auth.TriggerSOS(ctx, &authv1.TriggerSOSRequest{
		UserId: userID, ContextMessage: contextMessage, Latitude: lat, Longitude: lng,
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
		Email:                resp.GetEmail(),
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
		PhoneNumber:             resp.GetPhoneNumber(),
		PersonalEmail:           resp.GetPersonalEmail(),
		LegalName:               resp.GetLegalName(),
		Address:                 resp.GetAddress(),
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
	}
}
