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

// publicProfileResponse is what one member may see of ANOTHER: the things
// the app shows on a card already (name, photo, level, record) plus the
// three verification FACTS as booleans. It is a separate type from
// profileResponse on purpose — the private shape carries the phone number,
// personal email, legal name and address, and the safest way to be sure
// none of those ever reach a stranger is a response struct with no field
// to put them in. The client renders the flags as badges ("Professional"
// for LinkedIn, "Official" for a verified work email, "Phone verified"),
// never the underlying value.
type publicProfileResponse struct {
	UserID            string                 `json:"user_id"`
	FullName          string                 `json:"full_name"`
	ProfilePhotoURL   string                 `json:"profile_photo_url"`
	TrustLevel        int                    `json:"trust_level"`
	RatingAverage     float64                `json:"rating_average"`
	RatingCount       int                    `json:"rating_count"`
	MeetupsCompleted  int                    `json:"meetups_completed"`
	LinkedInConnected bool                   `json:"linkedin_connected"`
	WorkEmailVerified bool                   `json:"work_email_verified"`
	PhoneVerified     bool                   `json:"phone_verified"`
	RecentMeetups     []memberMeetupResponse `json:"recent_meetups"`
}

// memberMeetupResponse is one of the member's last few meetups: what,
// when, where, their role, the turnout, the overall rating, and the
// written comments. Comment authors are named only where the VIEWER was
// on that meetup — the monolith blanks them otherwise.
type memberMeetupResponse struct {
	ID                     string                        `json:"id"`
	Intent                 string                        `json:"intent"`
	Status                 string                        `json:"status"`
	WindowStartUnixSeconds int64                         `json:"window_start_unix_seconds"`
	WindowEndUnixSeconds   int64                         `json:"window_end_unix_seconds"`
	LocationLabel          string                        `json:"location_label"`
	Hosted                 bool                          `json:"hosted"`
	ParticipantCount       int32                         `json:"participant_count"`
	OverallAverage         float64                       `json:"overall_average"`
	ReviewCount            int32                         `json:"review_count"`
	ViewerWasIn            bool                          `json:"viewer_was_in"`
	Comments               []memberMeetupCommentResponse `json:"comments"`
}

type memberMeetupCommentResponse struct {
	AuthorName           string `json:"author_name"`
	Note                 string `json:"note"`
	WrittenAtUnixSeconds int64  `json:"written_at_unix_seconds"`
}

// getPublicProfile — GET /v1/users/{id}.
//
// Two monolith calls, in this order on purpose. GetMemberActivity is the
// GATE: it answers PermissionDenied unless the caller shares a meetup with
// this member or the member hosts one, and that decision is made before the
// profile is fetched at all — so a caller who may not open a member learns
// nothing, not even whether the id exists. Only then is the profile read,
// projected through publicProfileResponse so just the public subset is
// ever serialised.
func (h *Handler) getPublicProfile(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	viewerID := middleware.UserIDFromContext(ctx)
	targetID := r.PathValue("id")

	activity, err := h.monolith.GetMemberActivity(ctx, viewerID, targetID)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	profile, err := h.monolith.GetProfile(ctx, targetID)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	recent := make([]memberMeetupResponse, 0, len(activity.RecentMeetups))
	for _, mm := range activity.RecentMeetups {
		comments := make([]memberMeetupCommentResponse, 0, len(mm.Comments))
		for _, c := range mm.Comments {
			comments = append(comments, memberMeetupCommentResponse{
				AuthorName:           c.AuthorName,
				Note:                 c.Note,
				WrittenAtUnixSeconds: c.WrittenAtUnixSeconds,
			})
		}
		recent = append(recent, memberMeetupResponse{
			ID:                     mm.ID,
			Intent:                 mm.Intent,
			Status:                 mm.Status,
			WindowStartUnixSeconds: mm.WindowStartUnixSeconds,
			WindowEndUnixSeconds:   mm.WindowEndUnixSeconds,
			LocationLabel:          mm.LocationLabel,
			Hosted:                 mm.Hosted,
			ParticipantCount:       mm.ParticipantCount,
			OverallAverage:         mm.OverallAverage,
			ReviewCount:            mm.ReviewCount,
			ViewerWasIn:            mm.ViewerWasIn,
			Comments:               comments,
		})
	}
	writeJSON(w, http.StatusOK, publicProfileResponse{
		RecentMeetups:     recent,
		UserID:            profile.UserID,
		FullName:          profile.FullName,
		ProfilePhotoURL:   profile.ProfilePhotoURL,
		TrustLevel:        profile.TrustLevel,
		RatingAverage:     profile.RatingAverage,
		RatingCount:       profile.RatingCount,
		MeetupsCompleted:  profile.MeetupsCompleted,
		LinkedInConnected: profile.LinkedInConnected,
		WorkEmailVerified: profile.WorkEmailVerified,
		PhoneVerified:     profile.PhoneVerified,
	})
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
