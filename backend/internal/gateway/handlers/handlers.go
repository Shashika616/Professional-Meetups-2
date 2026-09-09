// Package handlers implements the gateway's public REST API — the only place
// the public contract (JSON over HTTP) is translated to and from the internal
// gRPC contract (via internal/gateway/monolithclient).
//
// Ported from ../Professional-Meetups/backend/services/gateway/internal/
// handlers. Same routes, same methods, same JSON field names, same middleware
// chain per route. Two structural changes, both from ADR-001:
//
//   - One backing client (monolithclient) instead of three.
//   - The gateway SIGNS the access token here (§6). Everything the source's
//     handlers did with an auth-service-supplied access_token, this package
//     now does with signer.Sign — see sessionFromClient, the single place it
//     happens for all nine session-returning routes.
package handlers

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/middleware"
	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/jwt"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// Handler holds the gateway's REST endpoint implementations.
type Handler struct {
	monolith    monolithclient.Client
	signer      *jwt.Signer
	requireAuth func(http.Handler) http.Handler
	limiter     ratelimit.Limiter
	logger      *slog.Logger
}

// Option configures optional Handler dependencies not every caller (or test
// call site) needs to provide.
type Option func(*Handler)

// WithRateLimiter attaches the shared limiter so Register can wire
// middleware.UserKeyedRateLimit onto the SOS trigger route. Omit it (as most
// tests do) and that route runs without the per-user limit — the global
// IP+path RateLimit in cmd/gateway still applies regardless.
func WithRateLimiter(limiter ratelimit.Limiter) Option {
	return func(h *Handler) { h.limiter = limiter }
}

// WithLogger overrides the logger used for the one thing this package logs:
// a token-signing failure.
func WithLogger(logger *slog.Logger) Option {
	return func(h *Handler) { h.logger = logger }
}

// New constructs a Handler. verifier backs the auth middleware applied
// per-route in Register; signer mints the access token returned by every
// session-issuing route (ADR-001 §6).
func New(monolith monolithclient.Client, signer *jwt.Signer, verifier *jwt.Verifier, opts ...Option) *Handler {
	h := &Handler{
		monolith:    monolith,
		signer:      signer,
		requireAuth: middleware.Auth(verifier),
		logger:      slog.Default(),
	}
	for _, opt := range opts {
		opt(h)
	}
	return h
}

// Register wires this Handler's routes onto mux, using Go 1.22+'s built-in
// method+path pattern matching — no third-party router needed at this API
// size. The authenticated routes are wrapped individually with h.requireAuth
// here, not applied globally in cmd/gateway's middleware chain, so the
// LinkedIn/refresh/logout/email routes stay unauthenticated at the gateway
// layer exactly as they are today.
func (h *Handler) Register(mux *http.ServeMux) {
	// Unauthenticated — four parallel, co-equal account-creation paths.
	// federated/signup (Apple/Google) and linkedin/callback are both
	// resolve-or-create; email signup and email login are both two-step,
	// OTP-only flows.
	mux.HandleFunc("POST /v1/auth/federated/signup", h.federatedSignup)
	mux.HandleFunc("POST /v1/auth/linkedin/callback", h.linkedInCallback)
	mux.HandleFunc("POST /v1/auth/email/signup/start", h.startEmailSignup)
	mux.HandleFunc("POST /v1/auth/email/signup", h.completeEmailSignup)
	mux.HandleFunc("POST /v1/auth/guest/signup", h.guestSignup)
	mux.HandleFunc("POST /v1/auth/email/login/start", h.startEmailLogin)
	mux.HandleFunc("POST /v1/auth/email/login", h.completeEmailLogin)
	mux.HandleFunc("POST /v1/auth/refresh", h.refresh)
	mux.HandleFunc("POST /v1/auth/logout", h.logout)

	// Authenticated — Profile-initiated linking only.
	mux.Handle("POST /v1/auth/identities/link", h.requireAuth(http.HandlerFunc(h.linkIdentity)))

	// The mandatory post-auth screen — every one of the four sign-up/login
	// paths above calls this once, right after auth succeeds.
	mux.Handle("POST /v1/auth/profile-setup", h.requireAuth(http.HandlerFunc(h.completeProfileSetup)))

	mux.Handle("POST /v1/verification/phone/start", h.requireAuth(http.HandlerFunc(h.startPhoneVerification)))
	mux.Handle("POST /v1/verification/phone/verify", h.requireAuth(http.HandlerFunc(h.verifyPhoneCode)))
	mux.Handle("POST /v1/verification/personal-email/start", h.requireAuth(http.HandlerFunc(h.startPersonalEmailVerification)))
	mux.Handle("POST /v1/verification/personal-email/verify", h.requireAuth(http.HandlerFunc(h.verifyPersonalEmailCode)))
	mux.Handle("POST /v1/verification/personal-details", h.requireAuth(http.HandlerFunc(h.submitPersonalDetails)))
	mux.Handle("POST /v1/verification/corporate-email/start", h.requireAuth(http.HandlerFunc(h.startCorporateEmailVerification)))
	mux.Handle("POST /v1/verification/corporate-email/verify", h.requireAuth(http.HandlerFunc(h.verifyCorporateEmailCode)))
	mux.Handle("GET /v1/users/me", h.requireAuth(http.HandlerFunc(h.getProfile)))

	// Trusted contacts + SOS. These live in the auth module, so all four go
	// through h.monolith's auth methods.
	mux.Handle("POST /v1/sos/contacts", h.requireAuth(http.HandlerFunc(h.addTrustedContact)))
	mux.Handle("GET /v1/sos/contacts", h.requireAuth(http.HandlerFunc(h.listTrustedContacts)))
	mux.Handle("DELETE /v1/sos/contacts/{id}", h.requireAuth(http.HandlerFunc(h.removeTrustedContact)))

	// /v1/sos/trigger gets an additional per-user limit (5/hour) on top of
	// the global IP+path RateLimit in cmd/gateway — chained AFTER
	// h.requireAuth specifically, since UserKeyedRateLimit needs
	// UserIDFromContext, which only exists once Auth has run.
	var sosTrigger http.Handler = http.HandlerFunc(h.triggerSOS)
	if h.limiter != nil {
		sosTrigger = middleware.UserKeyedRateLimit(h.limiter, "/v1/sos/trigger", 5, time.Hour)(sosTrigger)
	}
	mux.Handle("POST /v1/sos/trigger", h.requireAuth(sosTrigger))

	// Location — the browse screen's on-demand read is this route's one and
	// only call site on the frontend; no periodic timer.
	mux.Handle("POST /v1/users/me/location", h.requireAuth(http.HandlerFunc(h.updateLastKnownLocation)))

	// Meetup scheduling and join requests — all authenticated, same
	// requireAuth as above. RequestToJoin gets the same blanket IP+path rate
	// limit every route on this mux gets (a spam-join-requests vector is the
	// same shape of abuse as spam-OTP-sends), so no separate limiter there.
	//
	// CreateMeetup gets an ADDITIONAL per-user limit (10/hour) on top of that
	// — the same UserKeyedRateLimit mechanism /v1/sos/trigger uses, chained
	// AFTER requireAuth for the same reason (it needs UserIDFromContext).
	// CreateMeetup triggers an external reverse-geocoding call when the
	// label is empty or a placeholder: an unpredictable-latency,
	// real-per-call-cost dependency the blanket 20/min-per-IP limit doesn't
	// account for. A legitimate host scheduling several meetups a day fits
	// comfortably under 10/hour.
	var createMeetup http.Handler = http.HandlerFunc(h.createMeetup)
	if h.limiter != nil {
		createMeetup = middleware.UserKeyedRateLimit(h.limiter, "/v1/meetups", 10, time.Hour)(createMeetup)
	}
	mux.Handle("POST /v1/meetups", h.requireAuth(createMeetup))

	// ListOpenMeetups deliberately keeps only the blanket per-(IP, path)
	// limit, not a tighter per-user one: unlike CreateMeetup it has no
	// external per-call cost — it is one indexed Postgres query (the GiST
	// index backs ST_DWithin, idx_meetups_intent_status backs the
	// status/intent filter) — and browsing is normal, frequent, low-stakes
	// usage that a tighter budget would break for no security gain.
	mux.Handle("GET /v1/meetups", h.requireAuth(http.HandlerFunc(h.listOpenMeetups)))
	mux.Handle("GET /v1/meetups/mine", h.requireAuth(http.HandlerFunc(h.listMyMeetups)))
	mux.Handle("GET /v1/meetups/active", h.requireAuth(http.HandlerFunc(h.listActiveMeetups)))
	mux.Handle("GET /v1/meetups/{id}", h.requireAuth(http.HandlerFunc(h.getMeetup)))
	mux.Handle("POST /v1/meetups/{id}/close", h.requireAuth(http.HandlerFunc(h.closeMeetup)))
	mux.Handle("POST /v1/meetups/{id}/cancel", h.requireAuth(http.HandlerFunc(h.cancelMeetup)))
	mux.Handle("GET /v1/meetups/{id}/requests", h.requireAuth(http.HandlerFunc(h.listMeetupRequests)))
	mux.Handle("POST /v1/meetups/{id}/requests", h.requireAuth(http.HandlerFunc(h.requestToJoin)))
	mux.Handle("POST /v1/meetups/requests/{id}/withdraw", h.requireAuth(http.HandlerFunc(h.withdrawRequest)))
	mux.Handle("POST /v1/meetups/requests/{id}/respond", h.requireAuth(http.HandlerFunc(h.respondToRequest)))
	mux.Handle("POST /v1/meetups/device-token", h.requireAuth(http.HandlerFunc(h.registerDeviceToken)))
	// The caller's own notification history — user comes from the token.
	mux.Handle("GET /v1/notifications", h.requireAuth(http.HandlerFunc(h.listNotifications)))
	mux.Handle("GET /v1/meetups/{id}/safety", h.requireAuth(http.HandlerFunc(h.getSafetyState)))
	mux.Handle("POST /v1/meetups/{id}/safety/checklist", h.requireAuth(http.HandlerFunc(h.acknowledgeSafetyChecklist)))
	mux.Handle("POST /v1/meetups/{id}/safety/live-location", h.requireAuth(http.HandlerFunc(h.setLiveLocationOptIn)))
	mux.Handle("POST /v1/meetups/{id}/safety/share", h.requireAuth(http.HandlerFunc(h.shareWithContacts)))
	mux.Handle("POST /v1/meetups/{id}/safety/check-in", h.requireAuth(http.HandlerFunc(h.checkIn)))
	mux.Handle("POST /v1/meetups/{id}/safety/decline", h.requireAuth(http.HandlerFunc(h.declineCheckIn)))
	mux.Handle("POST /v1/meetups/{id}/feedback", h.requireAuth(http.HandlerFunc(h.submitMeetupFeedback)))
	mux.Handle("GET /v1/meetups/{id}/participants", h.requireAuth(http.HandlerFunc(h.listMeetupParticipants)))
	mux.Handle("GET /v1/meetups/{id}/ratings/ratable", h.requireAuth(http.HandlerFunc(h.listRatableParticipants)))
	mux.Handle("POST /v1/meetups/{id}/ratings", h.requireAuth(http.HandlerFunc(h.submitRating)))
	// The post-meetup review flow: one write for the whole thing, and a read
	// of what the caller themselves gave (for a history card).
	mux.Handle("POST /v1/meetups/{id}/review", h.requireAuth(http.HandlerFunc(h.submitMeetupReview)))
	mux.Handle("GET /v1/meetups/{id}/review", h.requireAuth(http.HandlerFunc(h.getMeetupReview)))

	// billing (Phase 3) routes: registered, 503 until that module exists.
	// See unavailable.go.
	h.registerUnbuiltModuleRoutes(mux)
}

type federatedSignupRequest struct {
	Provider           string `json:"provider"` // "apple" | "google"
	IDToken            string `json:"id_token"`
	Nonce              string `json:"nonce"`
	AgeConfirmedOver18 bool   `json:"age_confirmed_over_18"`
}

// federatedSignup creates a Level 0 account via Sign in with Apple/Google, or
// logs in if this (provider, subject) already has one. Unauthenticated.
//
// The nonce field is new relative to the source's REST contract — see the
// proto's own comment and the completion report: it closes an id_token replay
// window, and it is the one place in this phase where the copied frontend
// does need a change (it must send the nonce it already has to generate for
// Apple's/Google's own sign-in call).
func (h *Handler) federatedSignup(w http.ResponseWriter, r *http.Request) {
	var req federatedSignupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.CompleteFederatedSignup(r.Context(), req.Provider, req.IDToken, req.Nonce, req.AgeConfirmedOver18)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type linkedInCallbackRequest struct {
	AuthorizationCode  string `json:"authorization_code"`
	RedirectURI        string `json:"redirect_uri"`
	AgeConfirmedOver18 bool   `json:"age_confirmed_over_18"`
}

// linkedInCallback creates a Level 1 account directly via LinkedIn, or logs
// in if this linkedin_sub already has one. Unauthenticated.
func (h *Handler) linkedInCallback(w http.ResponseWriter, r *http.Request) {
	var req linkedInCallbackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.CompleteLinkedInOnboarding(r.Context(), req.AuthorizationCode, req.RedirectURI, req.AgeConfirmedOver18)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type linkIdentityRequest struct {
	Provider          string `json:"provider"` // "apple" | "google" | "linkedin"
	IDToken           string `json:"id_token"`
	Nonce             string `json:"nonce"`
	AuthorizationCode string `json:"authorization_code"`
	RedirectURI       string `json:"redirect_uri"`
}

// linkIdentity links an identity to the caller's already-authenticated
// account. Authenticated — the user id comes from the verified JWT.
func (h *Handler) linkIdentity(w http.ResponseWriter, r *http.Request) {
	var req linkIdentityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.LinkIdentity(
		r.Context(), middleware.UserIDFromContext(r.Context()), req.Provider, req.IDToken, req.Nonce, req.AuthorizationCode, req.RedirectURI,
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type startEmailSignupRequest struct {
	Email string `json:"email"`
}

type startEmailSignupResponse struct {
	ResendAfterSeconds int32 `json:"resend_after_seconds"`
}

// startEmailSignup sends an OTP to email as the first step of the
// passwordless email signup flow — unauthenticated.
func (h *Handler) startEmailSignup(w http.ResponseWriter, r *http.Request) {
	var req startEmailSignupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	resendAfterSeconds, err := h.monolith.StartEmailSignup(r.Context(), req.Email)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, startEmailSignupResponse{ResendAfterSeconds: resendAfterSeconds})
}

type completeEmailSignupRequest struct {
	Email              string `json:"email"`
	Code               string `json:"code"`
	AgeConfirmedOver18 bool   `json:"age_confirmed_over_18"`
}

// completeEmailSignup verifies the OTP sent by startEmailSignup and creates
// (or recovers) an account. No password anywhere — unauthenticated.
func (h *Handler) completeEmailSignup(w http.ResponseWriter, r *http.Request) {
	var req completeEmailSignupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.CompleteEmailSignup(r.Context(), req.Email, req.Code, req.AgeConfirmedOver18)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type guestSignupRequest struct {
	AgeConfirmedOver18 bool `json:"age_confirmed_over_18"`
}

// guestSignup creates a read-only guest account and returns a real session
// (ADR-002 §3). Unauthenticated, like the other signup routes.
//
// It carries a DEDICATED rate limit on top of the blanket per-(IP, path) one
// — 5 per IP per day (middleware's accountCreationPaths). This is the only
// endpoint in the system that mints a fully usable account with no
// verification step of any kind, and the shared 20/min would have allowed
// ~28,800 of them per IP per day. See that limiter's own comment for why the
// number is 5 and what it does not claim to stop.
func (h *Handler) guestSignup(w http.ResponseWriter, r *http.Request) {
	var req guestSignupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.GuestSignup(r.Context(), req.AgeConfirmedOver18)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type startEmailLoginRequest struct {
	Email string `json:"email"`
}

// startEmailLogin sends an OTP to email as the first step of passwordless
// email login — unauthenticated.
func (h *Handler) startEmailLogin(w http.ResponseWriter, r *http.Request) {
	var req startEmailLoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	resendAfterSeconds, err := h.monolith.StartEmailLogin(r.Context(), req.Email)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, startEmailSignupResponse{ResendAfterSeconds: resendAfterSeconds})
}

type completeEmailLoginRequest struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

// completeEmailLogin verifies the OTP sent by startEmailLogin against an
// already-existing account — unauthenticated. Every return visit sends and
// verifies a fresh code; there is no stored credential to check.
func (h *Handler) completeEmailLogin(w http.ResponseWriter, r *http.Request) {
	var req completeEmailLoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.CompleteEmailLogin(r.Context(), req.Email, req.Code)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	h.writeSession(w, session)
}

type completeProfileSetupRequest struct {
	FullName     string `json:"full_name"`
	CompanyName  string `json:"company_name"`
	CompanyEmail string `json:"company_email"`
}

// completeProfileSetup backs the mandatory post-auth screen — authenticated,
// user id from the verified JWT, never client-supplied.
func (h *Handler) completeProfileSetup(w http.ResponseWriter, r *http.Request) {
	var req completeProfileSetupRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	profile, err := h.monolith.CompleteProfileSetup(
		r.Context(), middleware.UserIDFromContext(r.Context()), req.FullName, req.CompanyName, req.CompanyEmail,
	)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, profileResponseFromClient(profile))
}

type sessionResponse struct {
	UserID          string `json:"user_id"`
	AccessToken     string `json:"access_token"`
	RefreshToken    string `json:"refresh_token"`
	ExpiresIn       int64  `json:"expires_in"`
	IsNewUser       bool   `json:"is_new_user"`
	FullName        string `json:"full_name"`
	ProfilePhotoURL string `json:"profile_photo_url"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	session, err := h.monolith.RefreshSession(r.Context(), req.RefreshToken)
	if err != nil {
		writeGRPCError(w, err)
		return
	}

	// The re-signing half of refresh happens right here rather than in the
	// monolith (ADR-001 §6): the module validated and rotated the
	// refresh-token row and told us whose it is, and this is the process
	// holding the key.
	h.writeSession(w, session)
}

type logoutRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type logoutResponse struct {
	Success bool `json:"success"`
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	var req logoutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	// RevokeSession is idempotent all the way down to the repository layer —
	// an unknown or already-revoked token isn't an error, so this only
	// returns non-200 for a genuine backend failure.
	if err := h.monolith.RevokeSession(r.Context(), req.RefreshToken); err != nil {
		writeGRPCError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, logoutResponse{Success: true})
}

// writeSession is where ADR-001 §6 actually lands: the monolith has returned
// identity facts, and the gateway turns them into the session the client
// sees. Every session-returning route goes through here, so the token's
// claims are built in exactly one place — user_id and trust_level, the same
// two claims the source's auth service put in the token it signed itself.
//
// A signing failure is a 500, not a partial success: handing back a session
// response with an empty access_token would look like success to a client
// and fail confusingly on its next request.
func (h *Handler) writeSession(w http.ResponseWriter, s monolithclient.Session) {
	accessToken, err := h.signer.Sign(jwt.Claims{UserID: s.UserID, TrustLevel: s.TrustLevel})
	if err != nil {
		// The error text can carry key-material detail; log it, never return
		// it, same discipline as apperror's Internal redaction.
		h.logger.Error("sign access token", "user_id", s.UserID, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	writeJSON(w, http.StatusOK, sessionResponse{
		UserID:          s.UserID,
		AccessToken:     accessToken,
		RefreshToken:    s.RefreshToken,
		ExpiresIn:       int64(jwt.AccessTokenTTL.Seconds()),
		IsNewUser:       s.IsNewUser,
		FullName:        s.FullName,
		ProfilePhotoURL: s.ProfilePhotoURL,
	})
}

type errorResponse struct {
	Error string `json:"error"`
}

// writeGRPCError maps a gRPC status error from monolithclient to the
// corresponding HTTP status via apperror's single mapping table — the one
// place this translation happens, not a switch statement per handler.
func writeGRPCError(w http.ResponseWriter, err error) {
	st := status.Convert(err)
	writeError(w, apperror.HTTPStatusFromGRPC(st.Code()), st.Message())
}

func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, errorResponse{Error: message})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
