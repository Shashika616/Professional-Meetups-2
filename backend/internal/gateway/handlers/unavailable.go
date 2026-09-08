package handlers

import "net/http"

// The billing (Phase 3) routes. They are registered now, with the same
// methods, paths and auth wrapping they will keep, and answer 503 until that
// module exists.
//
// The meetup routes that used to live here are real as of Phase 2 — see
// meetups.go and Register.
//
// Why register them at all rather than let them 404: this mirrors what the
// source gateway already does when BILLING_SERVICE_ADDR is unset — the
// routes exist, the handler nil-checks its client and returns 503 ("billing
// is not configured"). A 503 tells a client "this endpoint is real, the
// backend behind it isn't available", which is true here and is what the
// frontend's own error handling already distinguishes; a 404 would say "no
// such endpoint", which is false.
//
// What they deliberately do NOT do is return a plausible-looking success
// shape. A stubbed empty meetup list would be indistinguishable from "there
// are genuinely no meetups nearby" and would make Phase 2 look partly done
// when none of it exists.
//
// requireAuth is applied exactly where Phase 2/3 will need it, so an
// unauthenticated caller gets 401 here and not 503 — the same precedence the
// source has (its billing routes are wrapped in requireAuth, and the 503
// nil-check runs inside the handler, after auth). The two webhook routes
// stay unwrapped: Apple and Google don't carry this app's session JWTs, and
// their own signature/OIDC verification is what will gate them.
func (h *Handler) registerUnbuiltModuleRoutes(mux *http.ServeMux) {
	billingRoutes := []string{
		"POST /v1/billing/purchases/verify",
		"GET /v1/billing/subscription",
	}
	for _, pattern := range billingRoutes {
		mux.Handle(pattern, h.requireAuth(unavailable("billing is not configured")))
	}

	mux.Handle("POST /v1/billing/webhooks/apple", unavailable("billing is not configured"))
	mux.Handle("POST /v1/billing/webhooks/google", unavailable("billing is not configured"))
}

func unavailable(message string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusServiceUnavailable, message)
	})
}
