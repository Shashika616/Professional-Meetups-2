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

// ValidateLatLng rejects NaN and out-of-range coordinates. Callers map the
// returned error through their own apperror.ErrInvalidInput wrapping
// (kept out of this package so it stays dependency-free).
func ValidateLatLng(lat, lng float64) error {
	if math.IsNaN(lat) || math.IsNaN(lng) {
		return fmt.Errorf("latitude/longitude must not be NaN")
	}
	if lat < -90 || lat > 90 {
		return fmt.Errorf("latitude %v out of range [-90, 90]", lat)
	}
	if lng < -180 || lng > 180 {
		return fmt.Errorf("longitude %v out of range [-180, 180]", lng)
	}
	return nil
}
