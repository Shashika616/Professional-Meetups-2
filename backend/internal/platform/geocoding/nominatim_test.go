package geocoding

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
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

// Plan 30B, 3.3 (#118): a failed request's error must not carry the URL,
// which holds the coordinates, into the logs.
func TestNominatimErrorsCarryNoCoordinates(t *testing.T) {
	g := NewNominatimReverseGeocoder(WithBaseURL("http://127.0.0.1:1/reverse"), WithMinInterval(0))
	_, err := g.reverseGeocode(context.Background(), 6.927123, 79.861234)
	if err == nil {
		t.Fatal("an unreachable server answered")
	}
	for _, leak := range []string{"6.927", "79.861", "lat=", "lon="} {
		if strings.Contains(err.Error(), leak) {
			t.Errorf("the error %q carries %q", err, leak)
		}
	}
}

// #118: the response is read to at most 64 KB.
func TestNominatimResponseIsCapped(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"display_name":"` + strings.Repeat("a", 70<<10) + `"}`))
	}))
	defer server.Close()
	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL), WithMinInterval(0))
	if got, _ := g.ReverseGeocode(context.Background(), 6.9, 79.8); got != FallbackLabel {
		t.Errorf("an oversized response gave %q, want the fallback", got[:min(len(got), 20)])
	}
}

// #118: one request per place (rounded to about 110 m), cached, and the
// coordinates sent are the rounded ones; and requests are spaced out.
func TestNominatimCachesByRoundedPlaceAndThrottles(t *testing.T) {
	var hits atomic.Int32
	var lastQuery atomic.Value
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		lastQuery.Store(r.URL.RawQuery)
		_, _ = w.Write([]byte(`{"display_name":"Colombo 3, Colombo, Western Province"}`))
	}))
	defer server.Close()
	g := NewNominatimReverseGeocoder(WithBaseURL(server.URL), WithMinInterval(200*time.Millisecond))
	ctx := context.Background()
	_, _ = g.ReverseGeocode(ctx, 6.927123, 79.861234)
	_, _ = g.ReverseGeocode(ctx, 6.927301, 79.861049) // the same place, rounded
	if hits.Load() != 1 {
		t.Errorf("%d requests for one place, want 1", hits.Load())
	}
	if q := lastQuery.Load().(string); !strings.Contains(q, "lat=6.927&") || !strings.Contains(q, "lon=79.861") {
		t.Errorf("sent %q, want the rounded coordinates", q)
	}
	started := time.Now()
	_, _ = g.ReverseGeocode(ctx, 7.2906, 80.6337)
	if time.Since(started) < 150*time.Millisecond {
		t.Error("a second request went out without waiting for the interval")
	}
	if hits.Load() != 2 {
		t.Errorf("%d requests, want 2", hits.Load())
	}
}

func TestNominatimUserAgentNamesTheApp(t *testing.T) {
	if !strings.HasPrefix(defaultUserAgent, "TieHere/") || !strings.Contains(defaultUserAgent, "https://") {
		t.Errorf("User-Agent %q does not name the app and a contact URL", defaultUserAgent)
	}
}
