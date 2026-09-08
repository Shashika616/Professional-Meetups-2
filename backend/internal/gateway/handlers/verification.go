package handlers

import (
	"encoding/json"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

type startVerificationResponse struct {
	ResendAfterSeconds int32 `json:"resend_after_seconds"`
}

type phoneStartRequest struct {
	PhoneNumber string `json:"phone_number"`
}

func (h *Handler) startPhoneVerification(w http.ResponseWriter, r *http.Request) {
	var req phoneStartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	resendAfter, err := h.monolith.StartPhoneVerification(r.Context(), middleware.UserIDFromContext(r.Context()), req.PhoneNumber)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, startVerificationResponse{ResendAfterSeconds: resendAfter})
}

type phoneVerifyRequest struct {
	PhoneNumber string `json:"phone_number"`
	Code        string `json:"code"`
}

func (h *Handler) verifyPhoneCode(w http.ResponseWriter, r *http.Request) {
	var req phoneVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.VerifyPhoneCode(r.Context(), middleware.UserIDFromContext(r.Context()), req.PhoneNumber, req.Code)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	h.writeSession(w, session)
}

type emailStartRequest struct {
	Email string `json:"email"`
}

func (h *Handler) startPersonalEmailVerification(w http.ResponseWriter, r *http.Request) {
	var req emailStartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	resendAfter, err := h.monolith.StartPersonalEmailVerification(r.Context(), middleware.UserIDFromContext(r.Context()), req.Email)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, startVerificationResponse{ResendAfterSeconds: resendAfter})
}

type emailVerifyRequest struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

func (h *Handler) verifyPersonalEmailCode(w http.ResponseWriter, r *http.Request) {
	var req emailVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.VerifyPersonalEmailCode(r.Context(), middleware.UserIDFromContext(r.Context()), req.Email, req.Code)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	h.writeSession(w, session)
}

type personalDetailsRequest struct {
	LegalName string `json:"legal_name"`
	Address   string `json:"address"`
}

func (h *Handler) submitPersonalDetails(w http.ResponseWriter, r *http.Request) {
	var req personalDetailsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.SubmitPersonalDetails(r.Context(), middleware.UserIDFromContext(r.Context()), req.LegalName, req.Address)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	h.writeSession(w, session)
}

func (h *Handler) startCorporateEmailVerification(w http.ResponseWriter, r *http.Request) {
	var req emailStartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	resendAfter, err := h.monolith.StartCorporateEmailVerification(r.Context(), middleware.UserIDFromContext(r.Context()), req.Email)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, startVerificationResponse{ResendAfterSeconds: resendAfter})
}

type corporateEmailVerifyRequest struct {
	Email       string `json:"email"`
	Code        string `json:"code"`
	CompanyName string `json:"company_name"` // ADR-019 §3's name-vs-domain cross-check
}

func (h *Handler) verifyCorporateEmailCode(w http.ResponseWriter, r *http.Request) {
	var req corporateEmailVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.VerifyCorporateEmailCode(r.Context(), middleware.UserIDFromContext(r.Context()), req.Email, req.Code, req.CompanyName)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	h.writeSession(w, session)
}

// profileResponse is returned only to the authenticated caller about their
// own account (userID always comes from middleware.UserIDFromContext, never
// the request body — see getProfile below). ADR-023 §4 corrected an
// over-strict reading of Verification Model § 1 ("never reveal ... to
// other users") that had been implemented as "never to anyone" — the four
// raw fields below are the account owner's own data, never exposed via any
// other endpoint or about any other user. No raw work-email field exists
// here, or ever will (ADR-003 is a separate, stronger rule).
type profileResponse struct {
	UserID                  string `json:"user_id"`
	FullName                string `json:"full_name"`
	ProfilePhotoURL         string `json:"profile_photo_url"`
	TrustLevel              int    `json:"trust_level"`
	PhoneVerified           bool   `json:"phone_verified"`
	PersonalEmailVerified   bool   `json:"personal_email_verified"`
	PersonalDetailsComplete bool   `json:"personal_details_complete"`
	CompanyDomain           string `json:"company_domain"`
	WorkEmailVerified       bool   `json:"work_email_verified"`
	PhoneNumber             string `json:"phone_number"`
	PersonalEmail           string `json:"personal_email"`
	LegalName               string `json:"legal_name"`
	Address                 string `json:"address"`
	// ADR-002 — the client can no longer infer this from trust_level.
	LinkedInConnected bool `json:"linkedin_connected"`
	// ADR-002 §3/§2 — guest chrome and hosting-unlock prefill.
	IsGuest     bool   `json:"is_guest"`
	CompanyName string `json:"company_name"`

	// The profile screen's stats row.
	//
	// rating_average/rating_count were MISSING from this struct, which is
	// why the client's rating always read as zero: the monolith populated
	// them, monolithclient.Profile carried them, and this response object —
	// the only thing the app actually sees — silently dropped them on the
	// floor. The client's RATING chip could therefore only ever render its
	// "no ratings yet" dash, for every user, forever.
	RatingAverage float64 `json:"rating_average"`
	RatingCount   int     `json:"rating_count"`
	// meetups_completed is new (auth/0005). It replaces a hardcoded literal
	// on the client, which showed every account — including one created
	// seconds ago — the same fixed number.
	MeetupsCompleted int `json:"meetups_completed"`
}

func (h *Handler) getProfile(w http.ResponseWriter, r *http.Request) {
	profile, err := h.monolith.GetProfile(r.Context(), middleware.UserIDFromContext(r.Context()))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, profileResponseFromClient(profile))
}

// profileResponseFromClient is shared by getProfile and
// completeProfileSetup (handlers.go, ADR-019 §2) — both return the same
// shape, one conversion, not two near-duplicates that could drift.
func profileResponseFromClient(profile monolithclient.Profile) profileResponse {
	return profileResponse{
		UserID:                  profile.UserID,
		FullName:                profile.FullName,
		ProfilePhotoURL:         profile.ProfilePhotoURL,
		TrustLevel:              profile.TrustLevel,
		PhoneVerified:           profile.PhoneVerified,
		PersonalEmailVerified:   profile.PersonalEmailVerified,
		PersonalDetailsComplete: profile.PersonalDetailsComplete,
		CompanyDomain:           profile.CompanyDomain,
		WorkEmailVerified:       profile.WorkEmailVerified,
		PhoneNumber:             profile.PhoneNumber,
		PersonalEmail:           profile.PersonalEmail,
		LegalName:               profile.LegalName,
		Address:                 profile.Address,
		LinkedInConnected:       profile.LinkedInConnected,
		IsGuest:                 profile.IsGuest,
		CompanyName:             profile.CompanyName,
		RatingAverage:           profile.RatingAverage,
		RatingCount:             profile.RatingCount,
		MeetupsCompleted:        profile.MeetupsCompleted,
	}
}
