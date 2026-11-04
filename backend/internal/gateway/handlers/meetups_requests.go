package handlers

import (
	"encoding/json"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
)

type listMeetupRequestsResponse struct {
	Requests []meetupRequestResponse `json:"requests"`
}

func (h *Handler) listMeetupRequests(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	requests, err := h.monolith.ListMeetupRequests(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	out := make([]meetupRequestResponse, 0, len(requests))
	for _, req := range requests {
		out = append(out, requestFromClient(req))
	}
	writeJSON(w, http.StatusOK, listMeetupRequestsResponse{Requests: out})
}

func (h *Handler) requestToJoin(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	req, err := h.monolith.RequestToJoin(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, requestFromClient(req))
}

type successResponse struct {
	Success bool `json:"success"`
}

type withdrawRequestRequest struct {
	// Optional (ADR-020 §4) — the frontend always sends the field, empty
	// string when the user left it blank, same convention as every other
	// optional-text-field request body in this handler package.
	Note string `json:"note"`
}

func (h *Handler) withdrawRequest(w http.ResponseWriter, r *http.Request) {
	var req withdrawRequestRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.monolith.WithdrawRequest(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.Note); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}

type respondToRequestRequest struct {
	Accept bool `json:"accept"`
}

func (h *Handler) respondToRequest(w http.ResponseWriter, r *http.Request) {
	var req respondToRequestRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	updated, err := h.monolith.RespondToRequest(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.Accept)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, requestFromClient(updated))
}

type userNotificationResponse struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Type      string `json:"type"`
	MeetupID  string `json:"meetup_id"`
	CreatedAt int64  `json:"created_at"`
	Delivered bool   `json:"delivered"`
}

type listNotificationsResponse struct {
	Notifications []userNotificationResponse `json:"notifications"`
}

func (h *Handler) listNotifications(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	rows, err := h.monolith.ListNotifications(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	out := make([]userNotificationResponse, 0, len(rows))
	for _, n := range rows {
		out = append(out, userNotificationResponse{
			ID:        n.ID,
			Title:     n.Title,
			Body:      n.Body,
			Type:      n.Type,
			MeetupID:  n.MeetupID,
			CreatedAt: n.CreatedAt,
			Delivered: n.Delivered,
		})
	}
	writeJSON(w, http.StatusOK, listNotificationsResponse{Notifications: out})
}

type meetupParticipantResponse struct {
	UserID          string `json:"user_id"`
	IsHost          bool   `json:"is_host"`
	FullName        string `json:"full_name"`
	ProfilePhotoURL string `json:"photo_url"`
	TrustLevel      int32  `json:"trust_level"`
}

type listMeetupParticipantsResponse struct {
	Participants []meetupParticipantResponse `json:"participants"`
	Redacted     bool                        `json:"redacted"`
	TotalCount   int32                       `json:"total_count"`
}

func (h *Handler) listMeetupParticipants(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// Both the viewer and their trust level come from the verified JWT. The
	// trust level decides whether identities are disclosed at all, so it is
	// exactly the value a modified client would want to supply.
	result, err := h.monolith.ListMeetupParticipants(
		ctx,
		r.PathValue("id"),
		middleware.UserIDFromContext(ctx),
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	out := make([]meetupParticipantResponse, 0, len(result.Participants))
	for _, p := range result.Participants {
		out = append(out, meetupParticipantResponse{
			UserID:          p.UserID,
			IsHost:          p.IsHost,
			FullName:        p.FullName,
			ProfilePhotoURL: photoPath(p.ProfilePhotoURL),
			TrustLevel:      p.TrustLevel,
		})
	}
	writeJSON(w, http.StatusOK, listMeetupParticipantsResponse{
		Participants: out,
		Redacted:     result.Redacted,
		TotalCount:   result.TotalCount,
	})
}
