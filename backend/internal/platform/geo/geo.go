// Package geo holds the one small piece of validation logic shared between
// services/auth (TriggerSOS, UpdateLastKnownLocation) and services/meetup
// (ListOpenMeetups's viewer_lat/viewer_lng) — 2026-08-31 round-2 hardening
// finding: none of the three entry points checked their lat/lng inputs at
// all before this, so NaN or out-of-range values flowed straight through,
// worst case into a real maps link sent to a real trusted contact during
// TriggerSOS. A tiny standalone package (no dependency on apperror or
// anything domain-specific) rather than duplicating the same two-line
// check in both services — both already depend on the shared module for
// other cross-cutting concerns (apperror, events, outbox).
package geo

import (
	"fmt"
	"math"
)

// ValidateLatLng rejects NaN, infinite, out-of-range, and null-island
// coordinates. Callers map the returned error through their own
// apperror.ErrInvalidInput wrapping (kept out of this package so it stays
// dependency-free).
func ValidateLatLng(lat, lng float64) error {
	if math.IsNaN(lat) || math.IsNaN(lng) {
		return fmt.Errorf("latitude/longitude must not be NaN")
	}
	// Infinities pass every range comparison below in the wrong direction
	// (+Inf > 90 catches it, but -Inf < -90 also catches it, so this is
	// belt-and-braces) — named explicitly so the error says what happened
	// rather than reporting an unhelpful "+Inf out of range".
	if math.IsInf(lat, 0) || math.IsInf(lng, 0) {
		return fmt.Errorf("latitude/longitude must be finite")
	}
	// Exactly (0, 0) is "null island" — a point in the Atlantic off the Gulf
	// of Guinea, and in practice never a real meetup or SOS location. It is
	// what a failed GPS read defaults to, and it passes every range check
	// above, so before this it flowed silently through to a real geography
	// column: a meetup created 5,000km from where its host thinks it is,
	// invisible to the 50km nearby-notify fan-out and to every browse-radius
	// filter, with no error surfaced anywhere to explain why. On the SOS
	// path it would have put null island into a maps link sent to a real
	// trusted contact during an emergency.
	//
	// Rejected as its own distinct error, not folded into the range checks:
	// "latitude 0 out of range" would be actively confusing, since 0 IS in
	// range. The message has to say what actually went wrong, because the
	// real cause is upstream (a location permission denied, a fix not yet
	// acquired) and the caller needs to recognise it.
	//
	// The precision cost of this rule is a band roughly one ten-millionth of
	// a degree wide — around a centimetre of ocean. Anyone genuinely there
	// can move a hand's width.
	if lat == 0 && lng == 0 {
		return fmt.Errorf("latitude/longitude of exactly (0, 0) is not a real location — this usually means a location fix was never acquired")
	}
	if lat < -90 || lat > 90 {
		return fmt.Errorf("latitude %v out of range [-90, 90]", lat)
	}
	if lng < -180 || lng > 180 {
		return fmt.Errorf("longitude %v out of range [-180, 180]", lng)
	}
	return nil
}
