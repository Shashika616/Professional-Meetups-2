package sos

import (
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

// Plan 2.2: the location chain.
func TestResolveLocationWalksTheChain(t *testing.T) {
	now := time.Date(2026, 10, 30, 13, 15, 0, 0, time.UTC)
	lat, lng := 6.90123, 79.85432
	at := func(d time.Duration) *time.Time { v := now.Add(d); return &v }
	storedLat, storedLng := 6.901, 79.854
	stored := func(age time.Duration) repository.User {
		return repository.User{LastLocationLat: &storedLat, LastLocationLng: &storedLng, LastLocationUpdatedAt: at(-age)}
	}
	fix := func(source string, captured *time.Time) TriggerSOSRequest {
		return TriggerSOSRequest{Latitude: &lat, Longitude: &lng, Source: source, CapturedAt: captured}
	}
	for _, tc := range []struct {
		name string
		req  TriggerSOSRequest
		user repository.User
		kind LocationKind
		lat  float64
	}{
		{"a fresh fix", fix("gps", at(-5*time.Second)), stored(time.Hour), LocationGPS, lat},
		{"the phone's last known position", fix("device_last_known", at(-2*time.Hour)), stored(time.Hour), LocationDevice, lat},
		{"a build too old to say", fix("", nil), repository.User{}, LocationGPS, lat},
		{"a source with no time is not called current", fix("device_last_known", nil), repository.User{}, LocationDevice, lat},
		{"an unknown source claims less", fix("satellite", at(-time.Minute)), repository.User{}, LocationDevice, lat},
		{"a clock slightly ahead keeps the fix", fix("gps", at(time.Minute)), repository.User{}, LocationGPS, lat},
		{"a future fix falls back to the stored location", fix("gps", at(time.Hour)), stored(time.Hour), LocationServer, storedLat},
		{"a future fix with nothing stored is unknown", fix("gps", at(time.Hour)), repository.User{}, LocationUnknown, 0},
		{"a fix over 24 hours old falls back", fix("device_last_known", at(-25*time.Hour)), stored(time.Hour), LocationServer, storedLat},
		{"no fix uses the stored location", TriggerSOSRequest{}, stored(3 * time.Hour), LocationServer, storedLat},
		{"a stored location over 24 hours old is unknown", TriggerSOSRequest{}, stored(25 * time.Hour), LocationUnknown, 0},
		{"nothing at all is unknown", TriggerSOSRequest{}, repository.User{}, LocationUnknown, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveLocation(tc.req, tc.user, now)
			if got.Kind != tc.kind || got.Lat != tc.lat {
				t.Errorf("got kind %v at %v, want kind %v at %v", got.Kind, got.Lat, tc.kind, tc.lat)
			}
			if got.Kind != LocationUnknown && got.CapturedAt.After(now) {
				t.Errorf("captured at %v, after the alert", got.CapturedAt)
			}
		})
	}
}
