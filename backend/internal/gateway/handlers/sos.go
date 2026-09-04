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
}

func trustedContactResponseFromClient(c monolithclient.TrustedContact) trustedContactResponse {
	return trustedContactResponse{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		Email:                c.Email,
		CreatedAtUnixSeconds: c.CreatedAtUnixSeconds,
	}
}

func (h *Handler) addTrustedContact(w http.ResponseWriter, r *http.Request) {
	var req addTrustedContactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	contact, err := h.monolith.AddTrustedContact(r.Context(), middleware.UserIDFromContext(r.Context()), req.Name, req.PhoneNumber, req.Email)
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
	ContextMessage string  `json:"context_message"`
	Latitude       float64 `json:"latitude"`
	Longitude      float64 `json:"longitude"`
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
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	contactsNotified, err := h.monolith.TriggerSOS(r.Context(), middleware.UserIDFromContext(r.Context()), req.ContextMessage, req.Latitude, req.Longitude)
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
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	if err := h.monolith.UpdateLastKnownLocation(r.Context(), middleware.UserIDFromContext(r.Context()), req.Latitude, req.Longitude); err != nil {
		writeGRPCError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
