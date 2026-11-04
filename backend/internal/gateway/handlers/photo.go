package handlers

import (
	"errors"
	"io"
	"net/http"
	"strings"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/modules/auth/photo"
)

// A user's own photo (plan 2.1): one small JPEG held in Postgres and served
// from here. Every route needs a signed-in caller, so a photo is never at a
// public address, and the app sends its token only to this gateway.

// photoPathPrefix is what every stored path starts with. A value that does
// not is an old external LinkedIn address, waiting for cmd/backfill-photos.
const photoPathPrefix = "/v1/users/"

// photoPath is the value a payload carries: our own path, or nothing. No
// external address is ever served.
func photoPath(stored string) string {
	if strings.HasPrefix(stored, photoPathPrefix) {
		return stored
	}
	return ""
}

func photoPathPtr(stored *string) *string {
	if stored == nil {
		return nil
	}
	path := photoPath(*stored)
	return &path
}

var photoContentTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true}

type putPhotoResponse struct {
	PhotoURL string `json:"photo_url"`
}

func (h *Handler) putPhoto(w http.ResponseWriter, r *http.Request) {
	contentType, _, _ := strings.Cut(r.Header.Get("Content-Type"), ";")
	if !photoContentTypes[strings.TrimSpace(contentType)] {
		writeError(w, http.StatusUnsupportedMediaType, "Use a JPEG, PNG or WebP picture.")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, photo.MaxUploadBytes+1))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) || len(raw) > photo.MaxUploadBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "That picture is too large.")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	path, err := h.monolith.SetProfilePhoto(ctx, middleware.UserIDFromContext(ctx), raw)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, putPhotoResponse{PhotoURL: photoPath(path)})
}

func (h *Handler) deletePhoto(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if err := h.monolith.DeleteProfilePhoto(ctx, middleware.UserIDFromContext(ctx)); err != nil {
		writeGRPCError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// getPhoto serves a photo under the same rule as names: a guest (Level 0)
// sees their own and no one else's. A guest asking for someone else gets 404,
// as for a user with no photo.
func (h *Handler) getPhoto(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	targetID := r.PathValue("id")
	if targetID != middleware.UserIDFromContext(ctx) && middleware.TrustLevelFromContext(ctx) < 1 {
		writeError(w, http.StatusNotFound, "No photo here.")
		return
	}
	known := strings.Trim(strings.TrimPrefix(r.Header.Get("If-None-Match"), "W/"), `"`)
	jpeg, etag, err := h.monolith.GetProfilePhoto(ctx, targetID, known)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	header := w.Header()
	header.Set("ETag", `"`+etag+`"`)
	header.Set("Cache-Control", "private, max-age=86400")
	header.Set("X-Content-Type-Options", "nosniff")
	if known != "" && known == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	header.Set("Content-Type", "image/jpeg")
	_, _ = w.Write(jpeg)
}
