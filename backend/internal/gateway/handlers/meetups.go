package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// meetupResponse is the REST shape for a meetup — Intent/Status/
// MyRequestStatus are plain lowercase strings (meetupclient already
// converted them from proto enums), matching the frontend's IntentType
// wire format.
type meetupResponse struct {
	ID         string `json:"id"`
	HostUserID string `json:"host_user_id"`
	// HostFullName/HostProfilePhotoURL/LocationLat/LocationLng/LocationLabel/
	// the window fields are pointers with omitempty (ADR-028; coordinates
	// joined in round-8 hardening/ADR-029) — absent, not empty string/0,
	// when LockedForViewer is true. LockedForViewer is the field to key
	// lock-treatment UI off of, not their absence.
	HostFullName           *string  `json:"host_full_name,omitempty"`
	HostProfilePhotoURL    *string  `json:"host_profile_photo_url,omitempty"`
	HostTrustLevel         int32    `json:"host_trust_level"`
	HostRatingAverage      float64  `json:"host_rating_average"`
	HostRatingCount        int32    `json:"host_rating_count"`
	Intent                 string   `json:"intent"`
	WindowStartUnixSeconds *int64   `json:"window_start_unix_seconds,omitempty"`
	WindowEndUnixSeconds   *int64   `json:"window_end_unix_seconds,omitempty"`
	LocationLat            *float64 `json:"location_lat,omitempty"`
	LocationLng            *float64 `json:"location_lng,omitempty"`
	LocationLabel          *string  `json:"location_label,omitempty"`
	Capacity               int32    `json:"capacity"`
	AcceptedCount          int32    `json:"accepted_count"`
	Status                 string   `json:"status"`
	CreatedAtUnixSeconds   int64    `json:"created_at_unix_seconds"`
	CancelledAtUnixSeconds *int64   `json:"cancelled_at_unix_seconds,omitempty"`
	ClosedAtUnixSeconds    *int64   `json:"closed_at_unix_seconds,omitempty"`
	IsHostedByMe           bool     `json:"is_hosted_by_me"`
	MyRequestStatus        *string  `json:"my_request_status,omitempty"`
	MyRequestAutoRejected  bool     `json:"my_request_auto_rejected,omitempty"`
	CancellationReason     *string  `json:"cancellation_reason,omitempty"`
	MyRequestID            *string  `json:"my_request_id,omitempty"`
	LockedForViewer        bool     `json:"locked_for_viewer,omitempty"`
}

func meetupFromClient(m monolithclient.Meetup) meetupResponse {
	return meetupResponse{
		ID:                     m.ID,
		HostUserID:             m.HostUserID,
		HostFullName:           m.HostFullName,
		HostProfilePhotoURL:    m.HostProfilePhotoURL,
		HostTrustLevel:         m.HostTrustLevel,
		HostRatingAverage:      m.HostRatingAverage,
		HostRatingCount:        m.HostRatingCount,
		Intent:                 m.Intent,
		WindowStartUnixSeconds: m.WindowStartUnixSeconds,
		WindowEndUnixSeconds:   m.WindowEndUnixSeconds,
		LocationLat:            m.LocationLat,
		LocationLng:            m.LocationLng,
		LocationLabel:          m.LocationLabel,
		Capacity:               m.Capacity,
		AcceptedCount:          m.AcceptedCount,
		Status:                 m.Status,
		CreatedAtUnixSeconds:   m.CreatedAtUnixSeconds,
		CancelledAtUnixSeconds: m.CancelledAtUnixSeconds,
		ClosedAtUnixSeconds:    m.ClosedAtUnixSeconds,
		IsHostedByMe:           m.IsHostedByMe,
		MyRequestStatus:        m.MyRequestStatus,
		MyRequestAutoRejected:  m.MyRequestAutoRejected,
		CancellationReason:     m.CancellationReason,
		MyRequestID:            m.MyRequestID,
		LockedForViewer:        m.LockedForViewer,
	}
}

func meetupsFromClient(meetups []monolithclient.Meetup) []meetupResponse {
	out := make([]meetupResponse, 0, len(meetups))
	for _, m := range meetups {
		out = append(out, meetupFromClient(m))
	}
	return out
}

type meetupRequestResponse struct {
	ID                       string  `json:"id"`
	MeetupID                 string  `json:"meetup_id"`
	RequesterID              string  `json:"requester_id"`
	RequesterFullName        string  `json:"requester_full_name"`
	RequesterProfilePhotoURL string  `json:"requester_profile_photo_url"`
	RequesterTrustLevel      int32   `json:"requester_trust_level"`
	RequesterRatingAverage   float64 `json:"requester_rating_average"`
	RequesterRatingCount     int32   `json:"requester_rating_count"`
	Status                   string  `json:"status"`
	AutoRejected             bool    `json:"auto_rejected"`
	CreatedAtUnixSeconds     int64   `json:"created_at_unix_seconds"`
	ResolvedAtUnixSeconds    *int64  `json:"resolved_at_unix_seconds,omitempty"`
	WithdrawalNote           *string `json:"withdrawal_note,omitempty"`
	// Host visibility into Safety Gate status (ADR-024 §6) — set only for
	// accepted requests whose participant has checked in or declined.
	CheckedInAtUnixSeconds *int64  `json:"checked_in_at_unix_seconds,omitempty"`
	DeclinedAtUnixSeconds  *int64  `json:"declined_at_unix_seconds,omitempty"`
	DeclineReason          *string `json:"decline_reason,omitempty"`
}

func requestFromClient(r monolithclient.MeetupRequest) meetupRequestResponse {
	return meetupRequestResponse{
		ID:                       r.ID,
		MeetupID:                 r.MeetupID,
		RequesterID:              r.RequesterID,
		RequesterFullName:        r.RequesterFullName,
		RequesterProfilePhotoURL: r.RequesterProfilePhotoURL,
		RequesterTrustLevel:      r.RequesterTrustLevel,
		RequesterRatingAverage:   r.RequesterRatingAverage,
		RequesterRatingCount:     r.RequesterRatingCount,
		Status:                   r.Status,
		AutoRejected:             r.AutoRejected,
		CreatedAtUnixSeconds:     r.CreatedAtUnixSeconds,
		ResolvedAtUnixSeconds:    r.ResolvedAtUnixSeconds,
		WithdrawalNote:           r.WithdrawalNote,
		CheckedInAtUnixSeconds:   r.CheckedInAtUnixSeconds,
		DeclinedAtUnixSeconds:    r.DeclinedAtUnixSeconds,
		DeclineReason:            r.DeclineReason,
	}
}

type safetyStateResponse struct {
	MeetupID                  string  `json:"meetup_id"`
	ChecklistAckAtUnixSeconds *int64  `json:"checklist_ack_at_unix_seconds,omitempty"`
	LiveLocationOptIn         bool    `json:"live_location_opt_in"`
	CheckedInAtUnixSeconds    *int64  `json:"checked_in_at_unix_seconds,omitempty"`
	DeclinedAtUnixSeconds     *int64  `json:"declined_at_unix_seconds,omitempty"`
	DeclineReason             *string `json:"decline_reason,omitempty"`
	// Always emitted, never omitempty: the client distinguishes "told
	// nobody" from "field missing", and an absent key would make an empty
	// list indistinguishable from an older server.
	SharedWithContactIDs []string `json:"shared_with_contact_ids"`
}

func safetyStateFromClient(s monolithclient.SafetyState) safetyStateResponse {
	return safetyStateResponse{
		MeetupID:                  s.MeetupID,
		ChecklistAckAtUnixSeconds: s.ChecklistAckAtUnixSeconds,
		LiveLocationOptIn:         s.LiveLocationOptIn,
		CheckedInAtUnixSeconds:    s.CheckedInAtUnixSeconds,
		DeclinedAtUnixSeconds:     s.DeclinedAtUnixSeconds,
		DeclineReason:             s.DeclineReason,
		SharedWithContactIDs:      nonNilStrings(s.SharedWithContactIDs),
	}
}

// nonNilStrings renders an empty list as [] rather than null, so the client
// can treat the field as a list unconditionally.
func nonNilStrings(in []string) []string {
	if in == nil {
		return []string{}
	}
	return in
}

type createMeetupRequest struct {
	Intent                 string  `json:"intent"`
	WindowStartUnixSeconds int64   `json:"window_start_unix_seconds"`
	WindowEndUnixSeconds   int64   `json:"window_end_unix_seconds"`
	LocationLat            float64 `json:"location_lat"`
	LocationLng            float64 `json:"location_lng"`
	LocationLabel          string  `json:"location_label"`
	Capacity               int32   `json:"capacity"`
}

func (h *Handler) createMeetup(w http.ResponseWriter, r *http.Request) {
	var req createMeetupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	ctx := r.Context()
	m, err := h.monolith.CreateMeetup(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)),
		req.Intent, req.WindowStartUnixSeconds, req.WindowEndUnixSeconds, req.LocationLat, req.LocationLng, req.LocationLabel, req.Capacity)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, meetupFromClient(m))
}

// listOpenMeetupsResponse wraps the page + next_cursor, matching the
// frontend's existing PagedResult shape (frontend/meetup-scheduling-
// PLAN.md Step 4).
type listOpenMeetupsResponse struct {
	Meetups    []meetupResponse `json:"meetups"`
	NextCursor string           `json:"next_cursor"`
}

func (h *Handler) listOpenMeetups(w http.ResponseWriter, r *http.Request) {
	// intent is now OPTIONAL: omitted (or empty) means every intent, backing
	// the browse screen's "All" filter. It was required before, so no
	// previously-valid request changes meaning — only a request that used to
	// be a 400 now has a defined result.
	intent := r.URL.Query().Get("intent")
	cursor := r.URL.Query().Get("cursor")

	// within_days is likewise optional; absent or 0 means no time
	// restriction. Parsed strictly rather than defaulted on error, so a typo
	// is a 400 rather than a silently unfiltered list.
	withinDays := int32(0)
	if raw := r.URL.Query().Get("within_days"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "within_days must be an integer")
			return
		}
		withinDays = int32(parsed)
	}
	pageSize := int32(0)
	if raw := r.URL.Query().Get("page_size"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "page_size must be an integer")
			return
		}
		pageSize = int32(parsed)
	}

	// 40km geo-visibility (ADR-021 §2) — required, the device's current
	// on-demand location read. The browse screen never calls this route at
	// all when location is unavailable, so a missing/invalid value here
	// means a malformed request, not a legitimate "no location" case.
	viewerLat, err := strconv.ParseFloat(r.URL.Query().Get("viewer_lat"), 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "viewer_lat query parameter is required and must be a number")
		return
	}
	viewerLng, err := strconv.ParseFloat(r.URL.Query().Get("viewer_lng"), 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "viewer_lng query parameter is required and must be a number")
		return
	}

	ctx := r.Context()
	// ADR-028 — viewer_trust_level is sourced from the verified JWT, the
	// same way user_id already is on the line below; never read from the
	// request's own query params/body, even if a client sends one under
	// that name (nothing here does — TrustLevelFromContext is the only
	// source wired up).
	meetups, nextCursor, err := h.monolith.ListOpenMeetups(ctx, middleware.UserIDFromContext(ctx), intent, cursor, pageSize, viewerLat, viewerLng, int32(middleware.TrustLevelFromContext(ctx)), withinDays)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, listOpenMeetupsResponse{Meetups: meetupsFromClient(meetups), NextCursor: nextCursor})
}

func (h *Handler) getMeetup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// ADR-028 (round-5 hardening) — viewer_trust_level sourced from the
	// verified JWT, same as listOpenMeetups's handler; never read from the
	// request itself.
	m, err := h.monolith.GetMeetup(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, meetupFromClient(m))
}

type listMyMeetupsResponse struct {
	Hosted              []meetupResponse `json:"hosted"`
	Requested           []meetupResponse `json:"requested"`
	HostedNextCursor    string           `json:"hosted_next_cursor"`
	HostedHasMore       bool             `json:"hosted_has_more"`
	RequestedNextCursor string           `json:"requested_next_cursor"`
	RequestedHasMore    bool             `json:"requested_has_more"`
}

func (h *Handler) listMyMeetups(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	hostedCursor := r.URL.Query().Get("hosted_cursor")
	requestedCursor := r.URL.Query().Get("requested_cursor")
	hosted, requested, hostedNextCursor, hostedHasMore, requestedNextCursor, requestedHasMore, err :=
		h.monolith.ListMyMeetups(ctx, middleware.UserIDFromContext(ctx), hostedCursor, requestedCursor)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, listMyMeetupsResponse{
		Hosted:              meetupsFromClient(hosted),
		Requested:           meetupsFromClient(requested),
		HostedNextCursor:    hostedNextCursor,
		HostedHasMore:       hostedHasMore,
		RequestedNextCursor: requestedNextCursor,
		RequestedHasMore:    requestedHasMore,
	})
}

type listActiveMeetupsResponse struct {
	Meetups []meetupResponse `json:"meetups"`
}

// listActiveMeetups backs the active-meetups dashboard/persistent card
// (ADR-025 §2).
func (h *Handler) listActiveMeetups(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	meetups, err := h.monolith.ListActiveMeetups(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, listActiveMeetupsResponse{Meetups: meetupsFromClient(meetups)})
}

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
		writeError(w, http.StatusBadRequest, "invalid request body")
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
		writeError(w, http.StatusBadRequest, "invalid request body")
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

type registerDeviceTokenRequest struct {
	FcmToken string `json:"fcm_token"`
}

func (h *Handler) registerDeviceToken(w http.ResponseWriter, r *http.Request) {
	var req registerDeviceTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
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

type setLiveLocationOptInRequest struct {
	OptIn bool `json:"opt_in"`
}

func (h *Handler) setLiveLocationOptIn(w http.ResponseWriter, r *http.Request) {
	var req setLiveLocationOptInRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	ctx := r.Context()
	state, err := h.monolith.SetLiveLocationOptIn(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.OptIn)
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
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if len(req.ContactIDs) == 0 {
		writeError(w, http.StatusBadRequest, "pick at least one trusted contact")
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
		writeError(w, http.StatusBadRequest, "invalid request body")
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
		writeError(w, http.StatusBadRequest, "invalid request body")
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

// ratableParticipantResponse mirrors monolithclient.RatableParticipant
// (ADR-015) — the host + accepted requesters of a meetup, minus the viewer,
// each flagged with whether the viewer already rated them.
type ratableParticipantResponse struct {
	UserID          string  `json:"user_id"`
	FullName        string  `json:"full_name"`
	ProfilePhotoURL string  `json:"profile_photo_url"`
	TrustLevel      int32   `json:"trust_level"`
	AlreadyRated    bool    `json:"already_rated"`
	ContextNote     *string `json:"context_note,omitempty"`
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
	ProfilePhotoURL string `json:"profile_photo_url"`
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
			ProfilePhotoURL: p.ProfilePhotoURL,
			TrustLevel:      p.TrustLevel,
		})
	}
	writeJSON(w, http.StatusOK, listMeetupParticipantsResponse{
		Participants: out,
		Redacted:     result.Redacted,
		TotalCount:   result.TotalCount,
	})
}

type ratingTraitResponse struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Emoji string `json:"emoji"`
	// Sorts the trait into the review screen's Negative tab. Server-owned
	// so a client never decides which words count as criticism.
	Negative bool `json:"negative"`
}

type listRatableParticipantsResponse struct {
	Participants []ratableParticipantResponse `json:"participants"`
	// The trait vocabulary, sent with the list because the review screen
	// renders both together and would otherwise need a second round trip
	// before it could draw anything.
	AvailableTraits []ratingTraitResponse `json:"available_traits"`
}

func (h *Handler) listRatableParticipants(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	// Trust level from the verified JWT, exactly as listMeetupParticipants
	// above does — it gates a redaction, so it is precisely the value a
	// modified client would want to supply.
	result, err := h.monolith.ListRatableParticipants(
		ctx,
		r.PathValue("id"),
		middleware.UserIDFromContext(ctx),
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	out := make([]ratableParticipantResponse, 0, len(result.Participants))
	for _, p := range result.Participants {
		out = append(out, ratableParticipantResponse{
			UserID:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoURL: p.ProfilePhotoURL,
			TrustLevel:      p.TrustLevel,
			AlreadyRated:    p.AlreadyRated,
			ContextNote:     p.ContextNote,
		})
	}
	traits := make([]ratingTraitResponse, 0, len(result.AvailableTraits))
	for _, t := range result.AvailableTraits {
		traits = append(traits, ratingTraitResponse{Key: t.Key, Label: t.Label, Emoji: t.Emoji, Negative: t.Negative})
	}
	writeJSON(w, http.StatusOK, listRatableParticipantsResponse{Participants: out, AvailableTraits: traits})
}

type reviewParticipantRequest struct {
	UserID string   `json:"user_id"`
	Score  int32    `json:"score"`
	Traits []string `json:"traits"`
}

type submitMeetupReviewRequest struct {
	OverallScore int32                      `json:"overall_score"`
	Notes        *string                    `json:"notes"`
	Participants []reviewParticipantRequest `json:"participants"`
}

func (h *Handler) submitMeetupReview(w http.ResponseWriter, r *http.Request) {
	var req submitMeetupReviewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	participants := make([]monolithclient.ReviewParticipantInput, 0, len(req.Participants))
	for _, p := range req.Participants {
		participants = append(participants, monolithclient.ReviewParticipantInput{
			UserID: p.UserID, Score: p.Score, Traits: p.Traits,
		})
	}

	ctx := r.Context()
	if err := h.monolith.SubmitMeetupReview(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.OverallScore, req.Notes, participants); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}

type reviewedParticipantResponse struct {
	UserID          string   `json:"user_id"`
	FullName        string   `json:"full_name"`
	ProfilePhotoURL string   `json:"profile_photo_url"`
	Score           int32    `json:"score"`
	Traits          []string `json:"traits"`
}

type meetupReviewResponse struct {
	Completed    bool                          `json:"completed"`
	OverallScore int32                         `json:"overall_score"`
	Notes        *string                       `json:"notes,omitempty"`
	Participants []reviewedParticipantResponse `json:"participants"`
}

func (h *Handler) getMeetupReview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	review, err := h.monolith.GetMeetupReview(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	participants := make([]reviewedParticipantResponse, 0, len(review.Participants))
	for _, p := range review.Participants {
		participants = append(participants, reviewedParticipantResponse{
			UserID:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoURL: p.ProfilePhotoURL,
			Score:           p.Score,
			Traits:          p.Traits,
		})
	}
	writeJSON(w, http.StatusOK, meetupReviewResponse{
		Completed:    review.Completed,
		OverallScore: review.OverallScore,
		Notes:        review.Notes,
		Participants: participants,
	})
}

type submitRatingRequest struct {
	RatedUserID string `json:"rated_user_id"`
	Score       int32  `json:"score"`
}

func (h *Handler) submitRating(w http.ResponseWriter, r *http.Request) {
	var req submitRatingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	ctx := r.Context()
	if err := h.monolith.SubmitRating(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.RatedUserID, req.Score); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}

func (h *Handler) closeMeetup(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	m, err := h.monolith.CloseMeetup(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, meetupFromClient(m))
}

type cancelMeetupRequest struct {
	// Required (ADR-020 §3) — the meetup service rejects an empty reason.
	Reason string `json:"reason"`
}

func (h *Handler) cancelMeetup(w http.ResponseWriter, r *http.Request) {
	var req cancelMeetupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	ctx := r.Context()
	if err := h.monolith.CancelMeetup(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.Reason); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}
