package auth

import (
	"context"
	"errors"
	"math"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestUpdateLastKnownLocation_UpsertsCorrectly (ADR-021 §3, backend/geo-
// visibility-and-nearby-notifications-PLAN.md Step 6) — the browse
// screen's on-demand location read persists into users.last_location_*.
func TestUpdateLastKnownLocation_UpsertsCorrectly(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	ctx := context.Background()

	// The source's RPC returned a bool "success" field alongside the error;
	// the module method returns just an error, since a non-nil error was
	// always the only way success could be false.
	if err := svc.UpdateLastKnownLocation(ctx, UpdateLastKnownLocationRequest{
		UserID: "user-1", Lat: 6.9271, Lng: 79.8612,
	}); err != nil {
		t.Fatalf("UpdateLastKnownLocation() error: %v", err)
	}

	stored := users.byID["user-1"]
	if stored.LastLocationLat == nil || *stored.LastLocationLat != 6.9271 {
		t.Errorf("LastLocationLat = %v, want 6.9271", stored.LastLocationLat)
	}
	if stored.LastLocationLng == nil || *stored.LastLocationLng != 79.8612 {
		t.Errorf("LastLocationLng = %v, want 79.8612", stored.LastLocationLng)
	}
	if stored.LastLocationUpdatedAt == nil {
		t.Error("LastLocationUpdatedAt = nil, want set")
	}
}

// TestUpdateLastKnownLocation_UnknownUserMapsToNotFound confirms a
// malformed/stale caller id doesn't silently succeed.
func TestUpdateLastKnownLocation_UnknownUserMapsToNotFound(t *testing.T) {
	svc, _, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()

	err := svc.UpdateLastKnownLocation(ctx, UpdateLastKnownLocationRequest{
		UserID: "does-not-exist", Lat: 1, Lng: 2,
	})
	if err == nil {
		t.Fatal("UpdateLastKnownLocation() error = nil, want an error for an unknown user id")
	}
}

// TestUpdateLastKnownLocation_RejectsInvalidLatLng (2026-08-31 round-2
// hardening) — was previously accepted unchecked.
func TestUpdateLastKnownLocation_RejectsInvalidLatLng(t *testing.T) {
	cases := []struct {
		name string
		lat  float64
		lng  float64
	}{
		{"NaN latitude", math.NaN(), 79.8},
		{"NaN longitude", 6.9, math.NaN()},
		{"latitude too high", 91, 79.8},
		{"latitude too low", -91, 79.8},
		{"longitude too high", 6.9, 181},
		{"longitude too low", 6.9, -181},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc, users, _, _, _, _ := newTestServiceForSOS(t)
			users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
			ctx := context.Background()

			err := svc.UpdateLastKnownLocation(ctx, UpdateLastKnownLocationRequest{
				UserID: "user-1", Lat: tc.lat, Lng: tc.lng,
			})
			if !errors.Is(err, apperror.ErrInvalidInput) {
				t.Errorf("UpdateLastKnownLocation() with lat=%v lng=%v: code = %v, want %v", tc.lat, tc.lng, err, apperror.ErrInvalidInput)
			}
		})
	}
}
