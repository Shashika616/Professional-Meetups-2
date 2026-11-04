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
	HostProfilePhotoURL    *string  `json:"host_photo_url,omitempty"`
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
		HostProfilePhotoURL:    photoPathPtr(m.HostProfilePhotoURL),
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
	RequesterProfilePhotoURL string  `json:"requester_photo_url"`
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
		RequesterProfilePhotoURL: photoPath(r.RequesterProfilePhotoURL),
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
	// Plan 29 §3.5: the cost the app showed from POST /v1/billing/quote.
	// Absent from builds without the credits UI. Never a price the server
	// charges by — only what it checks its own price against.
	ExpectedCost *int64 `json:"expected_cost"`
	PriceVersion int32  `json:"price_version"`
}

func (h *Handler) createMeetup(w http.ResponseWriter, r *http.Request) {
	var req createMeetupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	key, ok := idempotencyKey(r)
	if !ok {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	m, err := h.monolith.CreateMeetup(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)),
		req.Intent, req.WindowStartUnixSeconds, req.WindowEndUnixSeconds, req.LocationLat, req.LocationLng, req.LocationLabel, req.Capacity,
		monolithclient.CreateCharge{ExpectedCost: req.ExpectedCost, PriceVersion: req.PriceVersion, IdempotencyKey: key})
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
		// Parsed AS 32-bit, so an out-of-range value is a 400. Atoi into
		// int and then int32(...) silently wrapped: page_size=4294967306
		// arrived as 10 (gosec G109).
		parsed, err := strconv.ParseInt(raw, 10, 32)
		if err != nil {
			writeError(w, http.StatusBadRequest, msgCouldNotLoad)
			return
		}
		withinDays = int32(parsed)
	}
	pageSize := int32(0)
	if raw := r.URL.Query().Get("page_size"); raw != "" {
		// Parsed AS 32-bit, so an out-of-range value is a 400. Atoi into
		// int and then int32(...) silently wrapped: page_size=4294967306
		// arrived as 10 (gosec G109).
		parsed, err := strconv.ParseInt(raw, 10, 32)
		if err != nil {
			writeError(w, http.StatusBadRequest, msgCouldNotLoad)
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
		writeError(w, http.StatusBadRequest, msgNeedLocation)
		return
	}
	viewerLng, err := strconv.ParseFloat(r.URL.Query().Get("viewer_lng"), 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, msgNeedLocation)
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

// checkScheduleResponse: `conflict` is the meetup in the way, or null when
// the window is free. Same object the 409 body carries, so the app renders
// both with one sheet.
type checkScheduleResponse struct {
	Conflict *meetupResponse `json:"conflict"`
}

// checkSchedule answers GET /v1/meetups/schedule-check?window_start_unix_seconds=&window_end_unix_seconds=
// for the scheduling flow's time step (ADR-005). Advisory: the create call
// still enforces the rule under the lock.
func (h *Handler) checkSchedule(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	start, errStart := strconv.ParseInt(q.Get("window_start_unix_seconds"), 10, 64)
	end, errEnd := strconv.ParseInt(q.Get("window_end_unix_seconds"), 10, 64)
	if errStart != nil || errEnd != nil {
		writeError(w, http.StatusBadRequest, "Choose when the meetup starts and ends.")
		return
	}
	ctx := r.Context()
	conflict, found, err := h.monolith.CheckSchedule(ctx, middleware.UserIDFromContext(ctx), start, end)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	resp := checkScheduleResponse{}
	if found {
		m := meetupFromClient(conflict)
		resp.Conflict = &m
	}
	writeJSON(w, http.StatusOK, resp)
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
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	if err := h.monolith.CancelMeetup(ctx, r.PathValue("id"), middleware.UserIDFromContext(ctx), req.Reason); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, successResponse{Success: true})
}
