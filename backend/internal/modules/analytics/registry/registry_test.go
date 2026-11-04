package registry

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func input(name string, attrs string) Input {
	return Input{
		EventID:       "0192f0a4-7b1c-7d3e-8f00-0123456789ab",
		Name:          name,
		SchemaVersion: 1,
		OccurredAt:    now.Add(-time.Minute).Format(time.RFC3339Nano),
		Attributes:    json.RawMessage(attrs),
	}
}

func TestTheEmbeddedRegistryParses(t *testing.T) {
	r := Default()
	for _, name := range []string{
		// Plan 29 §4.1: sessions, screens, actions, flows, friction, and
		// the server's domain events.
		"app_opened", "app_foregrounded", "app_backgrounded", "session_started", "session_ended",
		"screen_viewed", "screen_left", "cta_tapped", "search_performed", "filter_changed", "toggle_changed",
		"flow_started", "flow_step_viewed", "flow_step_completed", "flow_completed", "flow_abandoned",
		"error_shown", "api_error", "request_timeout", "rage_tap", "long_dwell",
		"meetup_created", "join_requested", "request_accepted", "meetup_completed",
		"credits_granted", "credits_spent", "credits_refunded", "credits_expired", "credits_revoked",
		"purchase_verified", "subscription_changed",
	} {
		if _, ok := r.Events[name]; !ok {
			t.Errorf("event %s is missing from the registry", name)
		}
	}
	for _, flow := range []string{"onboarding", "verify_level_2", "hosting_unlock", "schedule_meetup", "join_meetup", "review_meetup", "buy_credits", "subscribe", "sos"} {
		if _, ok := r.Flows[flow]; !ok {
			t.Errorf("flow %s is missing", flow)
		}
	}
	if got := len(r.Flows["schedule_meetup"]); got != 5 {
		t.Errorf("schedule_meetup has %d steps, want 5", got)
	}
}

func TestAValidEventPasses(t *testing.T) {
	r := Default()
	in := input("screen_left", `{"duration_ms": 4200}`)
	in.Screen = "home"
	in.SessionID = "0192F0A4-7B1C-7D3E-8F00-0123456789AB"
	res := r.Validate(in, SourceApp, now)
	if res.Dropped != "" || len(res.AttributeDrops) != 0 {
		t.Fatalf("dropped: %+v", res)
	}
	if res.Event.Attributes["duration_ms"] != int64(4200) || res.Event.Family != "screen" {
		t.Errorf("event = %+v", res.Event)
	}
	if res.Event.SessionID != strings.ToLower(in.SessionID) {
		t.Errorf("session id not normalised: %s", res.Event.SessionID)
	}
}

func TestUnknownEventIsDropped(t *testing.T) {
	if got := Default().Validate(input("user_email_entered", `{}`), SourceApp, now).Dropped; got != DropUnknownEvent {
		t.Errorf("dropped = %q", got)
	}
}

func TestTheAppCannotSendAServerEvent(t *testing.T) {
	res := Default().Validate(input("purchase_verified", `{"platform":"ios","kind":"consumable","product_id":"credits_50"}`), SourceApp, now)
	if res.Dropped != DropServerOnly {
		t.Errorf("dropped = %q", res.Dropped)
	}
}

func TestAttributeDrops(t *testing.T) {
	r := Default()
	cases := []struct {
		name, event, attrs, want string
	}{
		{"unknown attribute", "screen_left", `{"duration_ms": 1, "email": "a@b.c"}`, DropUnknownAttribute},
		{"wrong type: string for int", "screen_left", `{"duration_ms": "12"}`, DropWrongType},
		{"wrong type: float for int", "screen_left", `{"duration_ms": 1.5}`, DropWrongType},
		{"wrong type: int for bool", "app_opened", `{"cold_start": 1}`, DropWrongType},
		{"string over 100 characters", "error_shown", `{"kind": "` + strings.Repeat("a", 101) + `"}`, DropStringTooLong},
		{"free text is not an identifier", "error_shown", `{"kind": "Could not reach Jane Doe"}`, DropNotIdentifier},
		{"enum value not listed", "cta_tapped", `{"cta": "secret_button"}`, DropNotAllowed},
		{"negative int", "screen_left", `{"duration_ms": -1}`, DropOutOfRange},
		{"int over the max", "rage_tap", `{"taps": 101}`, DropOutOfRange},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			res := r.Validate(input(c.event, c.attrs), SourceApp, now)
			if res.Dropped != "" {
				t.Fatalf("whole event dropped: %s", res.Dropped)
			}
			found := false
			for _, d := range res.AttributeDrops {
				found = found || d == c.want
			}
			if !found {
				t.Errorf("drops = %v, want %s", res.AttributeDrops, c.want)
			}
			raw, _ := json.Marshal(res.Event.Attributes)
			if strings.Contains(string(raw), "a@b.c") || strings.Contains(string(raw), "Jane") || strings.Contains(string(raw), "secret") {
				t.Errorf("a dropped attribute was kept: %s", raw)
			}
		})
	}
}

func TestEventLevelDrops(t *testing.T) {
	r := Default()
	many := map[string]int{}
	for i := 0; i < 21; i++ {
		many["k"+string(rune('a'+i))] = i
	}
	manyJSON, _ := json.Marshal(many)
	cases := []struct {
		name string
		edit func(*Input)
		want string
	}{
		{"more than 20 keys", func(in *Input) { in.Attributes = manyJSON }, DropTooManyAttributes},
		{"attributes not an object", func(in *Input) { in.Attributes = json.RawMessage(`[1]`) }, DropBadEnvelope},
		{"bad event id", func(in *Input) { in.EventID = "not-a-uuid" }, DropBadEnvelope},
		{"nil event id", func(in *Input) { in.EventID = "00000000-0000-0000-0000-000000000000" }, DropBadEnvelope},
		{"bad time", func(in *Input) { in.OccurredAt = "yesterday" }, DropBadEnvelope},
		{"8 days ago", func(in *Input) { in.OccurredAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339) }, DropClockSkew},
		{"8 days ahead", func(in *Input) { in.OccurredAt = now.Add(8 * 24 * time.Hour).Format(time.RFC3339) }, DropClockSkew},
		{"future version", func(in *Input) { in.SchemaVersion = 2 }, DropBadVersion},
		{"unknown screen", func(in *Input) { in.Screen = "admin_console" }, DropUnknownScreen},
		{"unknown flow", func(in *Input) { in.FlowID = "checkout" }, DropUnknownFlow},
		{"step of another flow", func(in *Input) { in.FlowID = "schedule_meetup"; in.FlowStep = "otp" }, DropUnknownFlow},
		{"step without a flow", func(in *Input) { in.FlowStep = "review" }, DropUnknownFlow},
		{"bad session id", func(in *Input) { in.SessionID = "Jane's phone" }, DropBadEnvelope},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := input("screen_viewed", `{}`)
			c.edit(&in)
			if got := r.Validate(in, SourceApp, now).Dropped; got != c.want {
				t.Errorf("dropped = %q, want %q", got, c.want)
			}
		})
	}
	ok := input("screen_viewed", `{}`)
	ok.OccurredAt = now.Add(-6 * 24 * time.Hour).Format(time.RFC3339)
	if got := r.Validate(ok, SourceApp, now).Dropped; got != "" {
		t.Errorf("6 days old is within the window, dropped %q", got)
	}
}

func TestParseRejectsABrokenRegistry(t *testing.T) {
	for name, doc := range map[string]string{
		"unknown field":       "events:\n  a_b:\n    version: 1\n    family: session\n    source: app\n    pii: true\n",
		"unknown type":        "events:\n  a_b:\n    version: 1\n    family: session\n    source: app\n    attributes:\n      x: {type: text}\n",
		"server family, app":  "events:\n  a_b:\n    version: 1\n    family: server\n    source: app\n",
		"camel case":          "events:\n  aB:\n    version: 1\n    family: session\n    source: app\n",
		"enum without values": "events:\n  a_b:\n    version: 1\n    family: session\n    source: app\n    attributes:\n      x: {type: enum}\n",
	} {
		if _, err := Parse([]byte(doc)); err == nil {
			t.Errorf("%s: parsed", name)
		}
	}
}

// TestTheDartConstantsAreUpToDate fails when events.yaml changed without
// `go generate ./internal/modules/analytics/registry`.
func TestTheDartConstantsAreUpToDate(t *testing.T) {
	checkedIn, err := os.ReadFile("../../../../../frontend/lib/core/analytics/event_names.g.dart")
	if err != nil {
		t.Fatalf("read the generated file: %v", err)
	}
	if string(checkedIn) != string(Default().Dart()) {
		t.Fatal("frontend/lib/core/analytics/event_names.g.dart is out of date: run `go generate ./internal/modules/analytics/registry`")
	}
}

func TestTheDartConstantsLeaveOutServerEvents(t *testing.T) {
	dart := string(Default().Dart())
	for _, server := range []string{"purchase_verified", "credits_spent", "meetup_created"} {
		if strings.Contains(dart, "'"+server+"'") {
			t.Errorf("the app has a constant for the server event %s", server)
		}
	}
}

// #119 (review N1-L4): an id-typed attribute names a thing in the app (a
// filter, a toggle), never a record. A UUID there would be a user, meetup
// or contact id slipping into analytics, so it is refused.
func TestAnIDAttributeRefusesUUIDs(t *testing.T) {
	r := Default()
	for _, v := range []string{"0192f0a4-7b1c-7d3e-8f00-0123456789ab", "0192F0A4-7B1C-7D3E-8F00-0123456789AB", "0192f0a47b1c7d3e8f000123456789ab"} {
		res := r.Validate(input("filter_changed", `{"filter": "`+v+`", "active": true}`), SourceApp, now)
		if len(res.AttributeDrops) != 1 || res.AttributeDrops[0] != DropNotIdentifier {
			t.Errorf("%s: drops %v, want not_identifier", v, res.AttributeDrops)
		}
	}
	res := r.Validate(input("filter_changed", `{"filter": "intent.coffee", "active": true}`), SourceApp, now)
	if len(res.AttributeDrops) != 0 {
		t.Errorf("an ordinary id was refused: %v", res.AttributeDrops)
	}
}
