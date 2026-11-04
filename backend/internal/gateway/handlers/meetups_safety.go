package handlers

import (
	"encoding/json"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
)

type registerDeviceTokenRequest struct {
	FcmToken string `json:"fcm_token"`
}

func (h *Handler) registerDeviceToken(w http.ResponseWriter, r *http.Request) {
	var req registerDeviceTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.monolith.RegisterDeviceToken(ctx, middleware.UserIDFromContext(ctx), req.FcmToken); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}

// getSafetyState used to call h.monolith.GetSafetyState with no identity at
// all — the actual authorization gap ADR-024 fixes server-side, but the
// gateway's own call site was part of it: GetSafetyStateRequest had nowhere
// to put a user_id even if this handler had wanted to source one. Fixed to
// match every other Safety Gate handler below (identity from the verified
// JWT, never the request body).
func (h *Handler) getSafetyState(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	state, err := h.monolith.GetSafetyState(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, safetyStateFromClient(state))
}

func (h *Handler) acknowledgeSafetyChecklist(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	state, err := h.monolith.AcknowledgeSafetyChecklist(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, safetyStateFromClient(state))
}

type shareWithContactsRequest struct {
	ContactIDs []string `json:"contact_ids"`
}

func (h *Handler) shareWithContacts(w http.ResponseWriter, r *http.Request) {
	var req shareWithContactsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	if len(req.ContactIDs) == 0 {
		writeError(w, http.StatusBadRequest, "Pick at least one trusted contact.")
		return
	}

	ctx := r.Context()
	state, err := h.monolith.ShareWithContacts(
		ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.ContactIDs,
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, safetyStateFromClient(state))
}

func (h *Handler) checkIn(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	state, err := h.monolith.CheckIn(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, safetyStateFromClient(state))
}

type declineCheckInRequest struct {
	Reason string `json:"reason"`
}

func (h *Handler) declineCheckIn(w http.ResponseWriter, r *http.Request) {
	var req declineCheckInRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	state, err := h.monolith.DeclineCheckIn(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.Reason)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, safetyStateFromClient(state))
}

type submitMeetupFeedbackRequest struct {
	Happened        bool    `json:"happened"`
	FeltSafe        *bool   `json:"felt_safe"`
	ProfileAccurate *bool   `json:"profile_accurate"`
	WouldMeetAgain  *bool   `json:"would_meet_again"`
	Notes           *string `json:"notes"`
}

func (h *Handler) submitMeetupFeedback(w http.ResponseWriter, r *http.Request) {
	var req submitMeetupFeedbackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.monolith.SubmitMeetupFeedback(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx),
		req.Happened, req.FeltSafe, req.ProfileAccurate, req.WouldMeetAgain, req.Notes); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}
