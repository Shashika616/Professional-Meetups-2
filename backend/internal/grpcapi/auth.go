// Package grpcapi is the monolith's gRPC surface: one thin adapter per
// module, translating the wire contract (internal/proto) to and from that
// module's plain-Go Service interface, and mapping its sentinel errors to
// gRPC statuses.
//
// This layer exists precisely because ADR-001 §2 makes a module's Go
// interface the boundary: a module never imports protobuf, and re-extracting
// one later means keeping this adapter and pointing it at a standalone
// process instead of an in-process call. It is deliberately dumb — field
// copying, enum mapping, and apperror.ToGRPCStatus, with no business rule of
// its own to get out of sync with the module.
//
// Phases 2 and 3 add meetup.go and billing.go here, registered on the same
// server and the same port (ADR-001 §1: one gRPC target, not three).
package grpcapi

import (
	"context"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
)

// AuthServer adapts the auth module to authv1.AuthServiceServer.
type AuthServer struct {
	authv1.UnimplementedAuthServiceServer
	svc auth.Service
}

// NewAuthServer constructs an AuthServer over svc.
func NewAuthServer(svc auth.Service) *AuthServer {
	return &AuthServer{svc: svc}
}

// sessionToProto builds the wire SessionResponse from the module's
// SessionResult. Note what it does NOT set: access_token and
// access_token_expires_in_seconds don't exist on this message any more
// (ADR-001 §6, reserved field numbers 2 and 4) — the gateway signs the
// access token from the user_id/trust_level below and fills those into its
// own REST response.
func sessionToProto(s auth.SessionResult) *authv1.SessionResponse {
	return &authv1.SessionResponse{
		UserId:          s.UserID,
		RefreshToken:    s.RefreshToken,
		IsNewUser:       s.IsNewUser,
		FullName:        s.FullName,
		ProfilePhotoUrl: s.ProfilePhotoURL,
		TrustLevel:      int32(s.TrustLevel),
	}
}

func profileToProto(p auth.Profile) *authv1.ProfileResponse {
	return &authv1.ProfileResponse{
		UserId:                  p.UserID,
		FullName:                p.FullName,
		ProfilePhotoUrl:         p.ProfilePhotoURL,
		TrustLevel:              int32(p.TrustLevel),
		PhoneVerified:           p.PhoneVerified,
		PersonalEmailVerified:   p.PersonalEmailVerified,
		PersonalDetailsComplete: p.PersonalDetailsComplete,
		CompanyDomain:           p.CompanyDomain,
		WorkEmailVerified:       p.WorkEmailVerified,
		RatingAverage:           p.RatingAverage,
		RatingCount:             int32(p.RatingCount),
		PhoneNumber:             p.PhoneNumber,
		PersonalEmail:           p.PersonalEmail,
		LegalName:               p.LegalName,
		Address:                 p.Address,
	}
}

// providerFromProto maps the wire enum to the module's own provider type.
// IDENTITY_PROVIDER_UNSPECIFIED maps to the empty value, which the module
// rejects — the "is this provider allowed for this operation" rule stays in
// the module (federatedProvider), not here.
func providerFromProto(p authv1.IdentityProviderProto) auth.FederatedProvider {
	switch p {
	case authv1.IdentityProviderProto_IDENTITY_PROVIDER_APPLE:
		return auth.FederatedProviderApple
	case authv1.IdentityProviderProto_IDENTITY_PROVIDER_GOOGLE:
		return auth.FederatedProviderGoogle
	case authv1.IdentityProviderProto_IDENTITY_PROVIDER_LINKEDIN:
		return auth.FederatedProviderLinkedIn
	default:
		return ""
	}
}

// purposeFromProto maps the wire OTP-purpose enum to the module's own. The
// caller-supplied value is passed through unchanged rather than being
// inferred from which RPC was called: the module asserts the two agree,
// which is the check that catches a mismatched-purpose client bug.
func purposeFromProto(p authv1.VerificationPurpose) auth.VerificationPurpose {
	switch p {
	case authv1.VerificationPurpose_VERIFICATION_PURPOSE_PHONE:
		return auth.VerificationPurposePhone
	case authv1.VerificationPurpose_VERIFICATION_PURPOSE_PERSONAL_EMAIL:
		return auth.VerificationPurposePersonalEmail
	case authv1.VerificationPurpose_VERIFICATION_PURPOSE_CORPORATE_EMAIL:
		return auth.VerificationPurposeCorporateEmail
	case authv1.VerificationPurpose_VERIFICATION_PURPOSE_EMAIL_SIGNUP:
		return auth.VerificationPurposeEmailSignup
	case authv1.VerificationPurpose_VERIFICATION_PURPOSE_EMAIL_LOGIN:
		return auth.VerificationPurposeEmailLogin
	default:
		return auth.VerificationPurposeUnspecified
	}
}

func startVerificationRequestFromProto(req *authv1.StartVerificationRequest) auth.StartVerificationRequest {
	return auth.StartVerificationRequest{
		UserID:  req.GetUserId(),
		Purpose: purposeFromProto(req.GetPurpose()),
		Target:  req.GetTarget(),
	}
}

func verifyCodeRequestFromProto(req *authv1.VerifyCodeRequest) auth.VerifyCodeRequest {
	return auth.VerifyCodeRequest{
		UserID:      req.GetUserId(),
		Purpose:     purposeFromProto(req.GetPurpose()),
		Target:      req.GetTarget(),
		Code:        req.GetCode(),
		CompanyName: req.GetCompanyName(),
	}
}

func (s *AuthServer) CompleteFederatedSignup(ctx context.Context, req *authv1.CompleteFederatedSignupRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.CompleteFederatedSignup(ctx, auth.CompleteFederatedSignupRequest{
		Provider:           providerFromProto(req.GetProvider()),
		IDToken:            req.GetIdToken(),
		Nonce:              req.GetNonce(),
		AgeConfirmedOver18: req.GetAgeConfirmedOver_18(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) CompleteLinkedInOnboarding(ctx context.Context, req *authv1.CompleteLinkedInOnboardingRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.CompleteLinkedInOnboarding(ctx, auth.CompleteLinkedInOnboardingRequest{
		AuthorizationCode:  req.GetAuthorizationCode(),
		RedirectURI:        req.GetRedirectUri(),
		AgeConfirmedOver18: req.GetAgeConfirmedOver_18(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) LinkIdentity(ctx context.Context, req *authv1.LinkIdentityRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.LinkIdentity(ctx, auth.LinkIdentityRequest{
		UserID:            req.GetUserId(),
		Provider:          providerFromProto(req.GetProvider()),
		IDToken:           req.GetIdToken(),
		Nonce:             req.GetNonce(),
		AuthorizationCode: req.GetAuthorizationCode(),
		RedirectURI:       req.GetRedirectUri(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) StartEmailSignup(ctx context.Context, req *authv1.StartVerificationRequest) (*authv1.StartVerificationResponse, error) {
	result, err := s.svc.StartEmailSignup(ctx, startVerificationRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.StartVerificationResponse{ResendAfterSeconds: result.ResendAfterSeconds}, nil
}

func (s *AuthServer) CompleteEmailSignup(ctx context.Context, req *authv1.CompleteEmailSignupRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.CompleteEmailSignup(ctx, auth.CompleteEmailSignupRequest{
		Email:              req.GetEmail(),
		Code:               req.GetCode(),
		AgeConfirmedOver18: req.GetAgeConfirmedOver_18(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) StartEmailLogin(ctx context.Context, req *authv1.StartVerificationRequest) (*authv1.StartVerificationResponse, error) {
	result, err := s.svc.StartEmailLogin(ctx, startVerificationRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.StartVerificationResponse{ResendAfterSeconds: result.ResendAfterSeconds}, nil
}

func (s *AuthServer) CompleteEmailLogin(ctx context.Context, req *authv1.VerifyCodeRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.CompleteEmailLogin(ctx, verifyCodeRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) RefreshSession(ctx context.Context, req *authv1.RefreshSessionRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.RefreshSession(ctx, req.GetRefreshToken())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) RevokeSession(ctx context.Context, req *authv1.RevokeSessionRequest) (*authv1.RevokeSessionResponse, error) {
	if err := s.svc.RevokeSession(ctx, req.GetRefreshToken()); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.RevokeSessionResponse{Success: true}, nil
}

func (s *AuthServer) StartPhoneVerification(ctx context.Context, req *authv1.StartVerificationRequest) (*authv1.StartVerificationResponse, error) {
	result, err := s.svc.StartPhoneVerification(ctx, startVerificationRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.StartVerificationResponse{ResendAfterSeconds: result.ResendAfterSeconds}, nil
}

func (s *AuthServer) VerifyPhoneCode(ctx context.Context, req *authv1.VerifyCodeRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.VerifyPhoneCode(ctx, verifyCodeRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) StartPersonalEmailVerification(ctx context.Context, req *authv1.StartVerificationRequest) (*authv1.StartVerificationResponse, error) {
	result, err := s.svc.StartPersonalEmailVerification(ctx, startVerificationRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.StartVerificationResponse{ResendAfterSeconds: result.ResendAfterSeconds}, nil
}

func (s *AuthServer) VerifyPersonalEmailCode(ctx context.Context, req *authv1.VerifyCodeRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.VerifyPersonalEmailCode(ctx, verifyCodeRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) SubmitPersonalDetails(ctx context.Context, req *authv1.SubmitPersonalDetailsRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.SubmitPersonalDetails(ctx, auth.SubmitPersonalDetailsRequest{
		UserID:    req.GetUserId(),
		LegalName: req.GetLegalName(),
		Address:   req.GetAddress(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) StartCorporateEmailVerification(ctx context.Context, req *authv1.StartVerificationRequest) (*authv1.StartVerificationResponse, error) {
	result, err := s.svc.StartCorporateEmailVerification(ctx, startVerificationRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.StartVerificationResponse{ResendAfterSeconds: result.ResendAfterSeconds}, nil
}

func (s *AuthServer) VerifyCorporateEmailCode(ctx context.Context, req *authv1.VerifyCodeRequest) (*authv1.SessionResponse, error) {
	session, err := s.svc.VerifyCorporateEmailCode(ctx, verifyCodeRequestFromProto(req))
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return sessionToProto(session), nil
}

func (s *AuthServer) GetProfile(ctx context.Context, req *authv1.GetProfileRequest) (*authv1.ProfileResponse, error) {
	profile, err := s.svc.GetProfile(ctx, req.GetUserId())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return profileToProto(profile), nil
}

func (s *AuthServer) CompleteProfileSetup(ctx context.Context, req *authv1.CompleteProfileSetupRequest) (*authv1.ProfileResponse, error) {
	profile, err := s.svc.CompleteProfileSetup(ctx, auth.CompleteProfileSetupRequest{
		UserID:       req.GetUserId(),
		FullName:     req.GetFullName(),
		CompanyName:  req.GetCompanyName(),
		CompanyEmail: req.GetCompanyEmail(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return profileToProto(profile), nil
}

func (s *AuthServer) UpdateLastKnownLocation(ctx context.Context, req *authv1.UpdateLastKnownLocationRequest) (*authv1.UpdateLastKnownLocationResponse, error) {
	if err := s.svc.UpdateLastKnownLocation(ctx, auth.UpdateLastKnownLocationRequest{
		UserID: req.GetUserId(),
		Lat:    req.GetLat(),
		Lng:    req.GetLng(),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.UpdateLastKnownLocationResponse{Success: true}, nil
}

func trustedContactToProto(c auth.TrustedContact) *authv1.TrustedContactResponse {
	return &authv1.TrustedContactResponse{
		Id:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		Email:                c.Email,
		CreatedAtUnixSeconds: c.CreatedAtUnixSeconds,
	}
}

func (s *AuthServer) AddTrustedContact(ctx context.Context, req *authv1.AddTrustedContactRequest) (*authv1.TrustedContactResponse, error) {
	contact, err := s.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		UserID:      req.GetUserId(),
		Name:        req.GetName(),
		PhoneNumber: req.GetPhoneNumber(),
		Email:       req.GetEmail(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return trustedContactToProto(contact), nil
}

func (s *AuthServer) ListTrustedContacts(ctx context.Context, req *authv1.ListTrustedContactsRequest) (*authv1.ListTrustedContactsResponse, error) {
	contacts, err := s.svc.ListTrustedContacts(ctx, req.GetUserId())
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	out := make([]*authv1.TrustedContactResponse, 0, len(contacts))
	for _, c := range contacts {
		out = append(out, trustedContactToProto(c))
	}
	return &authv1.ListTrustedContactsResponse{Contacts: out}, nil
}

func (s *AuthServer) RemoveTrustedContact(ctx context.Context, req *authv1.RemoveTrustedContactRequest) (*authv1.RemoveTrustedContactResponse, error) {
	if err := s.svc.RemoveTrustedContact(ctx, auth.RemoveTrustedContactRequest{
		UserID:    req.GetUserId(),
		ContactID: req.GetContactId(),
	}); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.RemoveTrustedContactResponse{Success: true}, nil
}

func (s *AuthServer) TriggerSOS(ctx context.Context, req *authv1.TriggerSOSRequest) (*authv1.TriggerSOSResponse, error) {
	result, err := s.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{
		UserID:         req.GetUserId(),
		ContextMessage: req.GetContextMessage(),
		Latitude:       req.GetLatitude(),
		Longitude:      req.GetLongitude(),
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &authv1.TriggerSOSResponse{ContactsNotified: result.ContactsNotified}, nil
}
