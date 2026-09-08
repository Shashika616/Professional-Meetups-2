package geo

import (
	"math"
	"strings"
	"testing"
)

func TestValidateLatLng(t *testing.T) {
	tests := []struct {
		name     string
		lat, lng float64
		wantErr  bool
	}{
		{name: "ordinary coordinate", lat: 51.5074, lng: -0.1278},
		{name: "north pole", lat: 90, lng: 0},
		{name: "south pole", lat: -90, lng: 0},
		{name: "antimeridian east", lat: 0, lng: 180},
		{name: "antimeridian west", lat: 0, lng: -180},

		// §C1. The exact pair only — a real coordinate that merely has a
		// zero in one component must still be accepted, or the equator and
		// the prime meridian become unusable.
		{name: "null island is rejected", lat: 0, lng: 0, wantErr: true},
		{name: "on the equator but not null island", lat: 0, lng: -0.1278},
		{name: "on the prime meridian but not null island", lat: 51.5074, lng: 0},
		{name: "a hair off null island is a real place", lat: 0.0001, lng: 0},

		{name: "latitude above range", lat: 90.1, lng: 0, wantErr: true},
		{name: "latitude below range", lat: -90.1, lng: 0, wantErr: true},
		{name: "longitude above range", lat: 0, lng: 180.1, wantErr: true},
		{name: "longitude below range", lat: 0, lng: -180.1, wantErr: true},

		{name: "NaN latitude", lat: math.NaN(), lng: 0, wantErr: true},
		{name: "NaN longitude", lat: 0, lng: math.NaN(), wantErr: true},
		{name: "infinite latitude", lat: math.Inf(1), lng: 0, wantErr: true},
		{name: "negative infinite longitude", lat: 0, lng: math.Inf(-1), wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateLatLng(tc.lat, tc.lng)
			if tc.wantErr && err == nil {
				t.Fatalf("ValidateLatLng(%v, %v) = nil, want an error", tc.lat, tc.lng)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("ValidateLatLng(%v, %v) = %v, want nil", tc.lat, tc.lng, err)
			}
		})
	}
}

// TestValidateLatLng_NullIslandErrorExplainsItself pins the message, not
// just the rejection. The caller's actual problem is upstream — a location
// permission denied, or a fix never acquired — and an error reading
// "latitude 0 out of range" (which is false; 0 is in range) would send
// whoever reads it looking in the wrong place.
func TestValidateLatLng_NullIslandErrorExplainsItself(t *testing.T) {
	err := ValidateLatLng(0, 0)
	if err == nil {
		t.Fatal("ValidateLatLng(0, 0) = nil")
	}
	if strings.Contains(err.Error(), "out of range") {
		t.Errorf("null island reported as a range error, which is misleading — 0 is in range: %q", err)
	}
	if !strings.Contains(err.Error(), "(0, 0)") {
		t.Errorf("error does not name the offending value: %q", err)
	}
}
