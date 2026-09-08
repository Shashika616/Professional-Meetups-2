package geocoding

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

const (
	// defaultBaseURL is the public Nominatim instance — free, no signup.
	// Explicitly provisional (see TESTING-NOTES.md, same treatment as the
	// Stadia map key): rate-limited and its usage policy prohibits
	// sustained production volume. Swap via WithBaseURL (or a whole new
	// ReverseGeocoder implementation behind the same interface) once
	// Android's real map vendor is decided — no call-site changes needed
	// elsewhere.
	defaultBaseURL = "https://nominatim.openstreetmap.org/reverse"

	// defaultTimeout is deliberately short — this call sits inline in
	// CreateMeetup's request path (ADR-029: synchronous, not async/
	// outbox), so a hung request must not stall meetup creation for long.
	defaultTimeout = 3 * time.Second

	// defaultUserAgent — Nominatim's usage policy requires a real,
	// identifying User-Agent on every request; unidentified requests are
	// liable to be blocked outright.
	defaultUserAgent = "ProfessionalConnectionsApp/1.0 (+https://github.com/professional-connections)"

	// labelSegmentLimit trims Nominatim's often-long comma-separated
	// display_name (e.g. "123, Galle Road, Colombo 03, Colombo, Western
	// Province, 00300, Sri Lanka") down to its first few segments — a
	// full display_name is usually too long for a meetup card's label;
	// the leading segments (street/POI, then locality) are the
	// human-relevant part for "where am I meeting this person," the
	// trailing province/postcode/country segments aren't.
	labelSegmentLimit = 3
)

// NominatimReverseGeocoder calls a Nominatim-compatible reverse-geocoding
// HTTP endpoint. The safe-fallback-on-failure logic (ADR-029) lives here,
// inside the implementation, not at CreateMeetup's call site — mirrors how
// sms.LoggingSmsSender's own safe-no-op behavior is a property of that
// concrete implementation, not something every caller re-implements.
// ReverseGeocode therefore never returns a non-nil error; see the
// ReverseGeocoder interface's own doc comment.
type NominatimReverseGeocoder struct {
	baseURL    string
	userAgent  string
	httpClient *http.Client
}

// Option customizes a NominatimReverseGeocoder — currently only used by
// tests to point at an httptest.Server instead of the real endpoint.
type Option func(*NominatimReverseGeocoder)

// WithBaseURL overrides the reverse-geocoding endpoint. Test-only today,
// but also the seam a future Pelias/Nominatim-compatible hosted provider
// (e.g. Geocode Earth) would swap in through.
func WithBaseURL(u string) Option {
	return func(g *NominatimReverseGeocoder) { g.baseURL = u }
}

// NewNominatimReverseGeocoder constructs a NominatimReverseGeocoder. No
// credentials required for the default public endpoint — unlike the
// Twilio/Resend pattern, there's no "unconfigured" state to gate a
// separate Logging-style fallback implementation on; this is just "the
// real call, with a safe fallback on failure" (ADR-029).
func NewNominatimReverseGeocoder(opts ...Option) *NominatimReverseGeocoder {
	g := &NominatimReverseGeocoder{
		baseURL:    defaultBaseURL,
		userAgent:  defaultUserAgent,
		httpClient: &http.Client{Timeout: defaultTimeout},
	}
	for _, opt := range opts {
		opt(g)
	}
	return g
}

// nominatimResponse is the subset of Nominatim's reverse-geocode JSON
// response this package actually uses. Nominatim reports a failure (e.g.
// "Unable to geocode") as a 200 response with an "error" field, not a
// non-200 status — checked explicitly below, not just relying on the HTTP
// status code.
type nominatimResponse struct {
	DisplayName string `json:"display_name"`
	Error       string `json:"error"`
}

// ReverseGeocode never returns a non-nil error — any failure (network,
// timeout, non-200, malformed/empty response) is logged and converted to
// (FallbackLabel, nil), per this type's own doc comment and ADR-029's
// "never blocks or fails CreateMeetup on a third-party API" decision.
func (g *NominatimReverseGeocoder) ReverseGeocode(ctx context.Context, lat, lng float64) (string, error) {
	label, err := g.reverseGeocode(ctx, lat, lng)
	if err != nil {
		slog.Default().Warn("reverse geocode failed, using fallback label", "error", err)
		return FallbackLabel, nil
	}
	return label, nil
}

func (g *NominatimReverseGeocoder) reverseGeocode(ctx context.Context, lat, lng float64) (string, error) {
	u := fmt.Sprintf("%s?format=jsonv2&lat=%f&lon=%f", g.baseURL, lat, lng)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", fmt.Errorf("geocoding: build request: %w", err)
	}
	req.Header.Set("User-Agent", g.userAgent)
	req.Header.Set("Accept", "application/json")

	resp, err := g.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("geocoding: request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("geocoding: unexpected status %d", resp.StatusCode)
	}

	var parsed nominatimResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", fmt.Errorf("geocoding: decode response: %w", err)
	}
	if parsed.Error != "" {
		return "", fmt.Errorf("geocoding: nominatim reported an error: %s", parsed.Error)
	}
	if parsed.DisplayName == "" {
		return "", fmt.Errorf("geocoding: empty display_name")
	}

	return shortenLabel(parsed.DisplayName), nil
}

// shortenLabel keeps only the first labelSegmentLimit comma-separated
// segments of a Nominatim display_name — see labelSegmentLimit's own doc
// comment for why.
func shortenLabel(displayName string) string {
	parts := strings.Split(displayName, ",")
	limit := labelSegmentLimit
	if len(parts) < limit {
		limit = len(parts)
	}
	shortened := make([]string, limit)
	for i := 0; i < limit; i++ {
		shortened[i] = strings.TrimSpace(parts[i])
	}
	return strings.Join(shortened, ", ")
}
