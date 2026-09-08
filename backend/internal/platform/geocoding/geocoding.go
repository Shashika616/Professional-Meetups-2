// Package geocoding turns raw GPS coordinates into a human-readable place
// label (ADR-029, round-8 hardening) — used only to replace the literal
// "Current location"/empty placeholder a host's meetup-creation request can
// carry, never to override a real, host-chosen search result. Mirrors the
// existing services/auth/internal/sms and .../email package shape
// (interface + concrete implementation, env-credential-gated where the
// provider needs one) rather than inventing a new pattern.
package geocoding

import "context"

// ReverseGeocoder turns (lat, lng) into a short, human-readable label.
//
// ReverseGeocode is expected to never return a non-nil error in normal
// operation — a reverse-geocode call is a display convenience for a
// meetup's location label, not something meetup creation should ever
// block or fail on, so every failure mode (network error, timeout,
// non-200 response, malformed body) is expected to be handled internally
// by the implementation and turned into (FallbackLabel, nil) instead of
// being propagated. The error return stays part of the interface for
// symmetry with this codebase's other vendor-integration interfaces
// (sms.SmsSender, email.EmailSender) and so a caller stays defensive
// (falling back to FallbackLabel itself) even if some future
// implementation chooses to propagate errors instead.
type ReverseGeocoder interface {
	ReverseGeocode(ctx context.Context, lat, lng float64) (label string, err error)
}

// FallbackLabel is used whenever reverse geocoding fails, times out, or
// returns something unusable — never the raw coordinates, never a raw
// error message surfaced to the meetup's location_label.
const FallbackLabel = "Meetup location"
