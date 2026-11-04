package handlers

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"

	"github.com/google/uuid"
)

// The analytics routes (plan 29 §4.3, docs/api/analytics.md). The batch is
// checked for size and shape here and validated field by field in the
// monolith against the event registry. The client's IP address is used by
// the per-IP limit in cmd/gateway and never forwarded.

const (
	// analyticsMaxBody caps a batch at 64 KB after decompression, so a
	// small gzip body cannot expand into a large one.
	analyticsMaxBody = 64 << 10
	// analyticsMaxEvents is the most events one batch may carry.
	analyticsMaxEvents = 50
	// analyticsBatchesPerMinute is the per-user (or, signed out, per-install)
	// budget.
	analyticsBatchesPerMinute = 30
	consentMaxBody            = 1 << 10
	// consentPerMinute is the per-user budget on the consent route: opting
	// out deletes the account's analytics (security review 2026-11-01, S-5).
	consentPerMinute = 10
)

const msgAnalyticsTooLarge = "That batch is too large."

func (h *Handler) registerAnalyticsRoutes(mux *http.ServeMux) {
	// Signed in or not: screens before sign-in are counted too, keyed by
	// the install id.
	mux.Handle("POST /v1/analytics/events", h.optionalAuth(http.HandlerFunc(h.ingestAnalytics)))
	consent := http.Handler(http.HandlerFunc(h.setAnalyticsConsent))
	if h.limiter != nil {
		consent = middleware.UserKeyedRateLimit(h.limiter, "/v1/analytics/consent", consentPerMinute, time.Minute)(consent)
	}
	mux.Handle("PUT /v1/analytics/consent", h.requireAuth(consent))
}

// errTooLarge is a batch over the byte cap.
var errTooLarge = errors.New("batch too large")

// readBatchBody reads the body, gunzipping it when the client says so, and
// refuses anything over analyticsMaxBody either way.
func readBatchBody(r *http.Request) ([]byte, error) {
	var body io.Reader = r.Body
	switch strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Encoding"))) {
	case "", "identity":
	case "gzip":
		zr, err := gzip.NewReader(io.LimitReader(r.Body, analyticsMaxBody+1))
		if err != nil {
			return nil, err
		}
		defer func() { _ = zr.Close() }()
		body = zr
	default:
		return nil, errors.New("unsupported content encoding")
	}
	raw, err := io.ReadAll(io.LimitReader(body, analyticsMaxBody+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > analyticsMaxBody {
		return nil, errTooLarge
	}
	return raw, nil
}

func (h *Handler) ingestAnalytics(w http.ResponseWriter, r *http.Request) {
	raw, err := readBatchBody(r)
	if errors.Is(err, errTooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, msgAnalyticsTooLarge)
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	var batch monolithclient.AnalyticsBatch
	if err := decodeStrictBytes(raw, &batch); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	if len(batch.Events) > analyticsMaxEvents {
		writeError(w, http.StatusRequestEntityTooLarge, msgAnalyticsTooLarge)
		return
	}
	// The install id keys the limiter below, so it is checked first (#119):
	// any other string would make a key of the caller's choosing and size.
	if _, err := uuid.Parse(batch.InstallID); err != nil || len(batch.InstallID) != 36 {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	userID := middleware.UserIDFromContext(ctx)
	if h.limiter != nil {
		key := "ratelimit:analytics:install:" + strings.ToLower(batch.InstallID)
		if userID != "" {
			key = "ratelimit:analytics:user:" + userID
		}
		if !h.limiter.Allow(key, analyticsBatchesPerMinute, time.Minute) {
			writeRateLimitedJSON(w, time.Minute)
			return
		}
	}
	res, err := h.monolith.IngestAnalytics(ctx, userID, batch)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

type consentRequest struct {
	OptedOut *bool `json:"opted_out"`
}

func (h *Handler) setAnalyticsConsent(w http.ResponseWriter, r *http.Request) {
	var req consentRequest
	if err := decodeStrict(r, consentMaxBody, &req); err != nil || req.OptedOut == nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	if err := h.monolith.SetAnalyticsConsent(ctx, middleware.UserIDFromContext(ctx), *req.OptedOut); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"opted_out": *req.OptedOut})
}

// decodeStrictBytes is decodeStrict over a body already read: unknown
// fields and trailing data are refused.
func decodeStrictBytes(raw []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("trailing data")
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("trailing data")
	}
	return nil
}

// writeRateLimitedJSON is the gateway's usual 429, with Retry-After.
func writeRateLimitedJSON(w http.ResponseWriter, window time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(int(window.Seconds())))
	writeError(w, http.StatusTooManyRequests, "Too many attempts. Please wait a moment and try again.")
}
