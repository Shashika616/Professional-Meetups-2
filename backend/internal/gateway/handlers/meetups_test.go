package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// The meetup half of the gateway's route table. The assertions here are the
// same ones that matter for every authenticated route in this package: the
// route is wired at all, it requires a token, and the identity it acts on
// comes from that token rather than from anything the caller sent.

// meetupCalls records what the handlers asked the monolith for. Embedded in
// fakeMonolith (handlers_test.go) via the shared Client interface, so only
// the methods a test actually drives need implementing.
type meetupRecorder struct {
	gotUserID      string
	gotTrustLevel  int32
	gotMeetupID    string
	gotRequestID   string
	gotIntent      string
	gotViewerLat   float64
	gotViewerLng   float64
	gotCursor      string
	gotReason      string
	gotAccept      bool
	gotOptIn       bool
	gotScore       int32
	gotRatedUserID string

	gotOverallScore       int32
	gotReviewParticipants []monolithclient.ReviewParticipantInput
	review                monolithclient.MeetupReview
	gotFCMToken           string
	gotUnregisteredToken  string
	gotWithinDays         int32
}

// The fake in handlers_test.go embeds monolithclient.Client, so these
// overrides are all that is needed for the meetup routes.
func (f *fakeMonolith) CreateMeetup(_ context.Context, hostUserID string, hostTrustLevel int32, intent string, _, _ int64, _, _ float64, _ string, _ int32) (monolithclient.Meetup, error) {
	f.meetup.gotUserID, f.meetup.gotTrustLevel, f.meetup.gotIntent = hostUserID, hostTrustLevel, intent
	return monolithclient.Meetup{ID: "meetup-1", HostUserID: hostUserID}, f.err
}

func (f *fakeMonolith) ListOpenMeetups(_ context.Context, userID, intent, cursor string, _ int32, viewerLat, viewerLng float64, viewerTrustLevel, withinDays int32) ([]monolithclient.Meetup, string, error) {
	f.meetup.gotUserID, f.meetup.gotIntent, f.meetup.gotCursor = userID, intent, cursor
	f.meetup.gotViewerLat, f.meetup.gotViewerLng, f.meetup.gotTrustLevel = viewerLat, viewerLng, viewerTrustLevel
	f.meetup.gotWithinDays = withinDays
	return []monolithclient.Meetup{{ID: "meetup-1"}}, "next-cursor", f.err
}

func (f *fakeMonolith) GetMeetup(_ context.Context, meetupID, userID string, viewerTrustLevel int32) (monolithclient.Meetup, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID, f.meetup.gotTrustLevel = meetupID, userID, viewerTrustLevel
	if f.meetupResponse.ID != "" {
		return f.meetupResponse, f.err
	}
	return monolithclient.Meetup{ID: meetupID}, f.err
}

func (f *fakeMonolith) ListMyMeetups(_ context.Context, userID, hostedCursor, requestedCursor string) ([]monolithclient.Meetup, []monolithclient.Meetup, string, bool, string, bool, error) {
	f.meetup.gotUserID = userID
	return nil, nil, "", false, "", false, f.err
}

func (f *fakeMonolith) ListActiveMeetups(_ context.Context, userID string) ([]monolithclient.Meetup, error) {
	f.meetup.gotUserID = userID
	return nil, f.err
}

func (f *fakeMonolith) CheckSchedule(_ context.Context, userID string, _, _ int64) (monolithclient.Meetup, bool, error) {
	f.meetup.gotUserID = userID
	if f.meetupResponse.ID != "" {
		return f.meetupResponse, true, f.err
	}
	return monolithclient.Meetup{}, false, f.err
}

func (f *fakeMonolith) ListMeetupRequests(_ context.Context, meetupID, hostUserID string) ([]monolithclient.MeetupRequest, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, hostUserID
	return nil, f.err
}

func (f *fakeMonolith) RequestToJoin(_ context.Context, meetupID, requesterID string, requesterTrustLevel int32) (monolithclient.MeetupRequest, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID, f.meetup.gotTrustLevel = meetupID, requesterID, requesterTrustLevel
	return monolithclient.MeetupRequest{ID: "request-1"}, f.err
}

func (f *fakeMonolith) WithdrawRequest(_ context.Context, requestID, requesterID, note string) error {
	f.meetup.gotRequestID, f.meetup.gotUserID, f.meetup.gotReason = requestID, requesterID, note
	return f.err
}

func (f *fakeMonolith) RespondToRequest(_ context.Context, requestID, hostUserID string, accept bool) (monolithclient.MeetupRequest, error) {
	f.meetup.gotRequestID, f.meetup.gotUserID, f.meetup.gotAccept = requestID, hostUserID, accept
	return monolithclient.MeetupRequest{ID: requestID}, f.err
}

func (f *fakeMonolith) UnregisterDeviceToken(_ context.Context, userID, fcmToken string) error {
	f.meetup.gotUserID, f.meetup.gotUnregisteredToken = userID, fcmToken
	return f.err
}

func (f *fakeMonolith) RegisterDeviceToken(_ context.Context, userID, fcmToken string) error {
	f.meetup.gotUserID, f.meetup.gotFCMToken = userID, fcmToken
	return f.err
}

func (f *fakeMonolith) GetSafetyState(_ context.Context, meetupID, userID string) (monolithclient.SafetyState, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, userID
	return monolithclient.SafetyState{MeetupID: meetupID}, f.err
}

func (f *fakeMonolith) AcknowledgeSafetyChecklist(_ context.Context, meetupID, userID string) (monolithclient.SafetyState, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, userID
	return monolithclient.SafetyState{MeetupID: meetupID}, f.err
}

func (f *fakeMonolith) SetLiveLocationOptIn(_ context.Context, meetupID, userID string, optIn bool) (monolithclient.SafetyState, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID, f.meetup.gotOptIn = meetupID, userID, optIn
	return monolithclient.SafetyState{MeetupID: meetupID}, f.err
}

func (f *fakeMonolith) CheckIn(_ context.Context, meetupID, userID string) (monolithclient.SafetyState, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, userID
	return monolithclient.SafetyState{MeetupID: meetupID}, f.err
}

func (f *fakeMonolith) DeclineCheckIn(_ context.Context, meetupID, userID, reason string) (monolithclient.SafetyState, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID, f.meetup.gotReason = meetupID, userID, reason
	return monolithclient.SafetyState{MeetupID: meetupID}, f.err
}

func (f *fakeMonolith) SubmitMeetupFeedback(_ context.Context, meetupID, userID string, _ bool, _, _, _ *bool, _ *string) error {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, userID
	return f.err
}

func (f *fakeMonolith) ListNotifications(_ context.Context, userID string) ([]monolithclient.UserNotification, error) {
	f.meetup.gotUserID = userID
	return nil, f.err
}

func (f *fakeMonolith) ListMeetupParticipants(_ context.Context, meetupID, viewerID string, viewerTrustLevel int32) (monolithclient.MeetupParticipants, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, viewerID
	f.meetup.gotTrustLevel = viewerTrustLevel
	return monolithclient.MeetupParticipants{}, f.err
}

func (f *fakeMonolith) ListRatableParticipants(_ context.Context, meetupID, viewerID string, viewerTrustLevel int32) (monolithclient.RatableParticipants, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, viewerID
	// Recorded the same way ListMeetupParticipants above records it, so the
	// token-not-body assertion can be made against this endpoint too.
	f.meetup.gotTrustLevel = viewerTrustLevel
	return monolithclient.RatableParticipants{}, f.err
}

func (f *fakeMonolith) SubmitMeetupReview(_ context.Context, meetupID, raterUserID string, overallScore int32, _ *string, participants []monolithclient.ReviewParticipantInput) error {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, raterUserID
	f.meetup.gotOverallScore = overallScore
	f.meetup.gotReviewParticipants = participants
	return f.err
}

func (f *fakeMonolith) GetMeetupReview(_ context.Context, meetupID, viewerID string) (monolithclient.MeetupReview, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, viewerID
	return f.meetup.review, f.err
}

func (f *fakeMonolith) SubmitRating(_ context.Context, meetupID, raterUserID, ratedUserID string, score int32) error {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, raterUserID
	f.meetup.gotRatedUserID, f.meetup.gotScore = ratedUserID, score
	return f.err
}

func (f *fakeMonolith) CloseMeetup(_ context.Context, meetupID, hostUserID string) (monolithclient.Meetup, error) {
	f.meetup.gotMeetupID, f.meetup.gotUserID = meetupID, hostUserID
	return monolithclient.Meetup{ID: meetupID}, f.err
}

func (f *fakeMonolith) CancelMeetup(_ context.Context, meetupID, hostUserID, reason string) error {
	f.meetup.gotMeetupID, f.meetup.gotUserID, f.meetup.gotReason = meetupID, hostUserID, reason
	return f.err
}

// --- tests -------------------------------------------------------------

// TestMeetupRoutes_AreWiredAndRequireAuth walks every meetup route: with a
// token it reaches the monolith (not a 404, not a 503 — proving the Phase 1
// stubs are gone), and without one it is rejected before ever getting there.
func TestMeetupRoutes_AreWiredAndRequireAuth(t *testing.T) {
	routes := []struct{ method, path, body string }{
		{http.MethodPost, "/v1/meetups", `{"intent":"coffee","capacity":2}`},
		{http.MethodGet, "/v1/meetups?intent=coffee&viewer_lat=6.9&viewer_lng=79.8", ""},
		{http.MethodGet, "/v1/meetups/mine", ""},
		{http.MethodGet, "/v1/meetups/active", ""},
		{http.MethodGet, "/v1/meetups/schedule-check?window_start_unix_seconds=1&window_end_unix_seconds=2", ""},
		{http.MethodGet, "/v1/meetups/m1", ""},
		{http.MethodPost, "/v1/meetups/m1/close", `{}`},
		{http.MethodPost, "/v1/meetups/m1/cancel", `{"reason":"x"}`},
		{http.MethodGet, "/v1/meetups/m1/requests", ""},
		{http.MethodPost, "/v1/meetups/m1/requests", `{}`},
		{http.MethodPost, "/v1/meetups/requests/r1/withdraw", `{"note":"x"}`},
		{http.MethodPost, "/v1/meetups/requests/r1/respond", `{"accept":true}`},
		{http.MethodPost, "/v1/meetups/device-token", `{"fcm_token":"t"}`},
		{http.MethodGet, "/v1/meetups/m1/safety", ""},
		{http.MethodPost, "/v1/meetups/m1/safety/checklist", `{}`},
		{http.MethodPost, "/v1/meetups/m1/safety/live-location", `{"opt_in":true}`},
		{http.MethodPost, "/v1/meetups/m1/safety/check-in", `{}`},
		{http.MethodPost, "/v1/meetups/m1/safety/decline", `{"reason":"x"}`},
		{http.MethodPost, "/v1/meetups/m1/feedback", `{"happened":true}`},
		{http.MethodGet, "/v1/meetups/m1/participants", ""},
		{http.MethodGet, "/v1/notifications", ""},
		{http.MethodGet, "/v1/meetups/m1/ratings/ratable", ""},
		{http.MethodPost, "/v1/meetups/m1/ratings", `{"rated_user_id":"u2","score":5}`},
		{http.MethodPost, "/v1/meetups/m1/review", `{"overall_score":5,"participants":[{"user_id":"u2","score":5,"traits":["cheerful"]}]}`},
		{http.MethodGet, "/v1/meetups/m1/review", ""},
	}

	for _, route := range routes {
		t.Run(route.method+" "+route.path, func(t *testing.T) {
			s := newTestServer(t)

			rec := s.do(route.method, route.path, route.body, s.tokenFor(t, "user-1", 4))
			if rec.Code == http.StatusNotFound {
				t.Fatal("route is not registered")
			}
			if rec.Code == http.StatusServiceUnavailable {
				t.Fatal("route still returns 503 — the Phase 1 stub is still wired")
			}
			if rec.Code >= 500 {
				t.Fatalf("status = %d (body %s)", rec.Code, rec.Body.String())
			}
			if s.monolith.meetup.gotUserID != "user-1" {
				t.Errorf("monolith called with user id %q, want user-1 from the token", s.monolith.meetup.gotUserID)
			}
		})

		t.Run(route.method+" "+route.path+" (unauthenticated)", func(t *testing.T) {
			s := newTestServer(t)
			rec := s.do(route.method, route.path, route.body, "")
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
			if s.monolith.meetup.gotUserID != "" {
				t.Errorf("an unauthenticated request reached the monolith as %q", s.monolith.meetup.gotUserID)
			}
		})
	}
}

// TestMeetupRoutes_IdentityAndTrustLevelComeFromTheToken is the IDOR guard
// for this half of the API: a caller who puts someone else's user_id — or a
// higher trust level — in the body or query string must still be acted on as
// themselves, at their own level. Trust level matters as much as identity
// here because it is what the per-intent gate is checked against.
func TestMeetupRoutes_IdentityAndTrustLevelComeFromTheToken(t *testing.T) {
	cases := []struct {
		name, method, path, body string
		wantTrustLevel           bool
	}{
		{"create", http.MethodPost, "/v1/meetups", `{"user_id":"victim","host_trust_level":4,"intent":"coffee","capacity":2}`, true},
		{"browse", http.MethodGet, "/v1/meetups?intent=coffee&viewer_lat=6.9&viewer_lng=79.8&user_id=victim&viewer_trust_level=4", "", true},
		{"get", http.MethodGet, "/v1/meetups/m1?viewer_trust_level=4", "", true},
		{"request to join", http.MethodPost, "/v1/meetups/m1/requests", `{"requester_id":"victim","requester_trust_level":4}`, true},
		{"respond", http.MethodPost, "/v1/meetups/requests/r1/respond", `{"host_user_id":"victim","accept":true}`, false},
		{"withdraw", http.MethodPost, "/v1/meetups/requests/r1/withdraw", `{"requester_id":"victim"}`, false},
		{"close", http.MethodPost, "/v1/meetups/m1/close", `{"host_user_id":"victim"}`, false},
		{"cancel", http.MethodPost, "/v1/meetups/m1/cancel", `{"host_user_id":"victim","reason":"x"}`, false},
		{"safety state", http.MethodGet, "/v1/meetups/m1/safety?user_id=victim", "", false},
		{"check in", http.MethodPost, "/v1/meetups/m1/safety/check-in", `{"user_id":"victim"}`, false},
		{"submit rating", http.MethodPost, "/v1/meetups/m1/ratings", `{"rater_user_id":"victim","rated_user_id":"u2","score":5}`, false},
		// A review writes ratings onto other people's profiles, so the rater
		// must come from the token, never the body.
		{"submit review", http.MethodPost, "/v1/meetups/m1/review", `{"rater_user_id":"victim","overall_score":5,"participants":[]}`, false},
		{"get review", http.MethodGet, "/v1/meetups/m1/review?viewer_id=victim", "", false},
		// The trust level decides whether attendee identities are disclosed
		// at all, so it is exactly the value a modified client would want to
		// supply. It must come from the token.
		{"list participants", http.MethodGet, "/v1/meetups/m1/participants?viewer_id=victim&viewer_trust_level=4", "", true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(t)
			// The attacker's real token says trust level 1.
			rec := s.do(tc.method, tc.path, tc.body, s.tokenFor(t, "attacker", 1))
			if rec.Code >= 500 {
				t.Fatalf("status = %d (body %s)", rec.Code, rec.Body.String())
			}
			if s.monolith.meetup.gotUserID != "attacker" {
				t.Errorf("monolith called with user id %q, want attacker — the body/query value must be ignored", s.monolith.meetup.gotUserID)
			}
			if tc.wantTrustLevel && s.monolith.meetup.gotTrustLevel != 1 {
				t.Errorf("monolith called with trust level %d, want 1 from the token — a client-supplied level must never be trusted",
					s.monolith.meetup.gotTrustLevel)
			}
		})
	}
}

// TestListOpenMeetups_RequiresViewerCoordinates: the browse screen never
// calls this without a location, so a missing or unparseable one is a
// malformed request, not a legitimate "no location" case.
func TestListOpenMeetups_RequiresViewerCoordinates(t *testing.T) {
	// CHANGED (§B): "no intent" was in this table and expected a 400. Intent
	// is optional now — omitting it means "every intent", which backs the
	// browse screen's "All" filter — so that case moved to its own test
	// below asserting the new behaviour rather than being deleted.
	cases := []struct{ name, query string }{
		{"no coordinates", "?intent=coffee"},
		{"no longitude", "?intent=coffee&viewer_lat=6.9"},
		{"unparseable latitude", "?intent=coffee&viewer_lat=north&viewer_lng=79.8"},
		{"unparseable page size", "?intent=coffee&viewer_lat=6.9&viewer_lng=79.8&page_size=many"},
		{"unparseable within_days", "?intent=coffee&viewer_lat=6.9&viewer_lng=79.8&within_days=soon"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(t)
			rec := s.do(http.MethodGet, "/v1/meetups"+tc.query, "", s.tokenFor(t, "user-1", 3))
			if rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", rec.Code)
			}
		})
	}
}

// TestMeetupResponse_OmitsRedactedFields: the REST shape must express
// redaction as ABSENT keys, not zero values — a client has to be able to
// tell "no photo uploaded" from "hidden from you", and a 0.0 coordinate is a
// real place in the Gulf of Guinea.
func TestMeetupResponse_OmitsRedactedFields(t *testing.T) {
	s := newTestServer(t)
	s.monolith.meetupResponse = monolithclient.Meetup{
		ID: "meetup-1", HostUserID: "host-1", Intent: "dating", Status: "open",
		LockedForViewer: true, // every optional field left nil, as the module leaves them
	}

	rec := s.do(http.MethodGet, "/v1/meetups/meetup-1", "", s.tokenFor(t, "user-1", 1))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}

	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, key := range []string{
		"host_full_name", "host_profile_photo_url", "location_lat", "location_lng",
		"location_label", "window_start_unix_seconds", "window_end_unix_seconds",
	} {
		if _, present := body[key]; present {
			t.Errorf("redacted field %q is present in the JSON (value %v) — it must be omitted entirely", key, body[key])
		}
	}
	if body["locked_for_viewer"] != true {
		t.Error("locked_for_viewer is not set — it is the signal the client keys its lock treatment off")
	}
	if body["id"] != "meetup-1" {
		t.Error("the meetup id was omitted, but it must stay visible so the join button has a target")
	}
}

// TestCreateMeetupRoute_HasItsOwnPerUserRateLimit pins the 10/hour limit.
// The blanket per-(IP, path) limit is 20/min, so a limit that trips at 10
// can only be the per-user one.
func TestCreateMeetupRoute_HasItsOwnPerUserRateLimit(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "user-1", 4)
	body := `{"intent":"coffee","capacity":2}`

	for i := 1; i <= 10; i++ {
		rec := s.do(http.MethodPost, "/v1/meetups", body, token)
		if rec.Code != http.StatusOK {
			t.Fatalf("create %d of 10: status = %d, want 200", i, rec.Code)
		}
	}

	rec := s.do(http.MethodPost, "/v1/meetups", body, token)
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("create 11: status = %d, want 429 (the 10/hour per-user limit)", rec.Code)
	}
	if got := strings.TrimSpace(rec.Body.String()); got != `{"error":"rate limited"}` {
		t.Errorf("body = %q, want the standard rate-limited shape", got)
	}

	// A different user is unaffected — the key is per-user.
	rec = s.do(http.MethodPost, "/v1/meetups", body, s.tokenFor(t, "user-2", 4))
	if rec.Code != http.StatusOK {
		t.Errorf("a different user got %d, want 200", rec.Code)
	}
}

// TestListOpenMeetupsRoute_HasNoPerUserRateLimit is the deliberate contrast:
// browsing is frequent, low-stakes, and has no external per-call cost, so it
// keeps only the blanket limit.
func TestListOpenMeetupsRoute_HasNoPerUserRateLimit(t *testing.T) {
	s := newTestServerWithLimiter(t)
	token := s.tokenFor(t, "user-1", 4)

	// More than CreateMeetup's 10/hour, fewer than the blanket 20/min.
	for i := 1; i <= 15; i++ {
		rec := s.do(http.MethodGet, "/v1/meetups?intent=coffee&viewer_lat=6.9&viewer_lng=79.8", "", token)
		if rec.Code != http.StatusOK {
			t.Fatalf("browse %d of 15: status = %d, want 200 — browsing must not carry a per-user limit", i, rec.Code)
		}
	}
}

// --- §B: the two new optional filters --------------------------------------

// TestListOpenMeetups_OmittedIntentMeansAllIntents pins the one previously-
// invalid request whose meaning changed: intent used to be required and its
// absence a 400. It is now the "All" case, forwarded to the monolith as an
// empty intent string.
func TestListOpenMeetups_OmittedIntentMeansAllIntents(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodGet, "/v1/meetups?viewer_lat=6.9&viewer_lng=79.8", "", s.tokenFor(t, "user-1", 3))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — an omitted intent is the \"All\" filter now, not a malformed request", rec.Code)
	}
	if got := s.monolith.meetup.gotIntent; got != "" {
		t.Errorf("forwarded intent = %q, want \"\" (the all-intents sentinel)", got)
	}
}

// TestListOpenMeetups_ForwardsWithinDays confirms the new parameter reaches
// the monolith, and that its absence forwards 0 (unrestricted) rather than
// some accidental default.
func TestListOpenMeetups_ForwardsWithinDays(t *testing.T) {
	t.Run("present", func(t *testing.T) {
		s := newTestServer(t)
		rec := s.do(http.MethodGet, "/v1/meetups?intent=coffee&viewer_lat=6.9&viewer_lng=79.8&within_days=7", "", s.tokenFor(t, "user-1", 3))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		if got := s.monolith.meetup.gotWithinDays; got != 7 {
			t.Errorf("forwarded within_days = %d, want 7", got)
		}
	})

	t.Run("absent means unrestricted", func(t *testing.T) {
		s := newTestServer(t)
		rec := s.do(http.MethodGet, "/v1/meetups?intent=coffee&viewer_lat=6.9&viewer_lng=79.8", "", s.tokenFor(t, "user-1", 3))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		if got := s.monolith.meetup.gotWithinDays; got != 0 {
			t.Errorf("forwarded within_days = %d, want 0 — an absent filter must not become a default window", got)
		}
	})
}

// TestListOpenMeetups_TrustLevelStillComesFromTheJWT is a regression guard,
// not new behaviour: the new filters are query parameters, and the viewer's
// trust level must remain impossible to influence from the query string.
func TestListOpenMeetups_TrustLevelStillComesFromTheJWT(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(
		http.MethodGet,
		"/v1/meetups?viewer_lat=6.9&viewer_lng=79.8&within_days=7&viewer_trust_level=9",
		"",
		s.tokenFor(t, "user-1", 1),
	)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := s.monolith.meetup.gotTrustLevel; got != 1 {
		t.Errorf("forwarded trust level = %d, want 1 from the JWT — a query parameter must never override it", got)
	}
}
