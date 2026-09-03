// Package apperror defines the sentinel errors shared across services and
// the two boundary-mapping functions (gRPC status, then HTTP status) that
// translate them at each layer. Services should wrap one of these sentinels
// via fmt.Errorf("...: %w", ErrX) rather than returning ad-hoc errors, so
// GRPCCode/HTTPStatusFromGRPC below stay the single, complete mapping —
// not five different switch statements scattered through handlers.
package apperror

import "errors"

var (
	ErrNotFound     = errors.New("not found")
	ErrInvalidInput = errors.New("invalid input")
	ErrUnauthorized = errors.New("unauthorized")
	ErrConflict     = errors.New("conflict")
	ErrInternal     = errors.New("internal error")
	// ErrForbidden is "authenticated, but not permitted" — distinct from
	// ErrUnauthorized ("not authenticated at all"), which is the HTTP
	// 401-vs-403 distinction. Used for the meetup-scheduling slice's
	// trust-level gate and host/requester ownership checks (ADR-013,
	// backend/meetup-scheduling-PLAN.md).
	ErrForbidden = errors.New("forbidden")
	// ErrRateLimited is distinct from the gateway's IP-based rate limiter
	// (middleware/ratelimit.go) — this is for a server-enforced per-action
	// cooldown (e.g. the Level 2/3 verification addendum's 1-minute
	// resend-code timer) that a service layer needs to signal explicitly,
	// not a request-volume limit applied uniformly at the edge. Both map to
	// the same HTTP 429, which is the correct shared signal either way.
	ErrRateLimited = errors.New("rate limited")
)
