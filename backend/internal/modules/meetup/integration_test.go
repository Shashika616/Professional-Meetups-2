package meetup_test

// Integration tests: the real meetup module, wired to real Postgres
// repositories, against the real migrations — including PostGIS. This is the
// layer that actually exercises the ported SQL (the ST_DWithin radius filter
// and its host bypass, the ownership-scoped UPDATEs, the keyset pagination,
// the transactional accept-with-auto-reject), plus every authorization guard
// and the event flow into the read-model caches.
//
// External (package meetup_test) on purpose: these drive the module through
// its one public interface, exactly as internal/grpcapi does.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

const defaultTestDatabaseURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"

// migrationsURL is relative to this file's directory — one migration history
// for every module (ADR-001 §3), so this brings up auth's schema too.
const migrationsURL = "file://../../../migrations"

// Colombo, and a point ~200km away (well outside the 50km radius).
const (
	colomboLat, colomboLng = 6.9271, 79.8612
	farAwayLat, farAwayLng = 8.5874, 81.2152
)

func requirePostgres(t *testing.T) string {
	t.Helper()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = defaultTestDatabaseURL
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatalf("DATABASE_URL %q is not a URL: %v", dbURL, err)
	}
	hostPort := parsed.Host
	if !strings.Contains(hostPort, ":") {
		hostPort += ":5432"
	}
	conn, err := net.DialTimeout("tcp", hostPort, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping integration test (run `docker compose up -d postgres` first): %v", hostPort, err)
	}
	_ = conn.Close()

	// Integration tests get their OWN database, never the one a running
	// monolith is attached to — see db.EnsureTestDatabase for why that is a
	// correctness requirement here and not just hygiene (briefly: the live
	// app's outbox poller claims the rows these tests queue, and its
	// dead-token cleanup deletes their fixtures).
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("prepare isolated test database: %v", err)
	}
	return testURL
}

// recordingBus captures published events so the tests can assert the
// cross-module flows fire, while still delivering to the real subscribers
// the harness registers.
type recordingBus struct {
	*eventbus.InMemoryBus
	mu     sync.Mutex
	events []eventbus.Event
}

func newRecordingBus() *recordingBus {
	return &recordingBus{InMemoryBus: eventbus.New(slog.New(slog.DiscardHandler))}
}

func (b *recordingBus) Publish(ctx context.Context, topic string, payload any) error {
	b.mu.Lock()
	b.events = append(b.events, eventbus.Event{Topic: topic, Payload: payload, OccurredAt: time.Now().UTC()})
	b.mu.Unlock()
	return b.InMemoryBus.Publish(ctx, topic, payload)
}

func (b *recordingBus) countOf(topic string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for _, e := range b.events {
		if e.Topic == topic {
			n++
		}
	}
	return n
}

func (b *recordingBus) payloadsOf(topic string) []any {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []any
	for _, e := range b.events {
		if e.Topic == topic {
			out = append(out, e.Payload)
		}
	}
	return out
}

// stubGeocoder stands in for Nominatim — CreateMeetup calls it inline for a
// placeholder label, and no test should depend on a live third-party HTTP
// endpoint.
type stubGeocoder struct{ label string }

func (g stubGeocoder) ReverseGeocode(context.Context, float64, float64) (string, error) {
	return g.label, nil
}

type harness struct {
	svc               meetup.Service
	pool              *pgxpool.Pool
	bus               *recordingBus
	userDisplayCache  meetuprepo.UserDisplayCacheRepository
	userLocationCache meetuprepo.UserLocationCacheRepository
	deviceTokens      meetuprepo.DeviceTokenRepository
	outbox            meetuprepo.NotificationOutboxRepository
	safetyState       meetuprepo.SafetyStateRepository
	requests          meetuprepo.MeetupRequestRepository
	meetups           meetuprepo.MeetupRepository

	// completedOutbox and the wake counter cover the async meetups-completed
	// recompute (plan 06). completedWakes is incremented by the wake func
	// handed to the meetup repository, so a test can assert that a
	// completion actually nudged the poller — a poller built but never woken
	// was a real, self-found bug in the original notification outbox work,
	// so it is checked rather than assumed.
	completedOutbox meetuprepo.MeetupsCompletedOutboxRepository
	completedWakes  *atomic.Int64

	// contacts records what the meetup module asked the auth module to send
	// to trusted contacts, so the share tests can assert on the FACTS
	// crossing that boundary rather than on a real SMS.
	contacts *fakeContactNotifier
}

// fakeContactNotifier stands in for the auth module's trusted-contact
// fan-out. It records the calls and, like the real one, refuses ids that are
// not in its own allowlist — that refusal is the security property the
// share path depends on, so a fake that accepted anything would make the
// tests prove less than they appear to.
type fakeContactNotifier struct {
	mu    sync.Mutex
	owned map[string]bool
	calls []meetup.ContactShare
	err   error
}

func newFakeContactNotifier(ownedIDs ...string) *fakeContactNotifier {
	owned := map[string]bool{}
	for _, id := range ownedIDs {
		owned[id] = true
	}
	return &fakeContactNotifier{owned: owned}
}

func (f *fakeContactNotifier) NotifyMeetupShare(_ context.Context, _ string, share meetup.ContactShare) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return 0, f.err
	}
	f.calls = append(f.calls, share)
	notified := 0
	for _, id := range share.ContactIDs {
		if f.owned[id] {
			notified++
		}
	}
	if notified == 0 {
		return 0, fmt.Errorf("fake: none of those contacts belong to you: %w", apperror.ErrInvalidInput)
	}
	return notified, nil
}

func (f *fakeContactNotifier) lastCall() (meetup.ContactShare, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) == 0 {
		return meetup.ContactShare{}, false
	}
	return f.calls[len(f.calls)-1], true
}

func (f *fakeContactNotifier) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

// drainCompletedOutbox runs exactly one deterministic pass of the
// meetups-completed poller, standing in for the background goroutine
// cmd/monolith starts. Returns nothing: the assertions are on what the pass
// published and wrote, not on the pass itself.
func (h *harness) drainCompletedOutbox(t *testing.T, ctx context.Context) {
	t.Helper()
	poller := outbox.New(
		h.completedOutbox,
		meetup.NewCompletedRecompute(h.completedOutbox, h.bus, slog.New(slog.DiscardHandler)).Process,
		outbox.WithLogger(slog.New(slog.DiscardHandler)),
	)
	poller.DrainOnce(ctx)
}

// pendingCompletedRows reports how many recompute intents are still waiting,
// for tests asserting the row was written but not yet processed.
func (h *harness) pendingCompletedRows(t *testing.T, ctx context.Context) int {
	t.Helper()
	n, err := h.completedOutbox.CountPending(ctx)
	if err != nil {
		t.Fatalf("count pending meetups-completed: %v", err)
	}
	return n
}

// completedOutboxMeetupIDs returns the meetup ids recorded on every
// not-yet-processed outbox row, so a test can assert WHICH meetups were
// scheduled rather than only how many rows exist.
func (h *harness) completedOutboxMeetupIDs(t *testing.T, ctx context.Context) []string {
	t.Helper()
	rows, err := h.pool.Query(ctx, `
		SELECT meetup_ids FROM meetup.meetups_completed_outbox
		WHERE processed_at IS NULL AND dead_lettered_at IS NULL
		ORDER BY created_at`)
	if err != nil {
		t.Fatalf("query meetups_completed_outbox: %v", err)
	}
	defer rows.Close()

	var all []string
	for rows.Next() {
		var ids []string
		if err := rows.Scan(&ids); err != nil {
			t.Fatalf("scan meetup_ids: %v", err)
		}
		all = append(all, ids...)
	}
	return all
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dbURL := requirePostgres(t)

	if err := db.Migrate(dbURL, migrationsURL); err != nil {
		t.Fatalf("run migrations: %v", err)
	}

	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	// Serialise against every other integration-test harness in this repo —
	// see db.IntegrationTestLockKey. This package's truncate below includes
	// auth.users, which the auth module's own harness is simultaneously
	// populating when both packages run in parallel.
	release, err := db.AcquireIntegrationTestLock(ctx, pool)
	if err != nil {
		t.Fatalf("acquire integration test lock: %v", err)
	}
	t.Cleanup(release)

	// Clean slate per test. auth.* is truncated too: the rating-updated
	// consumer writes into auth.users, so these tests need it empty and
	// seedable.
	if _, err := pool.Exec(ctx, `
		TRUNCATE meetup.meetups, meetup.meetup_requests, meetup.safety_state,
		         meetup.meetup_feedback, meetup.device_tokens, meetup.meetup_user_ratings,
		         meetup.user_display_cache, meetup.user_location_cache, meetup.subscription_cache,
		         meetup.notification_outbox, meetup.meetups_completed_outbox,
		         meetup.safety_share,
		         auth.users
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	bus := newRecordingBus()
	logger := slog.New(slog.DiscardHandler)

	deviceTokens := meetuprepo.NewDeviceTokenRepository(pool)
	notificationOutbox := meetuprepo.NewNotificationOutboxRepository(pool)
	userLocationCache := meetuprepo.NewUserLocationCacheRepository(pool)
	safetyState := meetuprepo.NewSafetyStateRepository(pool)
	requests := meetuprepo.NewMeetupRequestRepository(pool, bus, logger)
	completedOutbox := meetuprepo.NewMeetupsCompletedOutboxRepository(pool)
	completedWakes := &atomic.Int64{}
	meetups := meetuprepo.NewMeetupRepository(pool, bus, logger, func() {
		completedWakes.Add(1)
	})

	contacts := newFakeContactNotifier()
	svc := meetup.New(meetup.Deps{
		ContactNotifier: contacts,
		Meetups:         meetups,
		Requests:        requests,
		SafetyState:     safetyState,
		Feedback:        meetuprepo.NewFeedbackRepository(pool),
		Ratings:         meetuprepo.NewRatingRepository(pool, bus, logger),
		DeviceTokens:    deviceTokens,
		UserLocations:   userLocationCache,
		Outbox:          notificationOutbox,
		Geocoder:        stubGeocoder{label: "Reverse Geocoded Place"},
		Logger:          logger,
	})

	return &harness{
		svc:               svc,
		pool:              pool,
		bus:               bus,
		userDisplayCache:  meetuprepo.NewUserDisplayCacheRepository(pool),
		userLocationCache: userLocationCache,
		deviceTokens:      deviceTokens,
		outbox:            notificationOutbox,
		safetyState:       safetyState,
		requests:          requests,
		meetups:           meetups,
		completedOutbox:   completedOutbox,
		completedWakes:    completedWakes,
		contacts:          contacts,
	}
}

// serviceWithWake builds a second Service over the SAME repositories as the
// harness, differing only in that it nudges a poller after each committing
// write (§F5). Used by the wake-signal test, which has to observe delivery
// latency rather than just the queued row.
func (h *harness) serviceWithWake(t *testing.T, wake func()) meetup.Service {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	return meetup.New(meetup.Deps{
		Meetups:       h.meetups,
		Requests:      h.requests,
		SafetyState:   h.safetyState,
		Feedback:      meetuprepo.NewFeedbackRepository(h.pool),
		Ratings:       meetuprepo.NewRatingRepository(h.pool, h.bus, logger),
		DeviceTokens:  h.deviceTokens,
		UserLocations: h.userLocationCache,
		Outbox:        h.outbox,
		Wake:          wake,
		Geocoder:      stubGeocoder{label: "Reverse Geocoded Place"},
		Logger:        logger,
	})
}

// newUserID returns a fresh uuid. These are auth.users ids from the meetup
// module's point of view — deliberately just UUIDs, with no FK (ADR-001 §3),
// so a test doesn't need an auth row to exist unless it's checking the
// rating-cache flow.
func newUserID(t *testing.T, h *harness) string {
	t.Helper()
	var id string
	if err := h.pool.QueryRow(context.Background(), `SELECT gen_random_uuid()::text`).Scan(&id); err != nil {
		t.Fatalf("generate user id: %v", err)
	}
	return id
}

// newUUID is a bare uuid with no row behind it — for ids that stand in for
// another module's rows (a trusted contact lives in auth's schema, which this
// module deliberately cannot see).
func newUUID(t *testing.T) string {
	t.Helper()
	return uuid.NewString()
}

// createMeetup makes one meetup at the given coordinates, hosted by host.
func (h *harness) createMeetup(t *testing.T, host string, intent meetup.Intent, lat, lng float64) meetup.Meetup {
	t.Helper()
	m, err := h.svc.CreateMeetup(context.Background(), meetup.CreateMeetupRequest{
		HostUserID:     host,
		HostTrustLevel: 4, // high enough for every intent
		Intent:         intent,
		WindowStart:    time.Now().Add(time.Hour),
		WindowEnd:      time.Now().Add(3 * time.Hour),
		LocationLat:    lat,
		LocationLng:    lng,
		LocationLabel:  "Test Cafe",
		Capacity:       5,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	return m
}

func isSentinel(err, sentinel error) bool {
	for err != nil {
		if err == sentinel {
			return true
		}
		unwrapped, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = unwrapped.Unwrap()
	}
	return false
}

// --- CreateMeetup ------------------------------------------------------

func TestCreateMeetup_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if m.ID == "" || !m.IsHostedByMe {
		t.Fatalf("created meetup = %+v, want an id and IsHostedByMe", m)
	}
	if m.Status != meetup.StatusOpen {
		t.Errorf("Status = %q, want open", m.Status)
	}

	// The PostGIS geography column is populated by the trigger, from the
	// plain lat/lng — no write path had to know about it.
	var hasLocation bool
	if err := h.pool.QueryRow(ctx, `SELECT location IS NOT NULL FROM meetup.meetups WHERE id = $1`, m.ID).Scan(&hasLocation); err != nil {
		t.Fatalf("read location: %v", err)
	}
	if !hasLocation {
		t.Error("meetups.location is NULL — the sync trigger didn't populate the geography column")
	}

	// The host gets their own Safety Gate row at creation ("a host, also a
	// user"), which is what makes the Safety Gate reachable for them at all.
	if _, err := h.safetyState.Get(ctx, m.ID, host); err != nil {
		t.Errorf("no safety_state row for the host after creation: %v", err)
	}

	// meetup-created fires, so the nearby-notify fan-out has something to
	// subscribe to.
	if h.bus.countOf(eventbus.TopicMeetupCreated) != 1 {
		t.Errorf("meetup-created published %d times, want 1", h.bus.countOf(eventbus.TopicMeetupCreated))
	}
}

// TestCreateMeetup_TrustGate is the below-trust-level rejection the prompt
// calls for. ride_share and dating require level 4; everything else 2.
func TestCreateMeetup_TrustGate(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	cases := []struct {
		name       string
		intent     meetup.Intent
		trustLevel int
		wantErr    bool
	}{
		// CHANGED (ADR-002 §4): CreateMeetup now uses the HOST bar, raised
		// to 3 for ordinary intents. "coffee at level 2 is allowed" became
		// "rejected" — that single flip is the entire behaviour change, and
		// it is the reason this table could not simply gain rows.
		{"coffee at level 1 is rejected", meetup.IntentCoffee, 1, true},
		{"coffee at level 2 is NO LONGER allowed to host", meetup.IntentCoffee, 2, true},
		{"coffee at level 3 is allowed to host", meetup.IntentCoffee, 3, false},
		{"lunch at level 2 is no longer allowed to host", meetup.IntentLunch, 2, true},
		{"lunch at level 3 is allowed to host", meetup.IntentLunch, 3, false},
		// ride_share/dating are unchanged at 4 for both actions (ADR-004).
		{"ride_share at level 2 is rejected", meetup.IntentRideShare, 2, true},
		{"ride_share at level 3 is rejected", meetup.IntentRideShare, 3, true},
		{"ride_share at level 4 is allowed", meetup.IntentRideShare, 4, false},
		{"dating at level 3 is rejected", meetup.IntentDating, 3, true},
		{"dating at level 4 is allowed", meetup.IntentDating, 4, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
				HostUserID: host, HostTrustLevel: tc.trustLevel, Intent: tc.intent,
				WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(2 * time.Hour),
				LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
			})
			if tc.wantErr {
				if err == nil {
					t.Fatal("meetup was created below the intent's trust floor")
				}
				if !isSentinel(err, apperror.ErrForbidden) {
					t.Errorf("error = %v, want ErrForbidden", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("CreateMeetup: %v", err)
			}
		})
	}
}

func TestCreateMeetup_Validation(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	base := func() meetup.CreateMeetupRequest {
		return meetup.CreateMeetupRequest{
			HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
			WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(2 * time.Hour),
			LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
		}
	}

	cases := []struct {
		name   string
		mutate func(*meetup.CreateMeetupRequest)
	}{
		{"capacity 0", func(r *meetup.CreateMeetupRequest) { r.Capacity = 0 }},
		{"capacity 21", func(r *meetup.CreateMeetupRequest) { r.Capacity = 21 }},
		{"window_end before window_start", func(r *meetup.CreateMeetupRequest) { r.WindowEnd = r.WindowStart.Add(-time.Hour) }},
		{"window_end equal to window_start", func(r *meetup.CreateMeetupRequest) { r.WindowEnd = r.WindowStart }},
		{"window_start well in the past", func(r *meetup.CreateMeetupRequest) {
			r.WindowStart = time.Now().Add(-2 * time.Hour)
			r.WindowEnd = time.Now().Add(time.Hour)
		}},
		{"latitude out of range", func(r *meetup.CreateMeetupRequest) { r.LocationLat = 91 }},
		{"longitude out of range", func(r *meetup.CreateMeetupRequest) { r.LocationLng = 181 }},
		{"unrecognized intent", func(r *meetup.CreateMeetupRequest) { r.Intent = meetup.Intent("brunch") }},
		{"oversized location label", func(r *meetup.CreateMeetupRequest) { r.LocationLabel = strings.Repeat("a", 501) }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := base()
			tc.mutate(&req)
			if _, err := h.svc.CreateMeetup(ctx, req); err == nil {
				t.Fatal("invalid input was accepted")
			}
		})
	}
}

// TestCreateMeetup_ReverseGeocodesPlaceholderLabel: an empty or placeholder
// label is replaced; a real one the host chose is never overridden.
func TestCreateMeetup_ReverseGeocodesPlaceholderLabel(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	for _, label := range []string{"", "Current location", "  CURRENT LOCATION  "} {
		m, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
			HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
			WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(2 * time.Hour),
			LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: label, Capacity: 2,
		})
		if err != nil {
			t.Fatalf("CreateMeetup(label=%q): %v", label, err)
		}
		if m.LocationLabel == nil || *m.LocationLabel != "Reverse Geocoded Place" {
			t.Errorf("label %q was not replaced: got %v", label, m.LocationLabel)
		}
	}

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if m.LocationLabel == nil || *m.LocationLabel != "Test Cafe" {
		t.Errorf("a host's own real label was overridden: got %v", m.LocationLabel)
	}
}

// --- ListOpenMeetups: the radius filter and its host bypass -------------

// TestListOpenMeetups_HostBypassesRadius is the host-bypass-radius case the
// prompt names, with its stranger-still-excluded control.
//
// Both meetups are ~200km from the viewer. The one the viewer HOSTS must
// still come back (they'd otherwise be unable to see their own meetup on the
// browse screen after travelling, or when scheduling somewhere they'll be
// later). A stranger's equally-distant meetup must still be excluded — the
// bypass is scoped to hosts, and would be a 50km-visibility hole otherwise.
func TestListOpenMeetups_HostBypassesRadius(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	viewer := newUserID(t, h)
	stranger := newUserID(t, h)

	// Viewer is in Colombo; both meetups are ~200km away.
	ownFarAway := h.createMeetup(t, viewer, meetup.IntentCoffee, farAwayLat, farAwayLng)
	strangerFarAway := h.createMeetup(t, stranger, meetup.IntentCoffee, farAwayLat, farAwayLng)
	// A control that IS nearby, hosted by the stranger — proves the radius
	// filter isn't simply returning everything.
	strangerNearby := h.createMeetup(t, stranger, meetup.IntentCoffee, colomboLat, colomboLng)

	result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentCoffee),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}

	got := map[string]bool{}
	for _, m := range result.Meetups {
		got[m.ID] = true
	}

	if !got[ownFarAway.ID] {
		t.Error("the viewer's OWN out-of-radius meetup was not returned — the host bypass is missing")
	}
	if got[strangerFarAway.ID] {
		t.Error("a STRANGER's out-of-radius meetup was returned — the bypass must be scoped to the host only")
	}
	if !got[strangerNearby.ID] {
		t.Error("a stranger's in-radius meetup was not returned — the radius filter is excluding too much")
	}
}

// TestListOpenMeetups_RadiusIs50km pins the radius at its boundary rather
// than 200km out: a meetup 45km from the viewer is in, one 55km out is
// not. Latitude degrees are ~111km, so the offsets are 0.405 and 0.495.
func TestListOpenMeetups_RadiusIs50km(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	viewer := newUserID(t, h)
	host := newUserID(t, h)

	inside := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat+0.405, colomboLng)
	outside := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat+0.495, colomboLng)

	result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentCoffee),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}
	got := map[string]bool{}
	for _, m := range result.Meetups {
		got[m.ID] = true
	}
	if !got[inside.ID] {
		t.Error("a meetup 45km away was not returned; the radius is under 50km")
	}
	if got[outside.ID] {
		t.Error("a meetup 55km away was returned; the radius is over 50km")
	}
}

// TestListOpenMeetups_HostBypassSurvivesPagination guards the specific
// failure the source's own SQL comment warns about: the bypass must be in
// BOTH the first-page and after-cursor queries, or a host's out-of-range
// meetup appears on page 1 and vanishes from page 2 onward.
func TestListOpenMeetups_HostBypassSurvivesPagination(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	viewer := newUserID(t, h)

	// Several of the viewer's own far-away meetups, so they span pages.
	var ownIDs []string
	for i := 0; i < 5; i++ {
		m := h.createMeetup(t, viewer, meetup.IntentCoffee, farAwayLat, farAwayLng)
		ownIDs = append(ownIDs, m.ID)
	}

	seen := map[string]bool{}
	cursor := ""
	for page := 0; page < 10; page++ {
		result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
			UserID: viewer, Intent: intentPtr(meetup.IntentCoffee), Cursor: cursor, PageSize: 2,
			ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
		})
		if err != nil {
			t.Fatalf("ListOpenMeetups(page %d): %v", page, err)
		}
		for _, m := range result.Meetups {
			seen[m.ID] = true
		}
		if result.NextCursor == "" {
			break
		}
		cursor = result.NextCursor
	}

	for _, id := range ownIDs {
		if !seen[id] {
			t.Errorf("own out-of-radius meetup %s never appeared across paginated results — the bypass is missing from the after-cursor query", id)
		}
	}
}

// TestListOpenMeetups_RedactsForUnderTrustViewer covers per-meetup redaction,
// including that coordinates are covered and not just the label.
//
// CHANGED VALUES (ADR-002 §5). This test used to drive a trust level 2 viewer
// against a dating meetup (join bar 4) and assert full redaction INCLUDING
// location. Both halves changed:
//   - the redacted tier is now Level 0 only, so the viewer is a guest;
//   - location is deliberately NO LONGER redacted, so the assertion that it
//     is has been inverted rather than deleted — losing it would leave the
//     "location survives" rule tested only in the unit test.
func TestListOpenMeetups_RedactsForUnderTrustViewer(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	viewer := newUserID(t, h)

	h.createMeetup(t, host, meetup.IntentDating, colomboLat, colomboLng)

	result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentDating),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 0,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}
	if len(result.Meetups) != 1 {
		t.Fatalf("got %d meetups, want 1", len(result.Meetups))
	}

	m := result.Meetups[0]
	if !m.LockedForViewer {
		t.Error("LockedForViewer = false for a guest viewer")
	}
	if m.HostFullName != nil || m.HostProfilePhotoURL != nil {
		t.Error("host display info leaked to a guest")
	}
	if m.WindowStart != nil || m.WindowEnd != nil {
		t.Error("the time window leaked to a guest")
	}
	// INVERTED (ADR-002 §5): these used to have to be nil.
	if m.LocationLat == nil || m.LocationLng == nil || m.LocationLabel == nil {
		t.Error("location was redacted for a guest — ADR-002 §5 keeps it visible")
	}
	// The id stays visible on purpose — the join button needs a target.
	if m.ID == "" {
		t.Error("meetup id was redacted, but it must stay visible")
	}

	// A Level 1 viewer — below the dating join bar of 4 — now sees the full
	// record. Before ADR-002 this required level 4.
	result, err = h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentDating),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 1,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}
	if result.Meetups[0].LockedForViewer || result.Meetups[0].LocationLat == nil {
		t.Error("a Level 1 viewer should see the full record — visibility no longer tracks the join bar")
	}
}

// TestGetMeetup_RedactionAndParticipantException covers the redaction bypass
// GetMeetup closes, plus the participant exception.
//
// CHANGED VALUE (ADR-002 §5): the stranger used to be trust level 2 viewing a
// dating meetup (2 < 4, so redacted). Visibility no longer tracks the intent's
// join bar — a Level 2 viewer now sees every meetup in full — so the stranger
// here is a guest, which is the only tier that is redacted at all now.
func TestGetMeetup_RedactionAndParticipantException(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	stranger := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentDating, colomboLat, colomboLng)

	// A GUEST can't read full data by fetching the id directly off their own
	// locked browse card.
	got, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: m.ID, UserID: stranger, ViewerTrustLevel: 0})
	if err != nil {
		t.Fatalf("GetMeetup: %v", err)
	}
	if !got.LockedForViewer || got.HostFullName != nil || got.WindowStart != nil {
		t.Error("GetMeetup returned unredacted host/time data to a guest — the ListOpenMeetups bypass is open")
	}
	// ...but location and count survive, per ADR-002 §5. Asserted here too,
	// not only in the unit test, because this is the path a real client hits.
	if got.LocationLabel == nil || got.LocationLat == nil {
		t.Error("location was nulled for a guest on GetMeetup — ADR-002 §5 keeps it visible")
	}

	// A LEVEL 2 stranger — below the dating meetup's join bar of 4, and below
	// the host bar too — now sees it in full. This is the behaviour change.
	got, err = h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: m.ID, UserID: stranger, ViewerTrustLevel: 2})
	if err != nil {
		t.Fatalf("GetMeetup(level 2 stranger): %v", err)
	}
	if got.LockedForViewer || got.HostFullName == nil {
		t.Error("a Level 2 viewer was redacted — after ADR-002 §5 visibility is flat Level 0 vs 1+, independent of the join/host bars")
	}

	// The participation exception, unchanged. Driven at trust level 0
	// deliberately: that is the only tier redaction applies to now, so it is
	// the only tier at which this exception is observable at all. The state
	// is unreachable in practice — a guest can never host — but the exception
	// must keep working, because it is what protects a Level 2/3 participant
	// if a bar is ever raised again under an existing meetup (which is
	// exactly what ADR-002 just did to hosting).
	got, err = h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{MeetupID: m.ID, UserID: host, ViewerTrustLevel: 0})
	if err != nil {
		t.Fatalf("GetMeetup(host): %v", err)
	}
	if got.LockedForViewer || got.LocationLat == nil || got.HostFullName == nil {
		t.Error("the host's own meetup was redacted from them — the participation exception is missing")
	}
}

// TestListOpenMeetups_GuestTierRedaction is the browse-screen half of
// ADR-002 §5, asserted end to end against real SQL rather than only on the
// pure function.
func TestListOpenMeetups_GuestTierRedaction(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	seedDisplay(t, h, host, "Real Host Name")

	h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	guestView, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		Intent: intentPtr(meetup.IntentCoffee), UserID: newUserID(t, h),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 0,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(guest): %v", err)
	}
	if len(guestView.Meetups) != 1 {
		t.Fatalf("guest saw %d meetups, want 1 — a guest browses the same set, just with less detail", len(guestView.Meetups))
	}
	g := guestView.Meetups[0]
	if !g.LockedForViewer {
		t.Error("guest card was not marked locked")
	}
	if g.HostFullName != nil || g.HostProfilePhotoURL != nil {
		t.Error("guest saw the host's identity")
	}
	if g.WindowStart != nil || g.WindowEnd != nil {
		t.Error("guest saw the meetup's time window")
	}
	if g.LocationLabel == nil || g.LocationLat == nil || g.LocationLng == nil {
		t.Error("guest lost the location — ADR-002 §5 keeps it visible so a guest can see meetups are happening nearby")
	}
	if g.Capacity == 0 {
		t.Error("guest lost the capacity")
	}

	// A Level 1 viewer — one real signup, nothing else — sees everything.
	memberView, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		Intent: intentPtr(meetup.IntentCoffee), UserID: newUserID(t, h),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 1,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(level 1): %v", err)
	}
	if len(memberView.Meetups) != 1 {
		t.Fatalf("level 1 saw %d meetups, want 1", len(memberView.Meetups))
	}
	member := memberView.Meetups[0]
	if member.LockedForViewer {
		t.Error("a Level 1 viewer's card was marked locked — only guests are redacted now")
	}
	if member.HostFullName == nil || *member.HostFullName != "Real Host Name" {
		t.Errorf("a Level 1 viewer did not get the real host name: %v", member.HostFullName)
	}
	if member.WindowStart == nil {
		t.Error("a Level 1 viewer did not get the time window")
	}
}

// --- requests: authorization, at the repository layer -------------------

// TestRequestAuthzScoping_AtRepositoryLayer is the prompt's
// mismatched-owner requirement, asserted where it actually bites: the SQL.
// Each call uses a WRONG owner id and must affect zero rows, independent of
// any service-layer check.
func TestRequestAuthzScoping_AtRepositoryLayer(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)
	attacker := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// A fresh requester per seeded request: UNIQUE(meetup_id, requester_id,
	// status) allows only one PENDING request per person per meetup, so
	// reusing one requester across subtests would collide.
	_ = requester
	newPendingRequest := func() string {
		t.Helper()
		r, err := h.requests.Create(ctx, m.ID, newUserID(t, h), host, nil)
		if err != nil {
			t.Fatalf("seed request: %v", err)
		}
		return r.ID
	}

	t.Run("accept with a non-host id affects zero rows", func(t *testing.T) {
		id := newPendingRequest()
		_, _, _, err := h.requests.Accept(ctx, id, attacker, nil)
		if err == nil {
			t.Fatal("a non-host accepted someone else's meetup request")
		}
		after, err := h.requests.GetByID(ctx, id)
		if err != nil {
			t.Fatalf("re-read request: %v", err)
		}
		if after.Status != meetuprepo.RequestStatusPending {
			t.Errorf("status = %q, want still pending", after.Status)
		}
	})

	t.Run("reject with a non-host id affects zero rows", func(t *testing.T) {
		id := newPendingRequest()
		if _, err := h.requests.Reject(ctx, id, attacker, nil); err == nil {
			t.Fatal("a non-host rejected someone else's meetup request")
		}
		after, _ := h.requests.GetByID(ctx, id)
		if after.Status != meetuprepo.RequestStatusPending {
			t.Errorf("status = %q, want still pending", after.Status)
		}
	})

	t.Run("withdraw with a non-requester id affects zero rows", func(t *testing.T) {
		id := newPendingRequest()
		if _, err := h.requests.Withdraw(ctx, id, "note", attacker, nil); err == nil {
			t.Fatal("a non-requester withdrew someone else's request")
		}
		after, _ := h.requests.GetByID(ctx, id)
		if after.Status != meetuprepo.RequestStatusPending {
			t.Errorf("status = %q, want still pending", after.Status)
		}
	})

	t.Run("cancel with a non-host id affects zero rows", func(t *testing.T) {
		if _, err := h.meetups.Cancel(ctx, m.ID, "reason", attacker, nil); err == nil {
			t.Fatal("a non-host cancelled someone else's meetup")
		}
		after, _ := h.meetups.GetByID(ctx, m.ID, host)
		if after.Status != meetuprepo.MeetupStatusOpen {
			t.Errorf("status = %q, want still open", after.Status)
		}
	})

	t.Run("close with a non-host id affects zero rows", func(t *testing.T) {
		if _, err := h.meetups.Close(ctx, m.ID, attacker, nil); err == nil {
			t.Fatal("a non-host closed someone else's meetup")
		}
		after, _ := h.meetups.GetByID(ctx, m.ID, host)
		if after.Status != meetuprepo.MeetupStatusOpen {
			t.Errorf("status = %q, want still open", after.Status)
		}
	})
}

// TestRequestAuthzScoping_AtServiceLayer is the same set through the module's
// public interface, checking the error each caller actually receives.
func TestRequestAuthzScoping_AtServiceLayer(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)
	attacker := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: attacker, Accept: true,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("RespondToRequest by a non-host: error = %v, want ErrForbidden", err)
	}

	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID: r.ID, RequesterID: attacker,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("WithdrawRequest by a non-requester: error = %v, want ErrForbidden", err)
	}

	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID: m.ID, HostUserID: attacker, Reason: "not mine",
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("CancelMeetup by a non-host: error = %v, want ErrForbidden", err)
	}

	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
		MeetupID: m.ID, HostUserID: attacker,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("CloseMeetup by a non-host: error = %v, want ErrForbidden", err)
	}

	if _, err := h.svc.ListMeetupRequests(ctx, meetup.ListMeetupRequestsRequest{
		MeetupID: m.ID, HostUserID: attacker,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("ListMeetupRequests by a non-host: error = %v, want ErrForbidden", err)
	}
}

func TestRequestToJoin_Rules(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentDating, colomboLat, colomboLng)

	// Below the intent's trust floor.
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("RequestToJoin below the trust floor: error = %v, want ErrForbidden", err)
	}

	// The host can't join their own meetup.
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: host, RequesterTrustLevel: 4,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("host joining their own meetup: error = %v, want ErrForbidden", err)
	}

	// A legitimate request succeeds, and a second simultaneous one conflicts.
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 4,
	}); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 4,
	}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("second pending request: error = %v, want ErrConflict", err)
	}
}

// TestAcceptRequest_CapacityAutoReject covers the transactional
// accept-then-auto-reject transition.
func TestAcceptRequest_CapacityAutoReject(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	m, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(2 * time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe",
		Capacity: 1, // one seat: the first accept fills it
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}

	first := newUserID(t, h)
	second := newUserID(t, h)
	r1, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: first, RequesterTrustLevel: 2})
	r2, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: second, RequesterTrustLevel: 2})

	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r1.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// The other pending request is auto-rejected, and marked as such so the
	// frontend can show different copy from a host's explicit rejection.
	after, err := h.requests.GetByID(ctx, r2.ID)
	if err != nil {
		t.Fatalf("re-read second request: %v", err)
	}
	if after.Status != meetuprepo.RequestStatusRejected || !after.AutoRejected {
		t.Errorf("second request = (%q, auto_rejected=%v), want (rejected, true)", after.Status, after.AutoRejected)
	}

	// The meetup is now full.
	full, _ := h.meetups.GetByID(ctx, m.ID, host)
	if full.Status != meetuprepo.MeetupStatusFull {
		t.Errorf("meetup status = %q, want full", full.Status)
	}

	// The accepted requester got their own Safety Gate row.
	if _, err := h.safetyState.Get(ctx, m.ID, first); err != nil {
		t.Errorf("no safety_state row for the accepted requester: %v", err)
	}
}

// --- Safety Gate: the authorization guard on all five methods ----------

// TestSafetyGate_RejectsNonParticipantOnEveryMethod is the prompt's explicit
// requirement: a non-participant must be rejected on ALL FIVE methods, not
// just some. Each is a separate subtest so a partial regression is visible.
func TestSafetyGate_RejectsNonParticipantOnEveryMethod(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	outsider := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// Sanity: the outsider is a real authenticated user with no relationship
	// to this meetup — exactly the caller the guard exists to stop.
	cases := []struct {
		name string
		call func() error
	}{
		{"GetSafetyState", func() error {
			_, err := h.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: outsider})
			return err
		}},
		{"AcknowledgeSafetyChecklist", func() error {
			_, err := h.svc.AcknowledgeSafetyChecklist(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: outsider})
			return err
		}},
		{"SetLiveLocationOptIn", func() error {
			_, err := h.svc.SetLiveLocationOptIn(ctx, meetup.SetLiveLocationOptInRequest{MeetupID: m.ID, UserID: outsider, OptIn: true})
			return err
		}},
		{"CheckIn", func() error {
			_, err := h.svc.CheckIn(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: outsider})
			return err
		}},
		{"DeclineCheckIn", func() error {
			_, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{MeetupID: m.ID, UserID: outsider, Reason: "nope"})
			return err
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.call()
			if err == nil {
				t.Fatal("a non-participant was allowed to act on this meetup's safety state")
			}
			if !isSentinel(err, apperror.ErrForbidden) {
				t.Errorf("error = %v, want ErrForbidden", err)
			}
		})
	}

	// And nothing was written: the outsider must not have created a row for
	// themselves as a side effect of trying.
	var rows int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM meetup.safety_state WHERE meetup_id = $1 AND user_id = $2`, m.ID, outsider).Scan(&rows); err != nil {
		t.Fatalf("count safety rows: %v", err)
	}
	if rows != 0 {
		t.Errorf("a non-participant's failed calls created %d safety_state row(s), want 0", rows)
	}
}

// TestSafetyGate_PerParticipantRowsAreIndependent is the schema half: each
// participant has their own row, so one person's check-in can't overwrite
// another's state.
func TestSafetyGate_PerParticipantRowsAreIndependent(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// The host acknowledges and checks in; the requester does neither.
	if _, err := h.svc.AcknowledgeSafetyChecklist(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host}); err != nil {
		t.Fatalf("host acknowledge: %v", err)
	}
	if _, err := h.svc.CheckIn(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host}); err != nil {
		t.Fatalf("host check-in: %v", err)
	}

	requesterState, err := h.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: requester})
	if err != nil {
		t.Fatalf("requester GetSafetyState: %v", err)
	}
	if requesterState.CheckedInAt != nil || requesterState.ChecklistAckAt != nil {
		t.Error("the host's check-in leaked into the requester's row — state must be per-participant")
	}

	hostState, err := h.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host})
	if err != nil {
		t.Fatalf("host GetSafetyState: %v", err)
	}
	if hostState.CheckedInAt == nil {
		t.Error("the host's own check-in was not recorded")
	}
}

// TestSafetyGate_StepOrderAndTerminalStates covers the server-side rules a
// modified client must not be able to bypass.
func TestSafetyGate_StepOrderAndTerminalStates(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// Check-in before acknowledging the checklist is rejected.
	if _, err := h.svc.CheckIn(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("check-in before checklist ack: error = %v, want ErrConflict", err)
	}

	if _, err := h.svc.AcknowledgeSafetyChecklist(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host}); err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	if _, err := h.svc.CheckIn(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host}); err != nil {
		t.Fatalf("check-in: %v", err)
	}

	// Declining after checking in is rejected — mutually exclusive terminal
	// states.
	if _, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: m.ID, UserID: host, Reason: "changed my mind",
	}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("decline after check-in: error = %v, want ErrConflict", err)
	}

	// An empty reason is rejected; an oversized one too.
	other := newUserID(t, h)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: other, RequesterTrustLevel: 2})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	if _, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: m.ID, UserID: other, Reason: "   ",
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("decline with a blank reason: error = %v, want ErrInvalidInput", err)
	}
	if _, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: m.ID, UserID: other, Reason: strings.Repeat("a", 501),
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("decline with an oversized reason: error = %v, want ErrInvalidInput", err)
	}

	// A real decline sticks, and blocks a later check-in.
	if _, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: m.ID, UserID: other, Reason: "feeling unwell",
	}); err != nil {
		t.Fatalf("decline: %v", err)
	}
	if _, err := h.svc.AcknowledgeSafetyChecklist(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: other}); err != nil {
		t.Fatalf("acknowledge after decline: %v", err)
	}
	if _, err := h.svc.CheckIn(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: other}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("check-in after declining: error = %v, want ErrConflict", err)
	}
}

// backdateMeetup moves a meetup's window into the past. CreateMeetup rejects
// a past window_start, so anything testing post-meetup behaviour creates a
// valid future meetup and then backdates it in SQL — the approach this
// package's lifecycle tests already use.
func backdateMeetup(t *testing.T, h *harness, meetupID string) {
	t.Helper()
	if _, err := h.pool.Exec(context.Background(), `
		UPDATE meetup.meetups
		SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
		WHERE id = $1`, meetupID); err != nil {
		t.Fatalf("backdate meetup window: %v", err)
	}
}

// --- ratings -----------------------------------------------------------

// TestListRatableParticipants_RejectsNonParticipant covers the IDOR the
// source's own review caught: without the viewer-participation check, any
// authenticated user could enumerate a meetup's participants by guessing an
// id.
func TestListRatableParticipants_RejectsNonParticipant(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)
	outsider := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	// Give both a display-cache row so a leak would actually carry names.
	seedDisplay := func(id, name string) {
		if _, err := h.userDisplayCache.Upsert(ctx, id, name, "https://example.com/p.jpg", 3, time.Now()); err != nil {
			t.Fatalf("seed display cache: %v", err)
		}
	}
	seedDisplay(host, "Host Person")
	seedDisplay(requester, "Requester Person")

	// An outsider gets an empty list, never the participant roster.
	got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: outsider})
	if err != nil {
		t.Fatalf("ListRatableParticipants(outsider): %v", err)
	}
	if len(got) != 0 {
		t.Errorf("an outsider saw %d participant(s), want 0 — this is the participant-enumeration IDOR", len(got))
	}

	// Even the HOST sees nobody yet. The meetup is still open and scheduled
	// for later, so there is no eligibility branch under which the host
	// could rate this requester — and this endpoint must agree with
	// SubmitRating, which would reject the score. It previously returned
	// the requester here, which the client renders as a live star picker:
	// a host looking at a meetup days away was invited to rate someone they
	// had not met, and the tap failed after the irreversible-rating
	// confirmation.
	got, err = h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: host})
	if err != nil {
		t.Fatalf("ListRatableParticipants(host, before it happened): %v", err)
	}
	if len(got) != 0 {
		t.Errorf("host saw %+v before the meetup happened, want none", got)
	}

	// Once the host confirms it happened, the requester is ratable —
	// excluding the viewer themselves.
	backdateMeetup(t, h, m.ID)
	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: host, Happened: true,
	}); err != nil {
		t.Fatalf("SubmitMeetupFeedback: %v", err)
	}
	got, err = h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: host})
	if err != nil {
		t.Fatalf("ListRatableParticipants(host): %v", err)
	}
	if len(got) != 1 || got[0].UserID != requester {
		t.Errorf("host saw %+v, want exactly the requester", got)
	}

	// The outsider check again, now that a real eligibility branch is open:
	// the IDOR guard must not depend on the list happening to be empty.
	got, err = h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: outsider})
	if err != nil {
		t.Fatalf("ListRatableParticipants(outsider, post-feedback): %v", err)
	}
	if len(got) != 0 {
		t.Errorf("an outsider saw %d participant(s), want 0", len(got))
	}
}

// A row with Happened=true is what unlocks rating everyone on a meetup
// (SubmitRating's first eligibility branch), so this write is the one that
// has to be guarded, not just the rating itself.
func TestSubmitMeetupFeedback_RequiresAStartedMeetupAndAParticipant(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)
	outsider := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// createMeetup schedules into the future, so this is a meetup that has
	// not started. "How did it go?" has no honest answer yet.
	err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: host, Happened: true,
	})
	if !errors.Is(err, apperror.ErrConflict) {
		t.Errorf("feedback on a future meetup: error = %v, want ErrConflict", err)
	}

	// And it left nothing behind that would unlock rating.
	got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: host})
	if err != nil {
		t.Fatalf("ListRatableParticipants: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("host saw %+v after a rejected feedback write, want none", got)
	}

	backdateMeetup(t, h, m.ID)

	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: outsider, Happened: true,
	}); !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("feedback from a non-participant: error = %v, want ErrForbidden", err)
	}

	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: host, Happened: true,
	}); err != nil {
		t.Errorf("feedback from the host on a started meetup: %v", err)
	}
}

// The two branches that have nothing to do with the meetup happening —
// both must survive the eligibility filter, since neither is covered by
// HasConfirmedHappened.
func TestListRatableParticipants_EligibilityBranches(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	t.Run("a cancelled meetup's host stays ratable by an accepted requester", func(t *testing.T) {
		host := newUserID(t, h)
		requester := newUserID(t, h)
		m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
		r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
			t.Fatalf("accept: %v", err)
		}
		if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{MeetupID: m.ID, HostUserID: host, Reason: "something came up"}); err != nil {
			t.Fatalf("CancelMeetup: %v", err)
		}

		got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: requester})
		if err != nil {
			t.Fatalf("ListRatableParticipants: %v", err)
		}
		if len(got) != 1 || got[0].UserID != host {
			t.Errorf("accepted requester saw %+v, want the cancelled meetup's host", got)
		}
	})

	t.Run("a withdrawn requester stays ratable by the host", func(t *testing.T) {
		host := newUserID(t, h)
		requester := newUserID(t, h)
		m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
		r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
		if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
			t.Fatalf("accept: %v", err)
		}
		if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{RequestID: r.ID, RequesterID: requester, Note: "sorry"}); err != nil {
			t.Fatalf("WithdrawRequest: %v", err)
		}

		got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{MeetupID: m.ID, ViewerID: host})
		if err != nil {
			t.Fatalf("ListRatableParticipants: %v", err)
		}
		if len(got) != 1 || got[0].UserID != requester {
			t.Errorf("host saw %+v, want the withdrawn requester", got)
		}
	})
}

// TestSubmitRating_EligibilityAndCachePublish covers the rating rules and the
// rating-updated event reaching the auth module's cache.
func TestSubmitRating_EligibilityAndCachePublish(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{MeetupID: m.ID, RequesterID: requester, RequesterTrustLevel: 2})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{RequestID: r.ID, HostUserID: host, Accept: true}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// Not yet eligible — nobody has confirmed the meetup happened.
	if err := h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: m.ID, RaterUserID: host, RatedUserID: requester, Score: 5,
	}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("rating before confirming attendance: error = %v, want ErrForbidden", err)
	}

	// Score bounds and self-rating are rejected outright.
	if err := h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: m.ID, RaterUserID: host, RatedUserID: requester, Score: 6,
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("score 6: error = %v, want ErrInvalidInput", err)
	}
	if err := h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: m.ID, RaterUserID: host, RatedUserID: host, Score: 5,
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("self-rating: error = %v, want ErrInvalidInput", err)
	}

	// Confirm attendance, then rate.
	backdateMeetup(t, h, m.ID)
	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: host, Happened: true,
	}); err != nil {
		t.Fatalf("SubmitMeetupFeedback: %v", err)
	}
	if err := h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: m.ID, RaterUserID: host, RatedUserID: requester, Score: 4,
	}); err != nil {
		t.Fatalf("SubmitRating: %v", err)
	}

	// Duplicate submission for the same pair conflicts.
	if err := h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: m.ID, RaterUserID: host, RatedUserID: requester, Score: 5,
	}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("duplicate rating: error = %v, want ErrConflict", err)
	}

	// rating-updated carries the recomputed aggregate for the RATED user.
	payloads := h.bus.payloadsOf(eventbus.TopicRatingUpdated)
	if len(payloads) != 1 {
		t.Fatalf("rating-updated published %d times, want 1", len(payloads))
	}
	payload, ok := payloads[0].(eventbus.RatingUpdatedPayload)
	if !ok {
		t.Fatalf("payload type = %T, want RatingUpdatedPayload", payloads[0])
	}
	if payload.UserID != requester || payload.RatingCount != 1 || payload.RatingAverage != 4 {
		t.Errorf("payload = %+v, want the requester with count 1 and average 4", payload)
	}
}

// --- lifecycle ---------------------------------------------------------

func TestCloseMeetup_HostOnlyAndWindowStarted(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	// A meetup whose window hasn't started yet can't be closed.
	future := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{MeetupID: future.ID, HostUserID: host}); !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("closing before the window starts: error = %v, want ErrForbidden", err)
	}

	// One whose window has started can.
	started, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(-time.Minute), WindowEnd: time.Now().Add(time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	closed, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{MeetupID: started.ID, HostUserID: host})
	if err != nil {
		t.Fatalf("CloseMeetup: %v", err)
	}
	if closed.Status != meetup.StatusCompleted || closed.ClosedAt == nil {
		t.Errorf("closed meetup = (%q, closed_at=%v), want completed with a timestamp", closed.Status, closed.ClosedAt)
	}

	// Closing twice conflicts.
	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{MeetupID: started.ID, HostUserID: host}); !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("second close: error = %v, want ErrConflict", err)
	}
}

func TestCancelMeetup_RequiresReason(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{MeetupID: m.ID, HostUserID: host, Reason: "  "}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("cancel with a blank reason: error = %v, want ErrInvalidInput", err)
	}
	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID: m.ID, HostUserID: host, Reason: strings.Repeat("a", 501),
	}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("cancel with an oversized reason: error = %v, want ErrInvalidInput", err)
	}

	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID: m.ID, HostUserID: host, Reason: "venue closed",
	}); err != nil {
		t.Fatalf("CancelMeetup: %v", err)
	}
	after, _ := h.meetups.GetByID(ctx, m.ID, host)
	if after.Status != meetuprepo.MeetupStatusCancelled || after.CancellationReason == nil || *after.CancellationReason != "venue closed" {
		t.Errorf("cancelled meetup = (%q, reason=%v), want cancelled with the reason stored", after.Status, after.CancellationReason)
	}
}

// TestAutoCloseSweep closes meetups whose window has ended, and is a no-op
// for one still in progress.
func TestAutoCloseSweep(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	// Created with a valid future window, then backdated directly: CreateMeetup
	// deliberately refuses a window_start in the past (beyond its short grace
	// period), which is the rule under test elsewhere — so an already-ended
	// meetup can only be set up by writing the row.
	ended := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
		ended.ID); err != nil {
		t.Fatalf("backdate ended meetup: %v", err)
	}
	ongoing, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(-time.Minute), // inside the grace period
		WindowEnd:   time.Now().Add(time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
	})
	if err != nil {
		t.Fatalf("CreateMeetup (ongoing): %v", err)
	}

	closed, err := h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("AutoCloseSweep: %v", err)
	}
	if closed != 1 {
		t.Errorf("closed %d meetups, want 1", closed)
	}

	endedAfter, _ := h.meetups.GetByID(ctx, ended.ID, host)
	if endedAfter.Status != meetuprepo.MeetupStatusCompleted {
		t.Errorf("ended meetup status = %q, want completed", endedAfter.Status)
	}
	ongoingAfter, _ := h.meetups.GetByID(ctx, ongoing.ID, host)
	if ongoingAfter.Status != meetuprepo.MeetupStatusOpen {
		t.Errorf("in-progress meetup status = %q, want still open", ongoingAfter.Status)
	}

	// Running again is a clean no-op — the WHERE clause is the race guard.
	closed, err = h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("second AutoCloseSweep: %v", err)
	}
	if closed != 0 {
		t.Errorf("second sweep closed %d, want 0", closed)
	}
}

// TestNotifyStartingSoonSweep marks each meetup once, so a later tick can't
// re-notify.
func TestNotifyStartingSoonSweep(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	if _, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(10 * time.Minute), WindowEnd: time.Now().Add(time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
	}); err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}

	notified, err := h.svc.NotifyStartingSoonSweep(ctx)
	if err != nil {
		t.Fatalf("NotifyStartingSoonSweep: %v", err)
	}
	if notified != 1 {
		t.Errorf("notified %d, want 1", notified)
	}

	notified, err = h.svc.NotifyStartingSoonSweep(ctx)
	if err != nil {
		t.Fatalf("second NotifyStartingSoonSweep: %v", err)
	}
	if notified != 0 {
		t.Errorf("second sweep notified %d, want 0 — the de-dup guard didn't hold", notified)
	}
}

// --- caches and the nearby-notify fan-out ------------------------------

// TestNearbyNotify_ExcludesHostAndFarAwayAndStale drives the meetup-created
// consumer directly, which is what cmd/monolith subscribes.
func TestNearbyNotify_ExcludesHostAndFarAwayAndStale(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	nearbyUser := newUserID(t, h)
	farUser := newUserID(t, h)
	staleUser := newUserID(t, h)

	// Everyone needs a device token, or they're skipped as unreachable.
	for _, u := range []string{host, nearbyUser, farUser, staleUser} {
		if err := h.deviceTokens.Upsert(ctx, u, "token-"+u); err != nil {
			t.Fatalf("register device token: %v", err)
		}
	}

	now := time.Now()
	mustUpsert := func(user string, lat, lng float64, at time.Time) {
		t.Helper()
		if _, err := h.userLocationCache.Upsert(ctx, user, lat, lng, at); err != nil {
			t.Fatalf("seed location cache: %v", err)
		}
	}
	mustUpsert(host, colomboLat, colomboLng, now)
	mustUpsert(nearbyUser, colomboLat, colomboLng, now)
	mustUpsert(farUser, farAwayLat, farAwayLng, now)
	mustUpsert(staleUser, colomboLat, colomboLng, now.Add(-48*time.Hour)) // older than the 24h cutoff

	// Counts outbox rows now, not bus events: push-notification-requested is
	// no longer a bus topic at all (§F). The recipient-selection logic being
	// asserted here is unchanged.
	before := h.countOutboxRows(t)
	if err := h.svc.HandleMeetupCreated(ctx, meetup.NearbyNotifyPayload{
		MeetupID: "meetup-1", HostUserID: host, Intent: "coffee",
		LocationLat: colomboLat, LocationLng: colomboLng,
	}); err != nil {
		t.Fatalf("HandleMeetupCreated: %v", err)
	}

	// Exactly one recipient: the nearby, non-stale, non-host user.
	if got := h.countOutboxRows(t) - before; got != 1 {
		t.Errorf("queued %d push notifications, want exactly 1 (host excluded, far user excluded, stale row excluded)", got)
	}
}

// countOutboxRows counts queued notifications. Used by the tests that assert
// on WHO gets notified — the delivery side is covered separately in
// outbox_integration_test.go.
func (h *harness) countOutboxRows(t *testing.T) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM meetup.notification_outbox`).Scan(&n); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	return n
}

// outboxTitles returns every queued notification's title, in insertion
// order — the assertion surface for "did this action notify the right people
// with the right copy".
func (h *harness) outboxTitles(t *testing.T) []string {
	t.Helper()
	rows, err := h.pool.Query(context.Background(),
		`SELECT title FROM meetup.notification_outbox ORDER BY created_at, id`)
	if err != nil {
		t.Fatalf("list outbox titles: %v", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var title string
		if err := rows.Scan(&title); err != nil {
			t.Fatalf("scan title: %v", err)
		}
		out = append(out, title)
	}
	return out
}

// TestUserDisplayCache_OrderingGuard covers the idempotent,
// timestamp-guarded upsert every cache in this module uses.
func TestUserDisplayCache_OrderingGuard(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	user := newUserID(t, h)

	now := time.Now()
	applied, err := h.userDisplayCache.Upsert(ctx, user, "Newer Name", "", 3, now)
	if err != nil || !applied {
		t.Fatalf("first upsert: applied=%v err=%v", applied, err)
	}

	// A stale redelivery must not regress the newer value.
	applied, err = h.userDisplayCache.Upsert(ctx, user, "Older Name", "", 1, now.Add(-time.Hour))
	if err != nil {
		t.Fatalf("stale upsert: %v", err)
	}
	if applied {
		t.Error("a stale event was applied — the ordering guard didn't hold")
	}

	var name string
	if err := h.pool.QueryRow(ctx, `SELECT full_name FROM meetup.user_display_cache WHERE user_id = $1`, user).Scan(&name); err != nil {
		t.Fatalf("read cache: %v", err)
	}
	if name != "Newer Name" {
		t.Errorf("cached name = %q, want the newer value to have survived", name)
	}

	// A genuinely newer event does apply.
	applied, err = h.userDisplayCache.Upsert(ctx, user, "Newest Name", "", 4, now.Add(time.Hour))
	if err != nil || !applied {
		t.Fatalf("newer upsert: applied=%v err=%v", applied, err)
	}
}

// TestListMyMeetups_And_ListActiveMeetups covers the two no-distance-filter
// reads, including the accepted-requests-only rule for the active dashboard.
func TestListMyMeetups_And_ListActiveMeetups(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	requester := newUserID(t, h)

	// Far away from everyone — these two reads have no distance filter at all.
	hosted := h.createMeetup(t, host, meetup.IntentCoffee, farAwayLat, farAwayLng)
	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: hosted.ID, RequesterID: requester, RequesterTrustLevel: 2,
	})

	mine, err := h.svc.ListMyMeetups(ctx, meetup.ListMyMeetupsRequest{UserID: host})
	if err != nil {
		t.Fatalf("ListMyMeetups(host): %v", err)
	}
	if len(mine.Hosted) != 1 || mine.Hosted[0].ID != hosted.ID {
		t.Errorf("hosted = %+v, want the one meetup", mine.Hosted)
	}

	mine, err = h.svc.ListMyMeetups(ctx, meetup.ListMyMeetupsRequest{UserID: requester})
	if err != nil {
		t.Fatalf("ListMyMeetups(requester): %v", err)
	}
	if len(mine.Requested) != 1 {
		t.Fatalf("requested = %+v, want one", mine.Requested)
	}
	if mine.Requested[0].MyRequestStatus == nil || *mine.Requested[0].MyRequestStatus != meetup.RequestStatusPending {
		t.Errorf("MyRequestStatus = %v, want pending", mine.Requested[0].MyRequestStatus)
	}

	// A merely-pending request does NOT put the meetup on the requester's
	// active dashboard.
	active, err := h.svc.ListActiveMeetups(ctx, requester)
	if err != nil {
		t.Fatalf("ListActiveMeetups(requester, pending): %v", err)
	}
	if len(active) != 0 {
		t.Errorf("a pending request put the meetup on the active dashboard: %+v", active)
	}

	// Once accepted, it does.
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	active, err = h.svc.ListActiveMeetups(ctx, requester)
	if err != nil {
		t.Fatalf("ListActiveMeetups(requester, accepted): %v", err)
	}
	if len(active) != 1 || active[0].ID != hosted.ID {
		t.Errorf("active = %+v, want the accepted meetup", active)
	}

	// The host sees it as active too.
	active, err = h.svc.ListActiveMeetups(ctx, host)
	if err != nil {
		t.Fatalf("ListActiveMeetups(host): %v", err)
	}
	if len(active) != 1 {
		t.Errorf("host's active list = %+v, want one", active)
	}
}

func TestRegisterDeviceToken_UpsertsByToken(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	first := newUserID(t, h)
	second := newUserID(t, h)

	if err := h.svc.RegisterDeviceToken(ctx, meetup.RegisterDeviceTokenRequest{UserID: first, FCMToken: "shared-device"}); err != nil {
		t.Fatalf("register (first): %v", err)
	}
	// The same physical device, now signed in as someone else — ownership
	// moves rather than leaving a stale row pointing at the old account.
	if err := h.svc.RegisterDeviceToken(ctx, meetup.RegisterDeviceTokenRequest{UserID: second, FCMToken: "shared-device"}); err != nil {
		t.Fatalf("register (second): %v", err)
	}

	firstTokens, _ := h.deviceTokens.ListForUser(ctx, first)
	secondTokens, _ := h.deviceTokens.ListForUser(ctx, second)
	if len(firstTokens) != 0 {
		t.Errorf("first user still owns %d token(s), want 0", len(firstTokens))
	}
	if len(secondTokens) != 1 {
		t.Errorf("second user owns %d token(s), want 1", len(secondTokens))
	}

	if err := h.svc.RegisterDeviceToken(ctx, meetup.RegisterDeviceTokenRequest{UserID: first, FCMToken: ""}); !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("empty token: error = %v, want ErrInvalidInput", err)
	}
}

// TestNoCrossSchemaForeignKeys is the ADR-001 §3 guard, asserted against the
// live catalog rather than by reading the migration: no constraint in the
// meetup schema may reference anything in auth (or vice versa).
func TestNoCrossSchemaForeignKeys(t *testing.T) {
	h := newHarness(t)

	rows, err := h.pool.Query(context.Background(), `
		SELECT con.conname, src.nspname, tgt.nspname
		FROM pg_constraint con
		JOIN pg_class srccls ON srccls.oid = con.conrelid
		JOIN pg_namespace src ON src.oid = srccls.relnamespace
		JOIN pg_class tgtcls ON tgtcls.oid = con.confrelid
		JOIN pg_namespace tgt ON tgt.oid = tgtcls.relnamespace
		WHERE con.contype = 'f' AND src.nspname <> tgt.nspname`)
	if err != nil {
		t.Fatalf("query constraints: %v", err)
	}
	defer rows.Close()

	for rows.Next() {
		var name, srcSchema, tgtSchema string
		if err := rows.Scan(&name, &srcSchema, &tgtSchema); err != nil {
			t.Fatalf("scan: %v", err)
		}
		t.Errorf("cross-schema foreign key %q from %s to %s — ADR-001 §3 forbids these, they are what makes a module unextractable",
			name, srcSchema, tgtSchema)
	}
}

// TestSafetyStateIsPerParticipantInTheSchema pins the primary key itself, so
// a future migration can't quietly regress to one shared row per meetup.
func TestSafetyStateIsPerParticipantInTheSchema(t *testing.T) {
	h := newHarness(t)

	var cols []string
	rows, err := h.pool.Query(context.Background(), `
		SELECT a.attname
		FROM pg_index i
		JOIN pg_class c ON c.oid = i.indrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
		WHERE i.indisprimary AND n.nspname = 'meetup' AND c.relname = 'safety_state'
		ORDER BY a.attname`)
	if err != nil {
		t.Fatalf("query primary key: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var col string
		if err := rows.Scan(&col); err != nil {
			t.Fatalf("scan: %v", err)
		}
		cols = append(cols, col)
	}

	if fmt.Sprint(cols) != "[meetup_id user_id]" {
		t.Errorf("safety_state primary key = %v, want [meetup_id user_id] — a meetup-only key is the shared-row bug", cols)
	}
}

// intentPtr is the §B ergonomics tax: ListOpenMeetupsRequest.Intent became a
// pointer so nil can mean "every intent", and Go has no way to take the
// address of a constant inline.
func intentPtr(i meetup.Intent) *meetup.Intent { return &i }

// --- §B: the two new optional ListOpenMeetups filters ----------------------
//
// These run against real SQL because the filters ARE SQL — a fake repository
// would only re-assert the predicate I just wrote.

// TestListOpenMeetups_NilIntentReturnsEveryIntent is the "All" case. Before
// §B, intent was required and there was no way to ask this question.
func TestListOpenMeetups_NilIntentReturnsEveryIntent_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	viewer := newUserID(t, h)
	seedDisplay(t, h, host, "Host")

	h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	h.createMeetup(t, host, meetup.IntentLunch, colomboLat, colomboLng)
	h.createMeetup(t, host, meetup.IntentNetworking, colomboLat, colomboLng)

	all, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: nil,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(nil intent): %v", err)
	}
	if len(all.Meetups) != 3 {
		t.Fatalf("nil intent returned %d meetups, want all 3", len(all.Meetups))
	}
	seen := map[meetup.Intent]bool{}
	for _, m := range all.Meetups {
		seen[m.Intent] = true
	}
	for _, want := range []meetup.Intent{meetup.IntentCoffee, meetup.IntentLunch, meetup.IntentNetworking} {
		if !seen[want] {
			t.Errorf("intent %s missing from the nil-intent result", want)
		}
	}

	// A named intent still narrows exactly as before — the point of the
	// change is that nil is NEW behaviour, not that the old behaviour moved.
	coffee, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentCoffee),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(coffee): %v", err)
	}
	if len(coffee.Meetups) != 1 || coffee.Meetups[0].Intent != meetup.IntentCoffee {
		t.Errorf("a named intent no longer filters: got %d meetups", len(coffee.Meetups))
	}
}

// TestListOpenMeetups_WithinDaysBoundsTheWindow covers the filter that makes
// "Happening Soon" possible. The boundary matters: a meetup exactly inside
// the window must be included, one outside excluded.
func TestListOpenMeetups_WithinDaysBoundsTheWindow_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	viewer := newUserID(t, h)
	seedDisplay(t, h, host, "Host")

	soon := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	later := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// createMeetup schedules an hour out; push one of them well past a week.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() + interval '30 days', window_end = now() + interval '30 days 2 hours'
		WHERE id = $1`, later.ID); err != nil {
		t.Fatalf("push the second meetup out: %v", err)
	}

	within, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentCoffee), WithinDays: 7,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(within 7): %v", err)
	}
	if len(within.Meetups) != 1 {
		t.Fatalf("within_days=7 returned %d meetups, want 1", len(within.Meetups))
	}
	if within.Meetups[0].ID != soon.ID {
		t.Errorf("within_days returned the wrong meetup — got %s, want the one starting in an hour", within.Meetups[0].ID)
	}

	// 0 means unrestricted, which is what every pre-§B caller passes
	// implicitly. Both come back.
	unrestricted, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: intentPtr(meetup.IntentCoffee), WithinDays: 0,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(within 0): %v", err)
	}
	if len(unrestricted.Meetups) != 2 {
		t.Errorf("within_days=0 returned %d meetups, want 2 — 0 must mean no restriction, exactly as before §B", len(unrestricted.Meetups))
	}
}

// TestListOpenMeetups_CombinedFilters covers the two together, which is how
// the home screen actually calls it ("All" + next 7 days).
func TestListOpenMeetups_CombinedFilters_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	viewer := newUserID(t, h)
	seedDisplay(t, h, host, "Host")

	h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	h.createMeetup(t, host, meetup.IntentLunch, colomboLat, colomboLng)
	far := h.createMeetup(t, host, meetup.IntentNetworking, colomboLat, colomboLng)
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups SET window_start = now() + interval '30 days',
		    window_end = now() + interval '30 days 2 hours' WHERE id = $1`, far.ID); err != nil {
		t.Fatalf("push out: %v", err)
	}

	result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: viewer, Intent: nil, WithinDays: 7,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}
	if len(result.Meetups) != 2 {
		t.Errorf("got %d meetups, want 2 (both intents, both inside the window)", len(result.Meetups))
	}
	for _, m := range result.Meetups {
		if m.ID == far.ID {
			t.Error("the out-of-window meetup came back despite within_days=7")
		}
	}
}

// TestListOpenMeetups_FiltersDoNotAffectRedactionOrRoleFields is the
// regression check §D asks for: the filter changes WHICH rows are returned
// and nothing else. Redaction and the IsHostedByMe/MyRequestStatus
// annotations must behave identically with the filters applied.
func TestListOpenMeetups_FiltersDoNotAffectRedactionOrRoleFields_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	seedDisplay(t, h, host, "Real Host Name")
	h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// Redaction: a guest is still redacted, with location still visible,
	// through the new filtered path.
	guest, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: newUserID(t, h), Intent: nil, WithinDays: 7,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 0,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(guest): %v", err)
	}
	if len(guest.Meetups) != 1 {
		t.Fatalf("guest saw %d meetups, want 1", len(guest.Meetups))
	}
	g := guest.Meetups[0]
	if !g.LockedForViewer || g.HostFullName != nil || g.WindowStart != nil {
		t.Error("guest-tier redaction did not apply through the filtered path (ADR-002 §5)")
	}
	if g.LocationLabel == nil {
		t.Error("location was redacted for a guest through the filtered path")
	}

	// Role fields: the host still sees their own meetup annotated, and the
	// 50km-exemption for one's own hosted meetups still applies.
	hostView, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: host, Intent: nil, WithinDays: 7,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(host): %v", err)
	}
	if len(hostView.Meetups) != 1 || !hostView.Meetups[0].IsHostedByMe {
		t.Error("IsHostedByMe was not set through the filtered path — the Happening Soon badges depend on it")
	}

	// The other role field: a requester still sees their own pending status
	// annotated on the browse row. Same badge block on the card reads both,
	// so testing only IsHostedByMe would leave half of it unguarded.
	requester := newUserID(t, h)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: hostView.Meetups[0].ID, RequesterID: requester, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	requesterView, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: requester, Intent: intentPtr(meetup.IntentCoffee), WithinDays: 7,
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups(requester): %v", err)
	}
	if len(requesterView.Meetups) != 1 {
		t.Fatalf("requester saw %d meetups, want 1", len(requesterView.Meetups))
	}
	if got := requesterView.Meetups[0].MyRequestStatus; got == nil || *got != meetup.RequestStatusPending {
		t.Errorf("MyRequestStatus through the filtered path = %v, want pending", got)
	}
	if requesterView.Meetups[0].IsHostedByMe {
		t.Error("IsHostedByMe was set for a non-host through the filtered path")
	}
}

// TestListOpenMeetups_RejectsAnOutOfRangeWithinDays pins the input
// validation: within_days reaches SQL, so a nonsense value is rejected with
// ErrInvalidInput rather than handed to Postgres.
func TestListOpenMeetups_RejectsAnOutOfRangeWithinDays_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	for _, days := range []int32{-1, 100_000} {
		_, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
			UserID: newUserID(t, h), Intent: nil, WithinDays: days,
			ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
		})
		if err == nil {
			t.Errorf("within_days=%d was accepted", days)
			continue
		}
		if !isSentinel(err, apperror.ErrInvalidInput) {
			t.Errorf("within_days=%d error = %v, want ErrInvalidInput", days, err)
		}
	}
}

// TestCloseMeetup_PublishesMeetupsCompletedForEveryParticipant covers the
// profile "MEETUPS" figure end to end on the publishing side: completing a
// meetup must tell the auth module the NEW total for the host and for every
// accepted requester, and must leave everyone else alone.
//
// This exists because the figure was a hardcoded literal 12 on the client
// before this slice — a brand-new account was shown a dozen completed
// meetups. The regression this guards is that being silently true again.
//
// CHANGED BY PLAN 06 (async recompute): the events no longer arrive from
// CloseMeetup itself. The close writes a meetups_completed_outbox row and
// the poller publishes afterwards, so this test drains the outbox before
// asserting. WHAT is published is unchanged, which is the point — the
// assertions below are the same ones that passed against the synchronous
// path.
func TestCloseMeetup_PublishesMeetupsCompletedForEveryParticipant(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	accepted := newUserID(t, h)
	rejected := newUserID(t, h)

	started, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(-time.Minute), WindowEnd: time.Now().Add(time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 4,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}

	acceptedReq, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: started.ID, RequesterID: accepted, RequesterTrustLevel: 2,
	})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: acceptedReq.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// A requester the host turned down. They were never a participant, so
	// their total must not move — the count is "meetups completed", not
	// "meetups applied to".
	rejectedReq, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: started.ID, RequesterID: rejected, RequesterTrustLevel: 2,
	})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: rejectedReq.ID, HostUserID: host, Accept: false,
	}); err != nil {
		t.Fatalf("reject: %v", err)
	}

	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
		MeetupID: started.ID, HostUserID: host,
	}); err != nil {
		t.Fatalf("CloseMeetup: %v", err)
	}

	// Nothing is published by the close itself any more — only scheduled.
	if got := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated); len(got) != 0 {
		t.Errorf("close published %d events synchronously, want 0 — the recompute is the poller's job now", len(got))
	}
	h.drainCompletedOutbox(t, ctx)

	counts := map[string]int{}
	for _, p := range h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated) {
		payload, ok := p.(eventbus.MeetupsCompletedUpdatedPayload)
		if !ok {
			t.Fatalf("unexpected payload type %T", p)
		}
		if payload.OccurredAt.IsZero() {
			t.Error("payload has no OccurredAt — the auth-side ordering guard depends on it")
		}
		counts[payload.UserID] = payload.MeetupsCompleted
	}

	if got, ok := counts[host]; !ok || got != 1 {
		t.Errorf("host count = %d (present=%v), want 1", got, ok)
	}
	if got, ok := counts[accepted]; !ok || got != 1 {
		t.Errorf("accepted requester count = %d (present=%v), want 1", got, ok)
	}
	if _, ok := counts[rejected]; ok {
		t.Error("a rejected requester was counted as having completed the meetup")
	}
	if len(counts) != 2 {
		t.Errorf("published for %d users, want exactly the host and the accepted requester", len(counts))
	}
}

// TestMeetupsCompleted_CountsAccumulateAndAreAbsolute pins the property the
// auth-side consumer's idempotency rests on: each event carries the user's
// TOTAL, not a delta. Re-applying an absolute total is harmless; re-applying
// a "+1" would inflate the figure on every redelivery.
//
// CHANGED BY PLAN 06: now exercised through the outbox and poller rather
// than the inline recompute. Same assertion — [1, 2, 3], not [1,1,1] and not
// [1,3,6] — which is exactly why it is worth re-running against the new
// path rather than rewriting it.
func TestMeetupsCompleted_CountsAccumulateAndAreAbsolute(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	closeOne := func() {
		m, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
			HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
			WindowStart: time.Now().Add(-time.Minute), WindowEnd: time.Now().Add(time.Hour),
			LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
		})
		if err != nil {
			t.Fatalf("CreateMeetup: %v", err)
		}
		if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
			MeetupID: m.ID, HostUserID: host,
		}); err != nil {
			t.Fatalf("CloseMeetup: %v", err)
		}
		// Drained after EACH close rather than once at the end: draining
		// once would let the three outbox rows be processed back-to-back
		// against the final database state and publish 3, 3, 3, which would
		// pass a weaker assertion while proving nothing about accumulation.
		// One drain per close is also what actually happens in production,
		// where each close wakes the poller.
		h.drainCompletedOutbox(t, ctx)
	}

	closeOne()
	closeOne()
	closeOne()

	var totals []int
	for _, p := range h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated) {
		payload := p.(eventbus.MeetupsCompletedUpdatedPayload)
		if payload.UserID == host {
			totals = append(totals, payload.MeetupsCompleted)
		}
	}

	// 1, 2, 3 — not 1, 1, 1 (which is what a delta would look like) and not
	// 1, 3, 6 (which is what double-counting would look like).
	want := []int{1, 2, 3}
	if len(totals) != len(want) {
		t.Fatalf("published %d events for the host, want %d: %v", len(totals), len(want), totals)
	}
	for i, got := range totals {
		if got != want[i] {
			t.Errorf("event %d carried %d, want %d (totals: %v)", i, got, want[i], totals)
		}
	}
}

// --- ShareWithContacts (safety share) --------------------------------------
//
// Replaces the old live-location switch, which wrote a boolean nothing read.
// These tests are mostly about what a modified CLIENT cannot do, because the
// feature texts real phone numbers.

func TestShareWithContacts_SendsTheMeetupsOwnFactsAndRecordsWhoWasTold_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	contactA, contactB := newUUID(t), newUUID(t)
	h.contacts.owned[contactA] = true
	h.contacts.owned[contactB] = true

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	state, err := h.svc.ShareWithContacts(ctx, meetup.ShareWithContactsRequest{
		MeetupID: m.ID, UserID: host, ContactIDs: []string{contactA, contactB},
	})
	if err != nil {
		t.Fatalf("ShareWithContacts: %v", err)
	}

	// The facts handed to auth come off the MEETUP ROW, not from the caller.
	call, ok := h.contacts.lastCall()
	if !ok {
		t.Fatal("the notifier was never called")
	}
	// LocationLabel/WindowStart are pointers on the service-layer type only
	// because ADR-028 can redact them for a non-participant; the host always
	// has them.
	if m.LocationLabel == nil || call.LocationLabel != *m.LocationLabel {
		t.Errorf("label = %q, want the meetup's own", call.LocationLabel)
	}
	if m.LocationLat == nil || m.LocationLng == nil ||
		call.Latitude != *m.LocationLat || call.Longitude != *m.LocationLng {
		t.Errorf("coordinates = (%v, %v), want the meetup's own",
			call.Latitude, call.Longitude)
	}
	if m.WindowStart == nil || !call.WindowStart.Equal(*m.WindowStart) {
		t.Error("window start did not come from the meetup row")
	}
	if m.WindowEnd == nil || !call.WindowEnd.Equal(*m.WindowEnd) {
		t.Error("window end did not come from the meetup row")
	}

	// And the share is recorded, so reopening the screen shows what happened.
	if len(state.SharedWithContactIDs) != 2 {
		t.Fatalf("shared with %v, want both contacts", state.SharedWithContactIDs)
	}

	reread, err := h.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host})
	if err != nil {
		t.Fatalf("GetSafetyState: %v", err)
	}
	if len(reread.SharedWithContactIDs) != 2 {
		t.Errorf("after a re-read, shared = %v, want both — the record is the "+
			"whole point: an action the user cannot confirm afterwards is one "+
			"they cannot rely on", reread.SharedWithContactIDs)
	}
}

func TestShareWithContacts_IsIdempotentPerContact_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	contact := newUUID(t)
	h.contacts.owned[contact] = true

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	req := meetup.ShareWithContactsRequest{
		MeetupID: m.ID, UserID: host, ContactIDs: []string{contact},
	}

	if _, err := h.svc.ShareWithContacts(ctx, req); err != nil {
		t.Fatalf("first share: %v", err)
	}
	state, err := h.svc.ShareWithContacts(ctx, req)
	if err != nil {
		t.Fatalf("second share: %v", err)
	}

	// One row, not two — "select all" must be safe to press twice.
	if len(state.SharedWithContactIDs) != 1 {
		t.Errorf("shared = %v, want exactly one entry after two shares", state.SharedWithContactIDs)
	}
}

func TestShareWithContacts_RejectsContactsThatAreNotYours_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	// Deliberately NOT added to the notifier's owned set — this is a guessed
	// uuid belonging to somebody else.
	stranger := newUUID(t)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	_, err := h.svc.ShareWithContacts(ctx, meetup.ShareWithContactsRequest{
		MeetupID: m.ID, UserID: host, ContactIDs: []string{stranger},
	})
	if err == nil {
		t.Fatal("a contact id that is not the caller's own was accepted — that " +
			"is a way to text a stranger by guessing a uuid")
	}

	state, _ := h.svc.GetSafetyState(ctx, meetup.SafetyStateRequest{MeetupID: m.ID, UserID: host})
	if len(state.SharedWithContactIDs) != 0 {
		t.Errorf("a rejected share was still recorded: %v", state.SharedWithContactIDs)
	}
}

func TestShareWithContacts_RequiresParticipation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	outsider := newUserID(t, h)
	contact := newUUID(t)
	h.contacts.owned[contact] = true

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	_, err := h.svc.ShareWithContacts(ctx, meetup.ShareWithContactsRequest{
		MeetupID: m.ID, UserID: outsider, ContactIDs: []string{contact},
	})
	if !isSentinel(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want ErrForbidden — someone who is not on this "+
			"meetup must not be able to read its place and time out through "+
			"a share", err)
	}
	if h.contacts.callCount() != 0 {
		t.Error("the notifier was called for a non-participant")
	}
}

func TestShareWithContacts_RejectsAnEmptySelection_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	_, err := h.svc.ShareWithContacts(ctx, meetup.ShareWithContactsRequest{
		MeetupID: m.ID, UserID: host, ContactIDs: nil,
	})
	if !isSentinel(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want ErrInvalidInput", err)
	}
}

// TestListOpenMeetups_ExcludesEndedMeetups guards a bug reported from the
// deployed app on 2026-09-10: a meetup whose window had ended two hours
// earlier was still in the browse list, still presented as joinable.
//
// The cause was that the query filtered on m.status alone. Status is written
// by the auto-close sweep, and on Cloud Run with minScale 0 that sweep only
// advances while a container happens to exist — the production meetup in
// question ended at 11:15 and was not closed until 13:08, when an unrelated
// request woke an instance. For 1h53m the read path was reporting a finished
// meetup as open, because it was asking a background job instead of the clock.
//
// So this test deliberately reproduces the UN-SWEPT state — window in the
// past, status still 'open' — and asserts the list excludes it anyway. If
// someone later "simplifies" the query back to a status check, this fails.
func TestListOpenMeetups_ExcludesEndedMeetups(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	viewer := newUserID(t, h)
	host := newUserID(t, h)

	ended := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	live := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)

	// Backdate the window WITHOUT touching status — the sweep's absence is
	// the whole point of the scenario.
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups
		    SET window_start = now() - interval '3 hours',
		        window_end   = now() - interval '1 hour'
		  WHERE id = $1`, ended.ID); err != nil {
		t.Fatalf("backdating the meetup window: %v", err)
	}

	// Assert the precondition rather than assuming it. If status had also
	// flipped to 'closed', this test would still pass — but for the old
	// reason, and it would stop guarding anything.
	var status string
	if err := h.pool.QueryRow(ctx,
		`SELECT status::text FROM meetup.meetups WHERE id = $1`, ended.ID).Scan(&status); err != nil {
		t.Fatalf("reading status back: %v", err)
	}
	if status != "open" {
		t.Fatalf("precondition failed: status is %q, want \"open\" — this test is only meaningful while the sweep has NOT run", status)
	}

	assertList := func(t *testing.T, userID, label string) {
		t.Helper()
		result, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
			UserID: userID, Intent: intentPtr(meetup.IntentCoffee),
			ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
		})
		if err != nil {
			t.Fatalf("ListOpenMeetups(%s): %v", label, err)
		}
		got := map[string]bool{}
		for _, m := range result.Meetups {
			got[m.ID] = true
		}
		if got[ended.ID] {
			t.Errorf("%s: a meetup whose window ended an hour ago is still listed as open", label)
		}
		if !got[live.ID] {
			t.Errorf("%s: the still-live meetup was excluded — the filter is dropping too much", label)
		}
	}

	assertList(t, viewer, "stranger")
	// The host bypasses the radius filter, so it is worth proving the clock
	// filter is not bypassed along with it — they are separate conditions and
	// only one of them should be waivable.
	assertList(t, host, "host")
}

// TestEndedMeetup_LeavesBrowseButStaysOnParticipantSurfaces is the other half
// of TestListOpenMeetups_ExcludesEndedMeetups, and exists because the obvious
// way to get that one passing is to over-filter.
//
// "A finished meetup is not discoverable" and "a finished meetup is gone" are
// different statements, and only the first is wanted. The people who were on
// it still need it: to review it, and to find it in their own lists. So this
// asserts both directions on the SAME meetup — absent from the open list,
// present for its host — which is the pair a future change has to keep true
// together. Filtering window_end in ListMeetupsByHost or GetMeetupByID would
// pass the sibling test and fail this one.
func TestEndedMeetup_LeavesBrowseButStaysOnParticipantSurfaces(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)
	stranger := newUserID(t, h)

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups
		    SET window_start = now() - interval '3 hours',
		        window_end   = now() - interval '1 hour'
		  WHERE id = $1`, m.ID); err != nil {
		t.Fatalf("backdating the meetup window: %v", err)
	}

	// 1. Gone from discovery, for a stranger.
	open, err := h.svc.ListOpenMeetups(ctx, meetup.ListOpenMeetupsRequest{
		UserID: stranger, Intent: intentPtr(meetup.IntentCoffee),
		ViewerLat: colomboLat, ViewerLng: colomboLng, ViewerTrustLevel: 4,
	})
	if err != nil {
		t.Fatalf("ListOpenMeetups: %v", err)
	}
	for _, got := range open.Meetups {
		if got.ID == m.ID {
			t.Error("an ended meetup is still discoverable in the browse list")
		}
	}

	// 2. Still fetchable by id — this is what makes the detail page, and the
	// review flow on it, reachable at all after the meetup is over.
	if _, err := h.svc.GetMeetup(ctx, meetup.GetMeetupRequest{
		MeetupID: m.ID, UserID: host, ViewerTrustLevel: 4,
	}); err != nil {
		t.Fatalf("GetMeetup on an ended meetup: %v — the review flow is unreachable without this", err)
	}

	// 3. Still in the host's own list. EventsPage is built from this, so a
	// host who cannot find a finished meetup here cannot review it either.
	hosted, _, err := h.meetups.ListByHost(ctx, host, nil, 0)
	if err != nil {
		t.Fatalf("ListByHost: %v", err)
	}
	found := false
	for _, got := range hosted {
		if got.ID == m.ID {
			found = true
		}
	}
	if !found {
		t.Error("an ended meetup vanished from its own host's list — Events would lose it, and with it the review")
	}
}
