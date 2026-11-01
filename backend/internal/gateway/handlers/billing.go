package handlers

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
)

// The billing routes (plan 29 §3.9, docs/api/billing.md). Every user route
// is the caller's own data: the user id comes from the verified token and no
// route takes one in its path, query or body, so there is nothing to point
// at another account. The two store webhooks have no session at all; billing
// verifies the store's own signature or push token.

// billingRateLimit is the per-user budget on the billing read routes.
const billingRateLimit = 60

// verifyRateLimit is the per-user budget on purchase verification: each one
// is a call to Apple or Google.
const verifyRateLimit = 10

// registerBillingRoutes wires the billing and app-config routes.
func (h *Handler) registerBillingRoutes(mux *http.ServeMux) {
	limited := func(path string, limit int, next http.Handler) http.Handler {
		if h.limiter == nil {
			return next
		}
		return middleware.UserKeyedRateLimit(h.limiter, path, limit, time.Minute)(next)
	}
	perUser := func(path string, next http.HandlerFunc) http.Handler {
		return h.requireAuth(limited(path, billingRateLimit, next))
	}
	mux.Handle("GET /v1/billing/wallet", perUser("/v1/billing/wallet", h.getWallet))
	mux.Handle("GET /v1/billing/ledger", perUser("/v1/billing/ledger", h.listLedger))
	mux.Handle("POST /v1/billing/quote", perUser("/v1/billing/quote", h.quote))
	mux.Handle("GET /v1/billing/entitlements", perUser("/v1/billing/entitlements", h.getEntitlements))

	// Plan 29B.
	mux.Handle("POST /v1/billing/purchases/verify",
		h.requireAuth(limited("/v1/billing/purchases/verify", verifyRateLimit, http.HandlerFunc(h.verifyPurchase))))
	mux.Handle("GET /v1/billing/subscription", perUser("/v1/billing/subscription", h.getSubscription))
	// Signed in or not, like app-config: the Premium page can render before
	// sign-in. Signed in, it is the caller's own view (their flags and
	// account token) and the per-user limit applies.
	mux.Handle("GET /v1/billing/catalog",
		h.optionalAuth(limited("/v1/billing/catalog", billingRateLimit, http.HandlerFunc(h.getCatalog))))
	// No session: Apple and Google carry none. The blanket per-IP limit in
	// cmd/gateway applies, and the body is capped below.
	mux.Handle("POST /v1/billing/webhooks/apple", http.HandlerFunc(h.appleWebhook))
	mux.Handle("POST /v1/billing/webhooks/google", http.HandlerFunc(h.googleWebhook))

	// Signed in or not: the app reads its flags before sign-in too. The
	// blanket per-IP limit covers the anonymous case.
	mux.Handle("GET /v1/app-config", h.optionalAuth(http.HandlerFunc(h.getAppConfig)))
}

func (h *Handler) getWallet(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	wallet, err := h.monolith.GetWallet(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, wallet)
}

func (h *Handler) listLedger(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := r.URL.Query()
	pageSize := int32(0)
	if raw := q.Get("page_size"); raw != "" {
		n, err := strconv.ParseInt(raw, 10, 32)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, msgCouldNotLoad)
			return
		}
		pageSize = int32(n)
	}
	page, err := h.monolith.ListLedger(ctx, middleware.UserIDFromContext(ctx), q.Get("cursor"), pageSize)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// quoteRequest is what the user chose. Nothing about money: the server
// prices it. Unknown fields are refused (OWASP API3), so a client cannot
// send a price and believe it was used.
type quoteRequest struct {
	Capacity               int32 `json:"capacity"`
	WindowStartUnixSeconds int64 `json:"window_start_unix_seconds"`
}

// quoteMaxBody bounds the quote body well below the global cap: it is two
// numbers.
const quoteMaxBody = 1 << 10

func (h *Handler) quote(w http.ResponseWriter, r *http.Request) {
	var req quoteRequest
	if err := decodeStrict(r, quoteMaxBody, &req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	q, err := h.monolith.Quote(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)),
		req.Capacity, req.WindowStartUnixSeconds)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, q)
}

func (h *Handler) getEntitlements(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	e, err := h.monolith.GetEntitlements(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, e)
}

// verifyPurchaseRequest is what the store handed the app, and which store.
// No amount, no price, no user id: the server reads all of that from the
// store's answer and the token.
type verifyPurchaseRequest struct {
	Platform  string `json:"platform"`
	ProductID string `json:"product_id"`
	Token     string `json:"token"`
}

// verifyMaxBody fits a StoreKit 2 signed transaction with room to spare.
const verifyMaxBody = 32 << 10

func (h *Handler) verifyPurchase(w http.ResponseWriter, r *http.Request) {
	var req verifyPurchaseRequest
	if err := decodeStrict(r, verifyMaxBody, &req); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	ctx := r.Context()
	res, err := h.monolith.VerifyPurchase(ctx, middleware.UserIDFromContext(ctx), int32(middleware.TrustLevelFromContext(ctx)),
		req.Platform, req.ProductID, req.Token)
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) getSubscription(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	sub, err := h.monolith.GetSubscription(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, sub)
}

func (h *Handler) getCatalog(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	c, err := h.monolith.GetCatalog(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, c)
}

// webhookMaxBody caps a store notification. Apple's signed payloads and
// Pub/Sub envelopes are a few kilobytes.
const webhookMaxBody = 64 << 10

// appleWebhook forwards an App Store Server Notification V2 ({"signedPayload":
// "..."}) untouched. This handler trusts nothing in it; billing verifies the
// signature chain before reading a field (ported from the source's gateway).
func (h *Handler) appleWebhook(w http.ResponseWriter, r *http.Request) {
	var body struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, webhookMaxBody)).Decode(&body); err != nil || body.SignedPayload == "" {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	if _, err := h.monolith.HandleAppleNotification(r.Context(), body.SignedPayload); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// googleWebhook forwards a Pub/Sub push (RTDN) and its Authorization header
// untouched; billing verifies the OIDC token before decoding message.data.
func (h *Handler) googleWebhook(w http.ResponseWriter, r *http.Request) {
	var envelope struct {
		Message struct {
			Data      string `json:"data"`
			MessageID string `json:"messageId"`
		} `json:"message"`
		Subscription string `json:"subscription"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, webhookMaxBody)).Decode(&envelope); err != nil {
		writeError(w, http.StatusBadRequest, msgBadRequest)
		return
	}
	if _, err := h.monolith.HandleGoogleNotification(r.Context(), r.Header.Get("Authorization"),
		envelope.Message.MessageID, envelope.Message.Data); err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *Handler) getAppConfig(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	cfg, err := h.monolith.GetAppConfig(ctx, middleware.UserIDFromContext(ctx))
	if err != nil {
		writeGRPCError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

// decodeStrict decodes exactly one JSON object with no unknown fields and no
// trailing data.
func decodeStrict(r *http.Request, limit int64, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, limit+1))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if dec.More() {
		return errors.New("trailing data")
	}
	var rest bytes.Buffer
	if _, err := io.Copy(&rest, dec.Buffered()); err == nil && strings.TrimSpace(rest.String()) != "" {
		return errors.New("trailing data")
	}
	return nil
}

// idempotencyKeyMax matches the meetup.meetups.creation_key column.
const idempotencyKeyMax = 128

// idempotencyKey reads the Idempotency-Key header. Absent is fine (every
// shipped build); present but malformed is a 400, because silently dropping
// it would turn a client's retry into a second charge.
func idempotencyKey(r *http.Request) (string, bool) {
	raw := r.Header.Get("Idempotency-Key")
	if raw == "" {
		return "", true
	}
	key := strings.TrimSpace(raw)
	if key == "" || len(key) > idempotencyKeyMax {
		return "", false
	}
	for _, c := range key {
		if c < 0x21 || c > 0x7e {
			return "", false
		}
	}
	return key, true
}
