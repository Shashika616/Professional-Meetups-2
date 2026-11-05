package handlers

import (
	"encoding/json"
	"io"
	"net/http"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
)

// getLegalDocuments is open to everyone: people read these before signing up.
func (h *Handler) getLegalDocuments(w http.ResponseWriter, r *http.Request) {
	docs, err := h.monolith.GetLegalDocuments(r.Context())
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, docs)
}

type legalAcceptanceResponse struct {
	Accepted bool `json:"accepted"`
}

func (h *Handler) getLegalAcceptance(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	accepted, err := h.monolith.HasAcceptedLegal(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, legalAcceptanceResponse{Accepted: accepted})
}

type acceptLegalRequest struct {
	Version string `json:"version"`
}

func (h *Handler) acceptLegal(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var req acceptLegalRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<10)).Decode(&req); err != nil || req.Version == "" {
		writeError(w, http.StatusBadRequest, "version is required")
		return
	}
	if err := h.monolith.AcceptLegal(ctx, middleware.UserIDFromContext(ctx), req.Version); err != nil {
		writeGRPCError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
