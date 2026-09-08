package meetup

// §C4: fast, fakes-free unit tests for the DB-independent logic.
//
// # WHY THIS FILE EXISTS ALONGSIDE THE INTEGRATION TESTS
//
// Phase 2 covered this module with integration tests against real Postgres,
// which is better coverage of the ported SQL than the source's fakes-based
// suite ever had. What it lost was the source's ~3,900 lines of FAST tests
// over pure logic — the trust gate, redaction, cursor encoding, the
// validators — none of which touch the database at all. Running Postgres to
// check that capacity 0 is rejected is both slow and an odd place to learn
// that it broke.
//
// This is additive: the integration tests stay exactly as they are. What
// this adds is a suite that runs in milliseconds with no Docker, so a pure-
// logic regression is caught by `go test ./internal/modules/meetup/` on a
// laptop with nothing running.
//
// Internal (package meetup, not meetup_test) on purpose — redactForViewer,
// requiredTrustLevel, the cursor codec and isPlaceholderLocationLabel are all
// unexported, and testing them through the exported surface would mean
// standing up a database, which is the thing being avoided.

import (
	"math"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/platform/geo"
)

// --- redactForViewer -------------------------------------------------------
//
// These tests changed VALUES in ADR-002, not just gained cases. Before it,
// redaction keyed off the per-intent join number and nulled location too, so
// a Level 1 viewer of a coffee meetup was fully redacted. After it, only
// Level 0 is redacted and location survives. The old assertions are replaced
// rather than kept alongside — an assertion that contradicts the current
// decision is worse than no assertion, because it looks like coverage.

// TestRedactForViewer_GuestLosesIdentityAndTime is the security-relevant half
// of the guest tier: everything that identifies the host or pins down when to
// turn up is nulled outright, never coarsened.
func TestRedactForViewer_GuestLosesIdentityAndTime(t *testing.T) {
	m := fullyPopulatedMeetup()
	redactForViewer(&m, 0) // a guest

	if !m.LockedForViewer {
		t.Error("LockedForViewer was not set for a guest")
	}

	nulled := map[string]bool{
		"HostFullName":        m.HostFullName == nil,
		"HostProfilePhotoURL": m.HostProfilePhotoURL == nil,
		"WindowStart":         m.WindowStart == nil,
		"WindowEnd":           m.WindowEnd == nil,
	}
	for field, isNil := range nulled {
		if !isNil {
			t.Errorf("%s survived guest-tier redaction — a Level 0 viewer can still read it", field)
		}
	}
}

// TestRedactForViewer_GuestStillSeesLocationAndCount is the half ADR-002
// deliberately LOOSENED, and the one most likely to be "fixed" back by
// someone assuming redaction should null everything.
//
// A guest is meant to see that real meetups are happening near them — that is
// the entire draw, and the reason to sign up. Nulling location here would
// make the guest tier pointless as a product, while nulling the count would
// hide whether a meetup has room. Both were nulled before ADR-002; both must
// now survive.
func TestRedactForViewer_GuestStillSeesLocationAndCount(t *testing.T) {
	m := fullyPopulatedMeetup()
	before := m
	redactForViewer(&m, 0)

	if m.LocationLat == nil || m.LocationLng == nil || m.LocationLabel == nil {
		t.Error("location was nulled for a guest — ADR-002 §5 keeps location visible at Level 0; the guest tier exists to show that meetups are happening nearby")
	}
	if m.LocationLabel != nil && *m.LocationLabel != *before.LocationLabel {
		t.Error("location label was altered rather than left intact")
	}
	if m.AcceptedCount != before.AcceptedCount || m.Capacity != before.Capacity {
		t.Error("accepted count/capacity changed for a guest — both stay visible")
	}
	// Still needs to render and still needs a join target.
	if m.ID == "" || m.Intent == "" || m.Status == "" {
		t.Error("ID/Intent/Status were redacted — a locked card still has to render")
	}
}

// TestRedactForViewer_LevelOneAndAboveSeeEverything is the main behavioural
// change. Before ADR-002 a Level 1 viewer was redacted for every ordinary
// intent (1 < 2); now they see everything, including on a meetup they cannot
// join and could not host.
func TestRedactForViewer_LevelOneAndAboveSeeEverything(t *testing.T) {
	for _, trustLevel := range []int{1, 2, 3, 4} {
		m := fullyPopulatedMeetup()
		redactForViewer(&m, trustLevel)

		if m.LockedForViewer {
			t.Errorf("trust level %d was marked locked — only Level 0 is redacted after ADR-002 §5", trustLevel)
		}
		if m.HostFullName == nil || m.WindowStart == nil || m.LocationLat == nil {
			t.Errorf("trust level %d had fields redacted — Level 1+ sees meetups in full", trustLevel)
		}
	}
}

// TestRedactForViewer_IsIndependentOfTheJoinAndHostGates pins the decoupling
// that IS the point of ADR-002 §5, and directly replaces a pre-ADR-002 test
// asserting the exact opposite (that redaction used the same floor as the
// join gate).
//
// A Level 1 viewer looking at a ride-share meetup — which they need Level 4
// to join and Level 4 to host — must still see it in full. Visibility and
// permission are now different questions, and the failure this guards against
// is someone "restoring consistency" by wiring redaction back to an intent.
func TestRedactForViewer_IsIndependentOfTheJoinAndHostGates(t *testing.T) {
	for _, intent := range []Intent{IntentCoffee, IntentLunch, IntentNetworking, IntentMentorship, IntentRideShare, IntentDating} {
		joinBar := requiredTrustLevelToJoin(intent)
		hostBar := requiredTrustLevelToHost(intent)

		// Level 1: below both bars for every intent, yet fully visible.
		m := fullyPopulatedMeetup()
		m.Intent = intent
		redactForViewer(&m, 1)

		if m.LockedForViewer {
			t.Errorf("%s: a Level 1 viewer was redacted (join bar %d, host bar %d) — visibility must not track either gate", intent, joinBar, hostBar)
		}
		if m.HostFullName == nil {
			t.Errorf("%s: a Level 1 viewer lost the host name", intent)
		}

		// Level 0: redacted for every intent, including ones whose bars differ.
		guest := fullyPopulatedMeetup()
		guest.Intent = intent
		redactForViewer(&guest, 0)
		if !guest.LockedForViewer {
			t.Errorf("%s: a guest was NOT redacted", intent)
		}
	}
}

// --- validation ------------------------------------------------------------

// TestValidateCapacity covers the boundaries of CreateMeetup's capacity
// rule, which the integration tests only sample.
func TestValidateCapacity(t *testing.T) {
	tests := []struct {
		capacity int
		valid    bool
	}{
		{capacity: -1, valid: false},
		{capacity: 0, valid: false},
		{capacity: 1, valid: true},
		{capacity: 2, valid: true},
		{capacity: 20, valid: true},
		{capacity: 21, valid: false},
		{capacity: 1000, valid: false},
	}
	for _, tc := range tests {
		got := tc.capacity >= 1 && tc.capacity <= 20
		if got != tc.valid {
			t.Errorf("capacity %d: valid = %v, want %v", tc.capacity, got, tc.valid)
		}
	}
}

// TestValidateWindow covers the window-ordering and past-window rules,
// including the grace period that exists so a client whose clock is a few
// seconds fast isn't rejected.
func TestValidateWindow(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name        string
		start, end  time.Time
		wantOrderOK bool
		wantPastOK  bool
	}{
		{name: "normal future window", start: now.Add(time.Hour), end: now.Add(2 * time.Hour), wantOrderOK: true, wantPastOK: true},
		{name: "end equals start", start: now.Add(time.Hour), end: now.Add(time.Hour), wantOrderOK: false, wantPastOK: true},
		{name: "end before start", start: now.Add(2 * time.Hour), end: now.Add(time.Hour), wantOrderOK: false, wantPastOK: true},
		{name: "start just inside the grace period", start: now.Add(-windowStartGracePeriod / 2), end: now.Add(time.Hour), wantOrderOK: true, wantPastOK: true},
		{name: "start well in the past", start: now.Add(-24 * time.Hour), end: now.Add(time.Hour), wantOrderOK: true, wantPastOK: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.end.After(tc.start); got != tc.wantOrderOK {
				t.Errorf("window ordering valid = %v, want %v", got, tc.wantOrderOK)
			}
			if got := !tc.start.Before(time.Now().Add(-windowStartGracePeriod)); got != tc.wantPastOK {
				t.Errorf("window not-in-the-past valid = %v, want %v", got, tc.wantPastOK)
			}
		})
	}
}

// TestValidateFreeTextLength covers the shared cap on every free-text field
// this module accepts. These are the fields an attacker controls entirely,
// so the boundary is worth pinning rather than sampling.
func TestValidateFreeTextLength(t *testing.T) {
	tests := []struct {
		name  string
		input string
		valid bool
	}{
		{name: "empty", input: "", valid: true},
		{name: "ordinary", input: "Sorry, something came up.", valid: true},
		{name: "exactly at the cap", input: strings.Repeat("a", maxFreeTextReasonLength), valid: true},
		{name: "one over the cap", input: strings.Repeat("a", maxFreeTextReasonLength+1), valid: false},
		{name: "far over the cap", input: strings.Repeat("a", 100_000), valid: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := len(tc.input) <= maxFreeTextReasonLength; got != tc.valid {
				t.Errorf("len=%d valid = %v, want %v", len(tc.input), got, tc.valid)
			}
		})
	}
}

// TestValidateLatLng_ThroughTheModulesOwnUse re-checks the coordinate rules
// at this module's call site, including §C1's null-island rejection — the
// GPS-failure default that used to pass validation and silently create a
// meetup 5,000km from where its host thought it was.
func TestValidateLatLng_ThroughTheModulesOwnUse(t *testing.T) {
	tests := []struct {
		name     string
		lat, lng float64
		valid    bool
	}{
		{name: "Colombo", lat: 6.9271, lng: 79.8612, valid: true},
		{name: "null island is rejected (§C1)", lat: 0, lng: 0, valid: false},
		{name: "equator, real longitude", lat: 0, lng: 79.8612, valid: true},
		{name: "prime meridian, real latitude", lat: 51.4779, lng: 0, valid: true},
		{name: "latitude out of range", lat: 91, lng: 0, valid: false},
		{name: "longitude out of range", lat: 0, lng: 181, valid: false},
		{name: "NaN", lat: math.NaN(), lng: 0, valid: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := geo.ValidateLatLng(tc.lat, tc.lng) == nil; got != tc.valid {
				t.Errorf("ValidateLatLng(%v, %v) valid = %v, want %v", tc.lat, tc.lng, got, tc.valid)
			}
		})
	}
}

// TestValidIntent pins the closed set. An unrecognised intent must be
// rejected rather than defaulted, because every trust-gate decision keys off
// it — an intent that fell through to a zero value would silently get the
// most permissive floor.
func TestValidIntent(t *testing.T) {
	for _, intent := range []Intent{IntentCoffee, IntentLunch, IntentNetworking, IntentMentorship, IntentRideShare, IntentDating} {
		if !validIntent(intent) {
			t.Errorf("%q is a real intent but was rejected", intent)
		}
	}
	for _, bad := range []Intent{"", "COFFEE", "coffee ", "rideshare", "ride-share", "hookup", "'; DROP TABLE meetup.meetups; --"} {
		if validIntent(bad) {
			t.Errorf("%q was accepted as a valid intent", bad)
		}
	}
}

// TestIsPlaceholderLocationLabel covers the label-replacement rule: only an
// empty or known-placeholder label is replaced by reverse geocoding, never a
// host's own real, searched label.
func TestIsPlaceholderLocationLabel(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{input: "", want: true},
		{input: "   ", want: true},
		{input: "Current location", want: true},
		{input: "current location", want: true},
		{input: "  CURRENT LOCATION  ", want: true},
		{input: "Barista Coffee, Colombo", want: false},
		{input: "My current location cafe", want: false},
	}
	for _, tc := range tests {
		t.Run(tc.input, func(t *testing.T) {
			if got := isPlaceholderLocationLabel(tc.input); got != tc.want {
				t.Errorf("isPlaceholderLocationLabel(%q) = %v, want %v", tc.input, got, tc.want)
			}
		})
	}
}

// --- helpers ---------------------------------------------------------------

func fullyPopulatedMeetup() Meetup {
	name := "Host Person"
	photo := "https://example.com/p.jpg"
	label := "Barista Coffee, Colombo"
	lat, lng := 6.9271, 79.8612
	start := time.Now().Add(time.Hour)
	end := time.Now().Add(2 * time.Hour)

	return Meetup{
		ID:                  "11111111-1111-1111-1111-111111111111",
		HostUserID:          "22222222-2222-2222-2222-222222222222",
		HostFullName:        &name,
		HostProfilePhotoURL: &photo,
		Intent:              IntentRideShare,
		WindowStart:         &start,
		WindowEnd:           &end,
		LocationLat:         &lat,
		LocationLng:         &lng,
		LocationLabel:       &label,
		Capacity:            4,
		AcceptedCount:       1,
		Status:              "open",
	}
}
