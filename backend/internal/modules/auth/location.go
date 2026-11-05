package auth

import (
	"context"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/geo"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// locationReportRule: the app reports at most about hourly or when the phone
// moves, so 60 a day is generous. Failing open costs one small write.
var locationReportRule = ratelimit.Rule{Name: "auth:location-report", Limit: 60, Window: 24 * time.Hour}

// UpdateLastKnownLocation records the browse screen's on-demand location
// read — self-only data, no participant/trust-level gate needed. Publishing
// user-location-updated happens inside the repository write (the call site
// that used to write the outbox row, ADR-001 §4), so this method has nothing
// else to do beyond validating and writing.
//
// The lat/lng validation is not optional politeness: unchecked coordinates
// previously flowed straight through, and the same values reach a real maps
// link sent to a real trusted contact via TriggerSOS.
func (s *service) UpdateLastKnownLocation(ctx context.Context, req UpdateLastKnownLocationRequest) error {
	if err := geo.ValidateLatLng(req.Lat, req.Lng); err != nil {
		return fmt.Errorf("auth: %v: %w", err, apperror.ErrInvalidInput)
	}
	if err := s.limits.Check(ctx, locationReportRule, req.UserID); err != nil {
		return err
	}
	// Kept to about 110 m (plan 30B, 3.3), whatever the app sends: enough
	// for a 50 km radius, too coarse to find a house. The published event,
	// and so the meetup module's cache, carries the rounded value too.
	if _, err := s.users.UpdateLastKnownLocation(ctx, req.UserID, geo.StoredPrecision(req.Lat), geo.StoredPrecision(req.Lng)); err != nil {
		return err
	}
	return nil
}
