package handlers

import (
	"encoding/json"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// Trusted contacts + SOS (ADR-026, backend/sos-trusted-contacts-PLAN.md
// Step 5) — all authenticated, self-scoped via middleware.UserIDFromContext
// exactly like every other route in this package. Trusted contacts live in
// auth's own database (ADR-017 DB split) so these all go through h.auth,
// never h.meetup — TriggerSOS takes client-supplied meetup/location context
// instead of the gateway making a second call to meetup.

type addTrustedContactRequest struct {
	Name        string `json:"name"`
	PhoneNumber string `json:"phone_number"`
	Email       string `json:"email"`
}

type trustedContactResponse struct {
	ID                   string `json:"id"`
	Name                 string `json:"name"`
	PhoneNumber          string `json:"phone_number"`
	Email                string `json:"email"`
	CreatedAtUnixSeconds int64  `json:"created_at_unix_seconds"`
	// "confirmed", "pending" or "expired" (#80). A new key: app builds that
	// predate it ignore unknown JSON fields.
	Status string `json:"status"`
}

func trustedContactResponseFromClient(c monolithclient.TrustedContact) trustedContactResponse {
	return trustedContactResponse{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		Email:                c.Email,
		CreatedAtUnixSeconds: c.CreatedAtUnixSeconds,
		Status:               c.Status,
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
		req.Name, req.PhoneNumber, req.Email,
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

// triggerSOS is additionally rate-limited per-user (5/hour, ADR-026 §5) via
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
	// Only a COMPLETE pair is a location. One coordinate without the
	// other is not a point, and passing it on would put a half-truth in
	// an emergency message.
	var lat, lng *float64
	if req.Latitude != nil && req.Longitude != nil {
		lat, lng = req.Latitude, req.Longitude
	}
	contactsNotified, err := h.monolith.TriggerSOS(
		ctx,
		middleware.UserIDFromContext(ctx),
		req.ContextMessage, req.ClientRequestID, lat, lng,
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
