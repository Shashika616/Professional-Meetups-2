package auth

import (
	"context"
	"fmt"

	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/geo"
)

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
	if _, err := s.users.UpdateLastKnownLocation(ctx, req.UserID, req.Lat, req.Lng); err != nil {
		return err
	}
	return nil
}
