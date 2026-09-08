package geocoding

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNominatimReverseGeocoder_ParsesAndShortensDisplayName(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"display_name":"123, Galle Road, Colombo 03, Colombo, Western Province, 00300, Sri Lanka"}`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil (never propagated)", err)
	}
	if label != "123, Galle Road, Colombo 03" {
		t.Errorf("label = %q, want the first 3 comma-separated segments only", label)
	}
}

func TestNominatimReverseGeocoder_ShortDisplayNameKeptAsIs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"display_name":"Colombo, Sri Lanka"}`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v", err)
	}
	if label != "Colombo, Sri Lanka" {
		t.Errorf("label = %q, want %q (fewer than the segment limit, kept whole)", label, "Colombo, Sri Lanka")
	}
}

func TestNominatimReverseGeocoder_SendsRequiredUserAgent(t *testing.T) {
	var gotUserAgent string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUserAgent = r.Header.Get("User-Agent")
		_, _ = w.Write([]byte(`{"display_name":"Test Place"}`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	if _, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612); err != nil {
		t.Fatalf("ReverseGeocode() error: %v", err)
	}
	if gotUserAgent == "" {
		t.Error("User-Agent header was empty — Nominatim's usage policy requires a real one")
	}
}

// TestNominatimReverseGeocoder_NonOKStatusFallsBackSafely (ADR-029) — a
// non-200 response never propagates as an error to the caller; it falls
// back to FallbackLabel with a nil error.
func TestNominatimReverseGeocoder_NonOKStatusFallsBackSafely(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil (CreateMeetup must never fail because geocoding failed)", err)
	}
	if label != FallbackLabel {
		t.Errorf("label = %q, want the safe fallback %q, not a raw error", label, FallbackLabel)
	}
}

// TestNominatimReverseGeocoder_NominatimReportedErrorFallsBackSafely —
// Nominatim reports its own failures (e.g. "Unable to geocode") as a 200
// response carrying an "error" field, not a non-200 status.
func TestNominatimReverseGeocoder_NominatimReportedErrorFallsBackSafely(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"error":"Unable to geocode"}`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil", err)
	}
	if label != FallbackLabel {
		t.Errorf("label = %q, want the safe fallback %q", label, FallbackLabel)
	}
}

// TestNominatimReverseGeocoder_MalformedResponseFallsBackSafely — a
// non-JSON body must not propagate a decode error to the caller either.
func TestNominatimReverseGeocoder_MalformedResponseFallsBackSafely(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`not json`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil", err)
	}
	if label != FallbackLabel {
		t.Errorf("label = %q, want the safe fallback %q", label, FallbackLabel)
	}
}

// TestNominatimReverseGeocoder_TimeoutFallsBackSafely — a hung/slow
// endpoint must not block the caller past the configured timeout, and
// must still fall back safely rather than propagate a timeout error.
func TestNominatimReverseGeocoder_TimeoutFallsBackSafely(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte(`{"display_name":"Too Slow"}`))
	}))
	defer server.Close()

	g := &NominatimReverseGeocoder{
		baseURL:    server.URL,
		userAgent:  defaultUserAgent,
		httpClient: &http.Client{Timeout: 50 * time.Millisecond},
	}
	start := time.Now()
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil", err)
	}
	if label != FallbackLabel {
		t.Errorf("label = %q, want the safe fallback %q", label, FallbackLabel)
	}
	if elapsed >= 200*time.Millisecond {
		t.Errorf("ReverseGeocode() took %v, want it to time out well before the server's 200ms response", elapsed)
	}
}

// TestNominatimReverseGeocoder_EmptyDisplayNameFallsBackSafely — a 200
// response with no usable display_name must not produce an empty label.
func TestNominatimReverseGeocoder_EmptyDisplayNameFallsBackSafely(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()

	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL))
	label, err := g.ReverseGeocode(context.Background(), 6.9271, 79.8612)
	if err != nil {
		t.Fatalf("ReverseGeocode() error: %v, want nil", err)
	}
	if label != FallbackLabel {
		t.Errorf("label = %q, want the safe fallback %q, not empty", label, FallbackLabel)
	}
}
