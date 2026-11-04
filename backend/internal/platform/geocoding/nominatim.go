package geocoding

import (
	"container/list"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
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
	// The app's real name and a page to reach its operator, as Nominatim's
	// usage policy asks (#118): the old value named a project that does
	// not exist.
	defaultUserAgent = "TieHere/1.1 (+https://professional-meetups-976d2.web.app)"

	// maxResponseBytes caps what is read from a response (#118).
	maxResponseBytes = 64 << 10

	// defaultMinInterval spaces requests out: Nominatim's policy is at most
	// one a second from an application (#118).
	defaultMinInterval = time.Second

	// cacheSize and cacheTTL bound the small label cache, keyed by the
	// place rounded to about 110 m.
	cacheSize = 256
	cacheTTL  = 24 * time.Hour

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

	// minInterval and next space requests out (#118).
	minInterval time.Duration
	throttle    sync.Mutex
	next        time.Time

	// cache holds recent labels by rounded place, oldest first.
	cacheMu sync.Mutex
	cache   map[string]*list.Element
	order   *list.List
}

type cachedLabel struct {
	key     string
	label   string
	expires time.Time
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
// WithMinInterval sets the spacing between requests (tests use a short one).
func WithMinInterval(d time.Duration) Option {
	return func(g *NominatimReverseGeocoder) { g.minInterval = d }
}

func NewNominatimReverseGeocoder(opts ...Option) *NominatimReverseGeocoder {
	g := &NominatimReverseGeocoder{
		baseURL:     defaultBaseURL,
		userAgent:   defaultUserAgent,
		httpClient:  &http.Client{Timeout: defaultTimeout},
		minInterval: defaultMinInterval,
		cache:       map[string]*list.Element{},
		order:       list.New(),
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
	// Rounded to about 110 m before anything else (#118): the label of a
	// street does not need the exact point, and neither the cache nor the
	// third party gets one.
	lat, lng = round3(lat), round3(lng)
	key := strconv.FormatFloat(lat, 'f', 3, 64) + "," + strconv.FormatFloat(lng, 'f', 3, 64)
	if label, ok := g.cached(key); ok {
		return label, nil
	}
	if err := g.wait(ctx); err != nil {
		return "", fmt.Errorf("geocoding: throttled: %w", err)
	}

	q := url.Values{"format": {"jsonv2"}, "lat": {strconv.FormatFloat(lat, 'f', 3, 64)}, "lon": {strconv.FormatFloat(lng, 'f', 3, 64)}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return "", errors.New("geocoding: build request")
	}
	req.Header.Set("User-Agent", g.userAgent)
	req.Header.Set("Accept", "application/json")

	resp, err := g.httpClient.Do(req)
	if err != nil {
		// A *url.Error's text includes the URL, and so the coordinates
		// (#118); only the cause underneath is reported.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return "", fmt.Errorf("geocoding: request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("geocoding: unexpected status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return "", errors.New("geocoding: read response")
	}
	if len(body) > maxResponseBytes {
		return "", errors.New("geocoding: response too large")
	}
	var parsed nominatimResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", errors.New("geocoding: decode response")
	}
	if parsed.Error != "" {
		return "", errors.New("geocoding: nominatim reported an error")
	}
	if parsed.DisplayName == "" {
		return "", fmt.Errorf("geocoding: empty display_name")
	}

	label := shortenLabel(parsed.DisplayName)
	g.store(key, label)
	return label, nil
}

func round3(v float64) float64 { return math.Round(v*1000) / 1000 }

// wait holds the caller until minInterval after the previous request.
func (g *NominatimReverseGeocoder) wait(ctx context.Context) error {
	g.throttle.Lock()
	now := time.Now()
	start := g.next
	if start.Before(now) {
		start = now
	}
	g.next = start.Add(g.minInterval)
	g.throttle.Unlock()
	if d := time.Until(start); d > 0 {
		t := time.NewTimer(d)
		defer t.Stop()
		select {
		case <-t.C:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

func (g *NominatimReverseGeocoder) cached(key string) (string, bool) {
	g.cacheMu.Lock()
	defer g.cacheMu.Unlock()
	el, ok := g.cache[key]
	if !ok {
		return "", false
	}
	c := el.Value.(*cachedLabel)
	if time.Now().After(c.expires) {
		g.order.Remove(el)
		delete(g.cache, key)
		return "", false
	}
	return c.label, true
}

func (g *NominatimReverseGeocoder) store(key, label string) {
	g.cacheMu.Lock()
	defer g.cacheMu.Unlock()
	if el, ok := g.cache[key]; ok {
		g.order.Remove(el)
	}
	for g.order.Len() >= cacheSize {
		oldest := g.order.Front()
		delete(g.cache, oldest.Value.(*cachedLabel).key)
		g.order.Remove(oldest)
	}
	g.cache[key] = g.order.PushBack(&cachedLabel{key: key, label: label, expires: time.Now().Add(cacheTTL)})
}

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
