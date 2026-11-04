package handlers

import (
	"encoding/json"
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// Trusted contacts + SOS (ADR-026, backend/sos-trusted-contacts-PLAN.md
// Step 5) — all authenticated, self-scoped via middleware.UserIDFromContext
// exactly like every other route in this package. Trusted contacts live in
// auth's own database (ADR-017 DB split) so these all go through h.auth,
// never h.meetup — TriggerSOS takes client-supplied meetup/location context
// instead of the gateway making a second call to meetup.

// A contact is a name and a number (ADR-013). Older app builds also send
// "email"; it is ignored, and they read a missing email and status as empty
// and confirmed.
type addTrustedContactRequest struct {
	Name        string `json:"name"`
	PhoneNumber string `json:"phone_number"`
}

type trustedContactResponse struct {
	ID                   string `json:"id"`
	Name                 string `json:"name"`
	PhoneNumber          string `json:"phone_number"`
	CreatedAtUnixSeconds int64  `json:"created_at_unix_seconds"`
}

func trustedContactResponseFromClient(c monolithclient.TrustedContact) trustedContactResponse {
	return trustedContactResponse{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		CreatedAtUnixSeconds: c.CreatedAtUnixSeconds,
	}
}

func (h *Handler) addTrustedContact(w http.ResponseWriter, r *http.Request) {
	var req addTrustedContactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	// Trust level from the verified JWT (ADR-003), never the body — it gates
	// the write, so it is exactly the value a modified client would supply.
	ctx := r.Context()
	contact, err := h.monolith.AddTrustedContact(
		ctx,
		middleware.UserIDFromContext(ctx),
		req.Name, req.PhoneNumber,
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, trustedContactResponseFromClient(contact))
}

func (h *Handler) updateTrustedContact(w http.ResponseWriter, r *http.Request) {
	var req addTrustedContactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	contact, err := h.monolith.UpdateTrustedContact(
		ctx,
		middleware.UserIDFromContext(ctx),
		r.PathValue("id"), req.Name, req.PhoneNumber,
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, trustedContactResponseFromClient(contact))
}

type listTrustedContactsResponse struct {
	Contacts []trustedContactResponse `json:"contacts"`
}

func (h *Handler) listTrustedContacts(w http.ResponseWriter, r *http.Request) {
	contacts, err := h.monolith.ListTrustedContacts(r.Context(), middleware.UserIDFromContext(r.Context()))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	resp := listTrustedContactsResponse{Contacts: make([]trustedContactResponse, 0, len(contacts))}
	for _, c := range contacts {
		resp.Contacts = append(resp.Contacts, trustedContactResponseFromClient(c))
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handler) removeTrustedContact(w http.ResponseWriter, r *http.Request) {
	if err := h.monolith.RemoveTrustedContact(r.Context(), middleware.UserIDFromContext(r.Context()), r.PathValue("id")); err != nil {
		writeGRPCError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type triggerSOSRequest struct {
	ContextMessage string `json:"context_message"`
	// POINTERS, so "absent" survives the decode (tracker #78, finding
	// N-D2). As plain float64 a body with no coordinates decoded to 0,0
	// — a real point in the Gulf of Guinea — and the alert would have
	// confidently named it. The client is now allowed to send an SOS
	// without a fix at all, so telling the two apart is the difference
	// between "no location" and a wrong one.
	Latitude  *float64 `json:"latitude"`
	Longitude *float64 `json:"longitude"`
	// Shared by an attempt and its automatic retry, so the retry reports
	// the first attempt's outcome instead of alerting everyone again.
	// Optional: older app builds do not send it.
	ClientRequestID string `json:"client_request_id"`
	// When the phone took the fix (RFC 3339) and how: "gps" or
	// "device_last_known". Optional: older builds send only a fresh fix.
	CapturedAt string `json:"captured_at"`
	Source     string `json:"source"`
}

// sosFix reads the location out of the request. Nothing here refuses the
// request: a bad timestamp is treated as no timestamp, and an unknown source
// as the weaker claim, because the alert matters more than the detail.
func (req triggerSOSRequest) sosFix() monolithclient.SOSFix {
	// Only a COMPLETE pair is a location. One coordinate without the
	// other is not a point, and passing it on would put a half-truth in
	// an emergency message.
	if req.Latitude == nil || req.Longitude == nil {
		return monolithclient.SOSFix{}
	}
	fix := monolithclient.SOSFix{Latitude: req.Latitude, Longitude: req.Longitude}
	switch req.Source {
	case "":
	case "gps":
		fix.Source = "gps"
	default:
		fix.Source = "device_last_known"
	}
	if at, err := time.Parse(time.RFC3339, req.CapturedAt); err == nil {
		unix := at.Unix()
		fix.CapturedAtUnix = &unix
	}
	return fix
}

// validClientRequestID admits a short opaque token and nothing else. It is
// stored and compared, never shown, but a bounded alphabet keeps it from
// being a place to put anything else.
func validClientRequestID(id string) bool {
	if len(id) > 64 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

type triggerSOSResponse struct {
	ContactsNotified int32 `json:"contacts_notified"`
}

// sosRequestsPerHour bounds requests to the route, retries included.
const sosRequestsPerHour = 30

// triggerSOS is additionally rate-limited per-user via
// middleware.UserKeyedRateLimit chained after h.requireAuth in Register —
// not the global IP+path RateLimit in main.go, which can't see UserID yet
// at that point in the chain.
func (h *Handler) triggerSOS(w http.ResponseWriter, r *http.Request) {
	var req triggerSOSRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	if !validClientRequestID(req.ClientRequestID) {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	ctx := r.Context()
	contactsNotified, err := h.monolith.TriggerSOS(
		ctx,
		middleware.UserIDFromContext(ctx),
		req.ContextMessage, req.ClientRequestID, req.sosFix(),
		int32(middleware.TrustLevelFromContext(ctx)),
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, triggerSOSResponse{ContactsNotified: contactsNotified})
}

type updateLastKnownLocationRequest struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

func (h *Handler) updateLastKnownLocation(w http.ResponseWriter, r *http.Request) {
	var req updateLastKnownLocationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}

	if err := h.monolith.UpdateLastKnownLocation(r.Context(), middleware.UserIDFromContext(r.Context()), req.Latitude, req.Longitude); err != nil {
		writeGRPCError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
