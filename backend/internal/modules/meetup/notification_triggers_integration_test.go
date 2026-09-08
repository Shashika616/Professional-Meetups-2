package meetup_test

// §E4: every notification trigger, verified end to end.
//
// # WHY THIS IS A TEST RATHER THAN A MANUAL CHECKLIST
//
// The hardening plan asked for these seven triggers to be exercised with two
// real accounts and a real device. That exercises the same code once, on one
// machine, and proves nothing the next time anyone changes requests.go. These
// tests assert the same facts — WHO is notified, WITH WHAT COPY, for each
// trigger — against real Postgres, on every run, forever.
//
// What they deliberately do NOT cover is the last hop: whether a push
// physically arrives on a handset. That is covered separately and really,
// against the live FCM API (see the completion report's §E4) — the piece
// that cannot be automated here is a physical device, not the logic.
//
// Every assertion below reads meetup.notification_outbox directly, because
// that is now the durable record of "this notification was raised" — the
// point at which the business logic's job is done and delivery becomes the
// poller's problem.

import (
	"context"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
)

// notifiedSet returns which users have a queued notification with the given
// title, resolved back from the tokens in the outbox row.
func notifiedSet(t *testing.T, h *harness, title string) map[string]int {
	t.Helper()
	rows, err := h.pool.Query(context.Background(), `
		SELECT dt.user_id::text, count(*)
		FROM meetup.notification_outbox o
		JOIN meetup.device_tokens dt ON dt.fcm_token = ANY(o.fcm_tokens)
		WHERE o.title = $1
		GROUP BY dt.user_id`, title)
	if err != nil {
		t.Fatalf("resolve notified users for %q: %v", title, err)
	}
	defer rows.Close()

	out := map[string]int{}
	for rows.Next() {
		var userID string
		var n int
		if err := rows.Scan(&userID, &n); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[userID] = n
	}
	return out
}

func assertNotified(t *testing.T, h *harness, title string, want map[string]string) {
	t.Helper()
	got := notifiedSet(t, h, title)

	for userID, role := range want {
		if got[userID] == 0 {
			t.Errorf("%q: %s was NOT notified", title, role)
		} else if got[userID] > 1 {
			t.Errorf("%q: %s was notified %d times, want once", title, role, got[userID])
		}
	}
	for userID, n := range got {
		if _, expected := want[userID]; !expected {
			t.Errorf("%q: an unintended recipient %s was notified %d time(s)", title, userID, n)
		}
	}
}

// triggerHarness sets up a host, a requester, and a bystander who must never
// be notified by any of this.
type triggerFixture struct {
	host      string
	requester string
	other     string
	bystander string
	meetupID  string
}

func newTriggerFixture(t *testing.T, h *harness, capacity int) triggerFixture {
	t.Helper()
	ctx := context.Background()

	f := triggerFixture{
		host:      newUserID(t, h),
		requester: newUserID(t, h),
		other:     newUserID(t, h),
		bystander: newUserID(t, h),
	}
	for name, id := range map[string]string{"Host": f.host, "Requester": f.requester, "Other": f.other, "Bystander": f.bystander} {
		seedDisplay(t, h, id, name)
		if err := h.deviceTokens.Upsert(ctx, id, "device-"+id); err != nil {
			t.Fatalf("register device for %s: %v", name, err)
		}
	}

	m, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: f.host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(3 * time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Test Cafe",
		Capacity: capacity,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	f.meetupID = m.ID

	// Creation queues the host's own checklist prompt; clear it so each test
	// below starts from a clean outbox.
	clearOutbox(t, h)
	return f
}

// Row 1: RequestToJoin -> host, "New join request".
func TestTrigger_RequestToJoin_NotifiesHost_Integration(t *testing.T) {
	h := newHarness(t)
	f := newTriggerFixture(t, h, 2)

	if _, err := h.svc.RequestToJoin(context.Background(), requestToJoin(f.meetupID, f.requester)); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	assertNotified(t, h, "New join request", map[string]string{f.host: "the host"})
}

// Row 2: WithdrawRequest -> host, "Request withdrawn".
func TestTrigger_WithdrawRequest_NotifiesHost_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 2)

	r, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	clearOutbox(t, h)

	if err := h.svc.WithdrawRequest(ctx, meetup.WithdrawRequestRequest{
		RequestID: r.ID, RequesterID: f.requester, Note: "sorry",
	}); err != nil {
		t.Fatalf("WithdrawRequest: %v", err)
	}

	assertNotified(t, h, "Request withdrawn", map[string]string{f.host: "the host"})
}

// Rows 3+4: RespondToRequest(accept) -> requester gets BOTH "Request
// accepted" and the safety-checklist follow-up.
func TestTrigger_AcceptRequest_NotifiesRequesterTwice_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 2)

	r, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	clearOutbox(t, h)

	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("RespondToRequest(accept): %v", err)
	}

	assertNotified(t, h, "Request accepted", map[string]string{f.requester: "the requester"})
	assertNotified(t, h, "Review your safety checklist", map[string]string{f.requester: "the requester"})
}

// Row 5: RespondToRequest(reject) -> requester, "Request declined".
func TestTrigger_RejectRequest_NotifiesRequester_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 2)

	r, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	clearOutbox(t, h)

	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: f.host, Accept: false,
	}); err != nil {
		t.Fatalf("RespondToRequest(reject): %v", err)
	}

	assertNotified(t, h, "Request declined", map[string]string{f.requester: "the requester"})
}

// Row 6: auto-reject on capacity -> each auto-rejected requester, "Meetup is
// full". Fires INSIDE the accept that fills the meetup, which is what makes
// it easy to miss.
func TestTrigger_AutoRejectOnCapacity_NotifiesEachRejectedRequester_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 1) // capacity 1: one accept fills it

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin(requester): %v", err)
	}
	if _, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.other)); err != nil {
		t.Fatalf("RequestToJoin(other): %v", err)
	}
	clearOutbox(t, h)

	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("RespondToRequest(accept): %v", err)
	}

	assertNotified(t, h, "Meetup is full", map[string]string{f.other: "the auto-rejected requester"})
	// And the accepted one still gets their own notifications, not the
	// capacity notice.
	assertNotified(t, h, "Request accepted", map[string]string{f.requester: "the accepted requester"})
}

// Row 7: CancelMeetup -> every ACCEPTED requester, "Meetup cancelled".
// A merely-pending requester is deliberately not notified.
func TestTrigger_CancelMeetup_NotifiesAcceptedRequesters_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 3)

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin(accepted): %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	// A still-pending requester.
	if _, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.other)); err != nil {
		t.Fatalf("RequestToJoin(pending): %v", err)
	}
	clearOutbox(t, h)

	if err := h.svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
		MeetupID: f.meetupID, HostUserID: f.host, Reason: "something came up",
	}); err != nil {
		t.Fatalf("CancelMeetup: %v", err)
	}

	assertNotified(t, h, "Meetup cancelled", map[string]string{f.requester: "the accepted requester"})
}

// Row 8a: CloseMeetup (manual) -> host AND every accepted requester,
// "Meetup ended".
func TestTrigger_CloseMeetupManually_NotifiesHostAndParticipants_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 3)

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// CloseMeetup requires the window to have started.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups SET window_start = now() - interval '1 hour' WHERE id = $1`, f.meetupID); err != nil {
		t.Fatalf("start the window: %v", err)
	}
	clearOutbox(t, h)

	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{
		MeetupID: f.meetupID, HostUserID: f.host,
	}); err != nil {
		t.Fatalf("CloseMeetup: %v", err)
	}

	assertNotified(t, h, "Meetup ended", map[string]string{
		f.host:      "the host",
		f.requester: "the accepted requester",
	})
}

// Row 8b: the AUTO-CLOSE poller -> host AND every accepted requester,
// "Meetup ended". The plan called this out specifically: it must be verified
// through the poller path, not only the manual one, since they are different
// entry points into the same helper.
func TestTrigger_AutoClosePoller_NotifiesHostAndParticipants_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 3)

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	// Let the window lapse, then run the sweep the lifecycle poller runs.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups
		SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour'
		WHERE id = $1`, f.meetupID); err != nil {
		t.Fatalf("lapse the window: %v", err)
	}
	clearOutbox(t, h)

	closed, err := h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("AutoCloseSweep: %v", err)
	}
	if closed != 1 {
		t.Fatalf("AutoCloseSweep closed %d meetups, want 1", closed)
	}

	assertNotified(t, h, "Meetup ended", map[string]string{
		f.host:      "the host",
		f.requester: "the accepted requester",
	})
}

// Row 9: starting-soon reminder -> host and every accepted requester.
func TestTrigger_StartingSoonSweep_NotifiesHostAndParticipants_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 3)

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups SET window_start = now() + interval '10 minutes' WHERE id = $1`, f.meetupID); err != nil {
		t.Fatalf("move into the starting-soon window: %v", err)
	}
	clearOutbox(t, h)

	notified, err := h.svc.NotifyStartingSoonSweep(ctx)
	if err != nil {
		t.Fatalf("NotifyStartingSoonSweep: %v", err)
	}
	if notified != 1 {
		t.Fatalf("sweep claimed %d meetups, want 1", notified)
	}

	assertNotified(t, h, "Meetup starting soon", map[string]string{
		f.host:      "the host",
		f.requester: "the accepted requester",
	})
}

// Row 10: Safety Gate decline -> host, "Participant declined".
func TestTrigger_SafetyGateDecline_NotifiesHost_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 3)

	accepted, err := h.svc.RequestToJoin(ctx, requestToJoin(f.meetupID, f.requester))
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: accepted.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	clearOutbox(t, h)

	if _, err := h.svc.DeclineCheckIn(ctx, meetup.DeclineCheckInRequest{
		MeetupID: f.meetupID, UserID: f.requester, Reason: "no longer comfortable",
	}); err != nil {
		t.Fatalf("DeclineCheckIn: %v", err)
	}

	assertNotified(t, h, "Participant declined", map[string]string{f.host: "the host"})
}

// TestEveryNotificationCarriesAType is the guard for the bug this constant
// set exists to fix.
//
// Nothing set a `type` on any push. The client's foreground handler reads
// `data['type']`, so it got "" on every message and its
// `== "meetup_closed"` branch could never fire — a user with the app OPEN
// got no system banner (FCM suppresses those in the foreground), no in-app
// notice, and no refresh.
//
// This walks the whole notification surface rather than one trigger:
// `queueNotification`/`queueNotifications` now take the type as a required
// parameter, so a NEW notification cannot compile without one — but it could
// still pass an empty string, and this catches that.
func TestEveryNotificationCarriesAType_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 4)

	// Exercise the request-side triggers, which cover most of the surface.
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: f.meetupID, RequesterID: f.requester, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	rows, err := h.pool.Query(ctx, `
		SELECT title, data FROM meetup.notification_outbox ORDER BY created_at`)
	if err != nil {
		t.Fatalf("query outbox: %v", err)
	}
	defer rows.Close()

	checked := 0
	for rows.Next() {
		var title string
		var data map[string]string
		if err := rows.Scan(&title, &data); err != nil {
			t.Fatalf("scan: %v", err)
		}
		checked++
		if data["type"] == "" {
			t.Errorf("notification %q carries no type — the client cannot "+
				"decide what to refresh or what to say from a title string", title)
		}
		if data["meetup_id"] == "" {
			t.Errorf("notification %q carries no meetup_id", title)
		}
	}
	if checked == 0 {
		t.Fatal("no notifications were queued, so this test proved nothing")
	}
}

// TestNotificationTypesAreTheOnesTheClientExpects pins the exact wire
// strings. They are a contract with a shipped client, so a rename here is a
// breaking change that must be deliberate.
func TestNotificationTypesAreTheOnesTheClientExpects_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newTriggerFixture(t, h, 4)

	r, _ := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: f.meetupID, RequesterID: f.requester, RequesterTrustLevel: 2,
	})
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	byTitle := map[string]string{}
	rows, err := h.pool.Query(ctx, `SELECT title, data FROM meetup.notification_outbox`)
	if err != nil {
		t.Fatalf("query outbox: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var title string
		var data map[string]string
		if err := rows.Scan(&title, &data); err != nil {
			t.Fatalf("scan: %v", err)
		}
		byTitle[title] = data["type"]
	}

	for title, wantType := range map[string]string{
		"New join request":             "join_request",
		"Request accepted":             "request_accepted",
		"Review your safety checklist": "safety_checklist",
	} {
		if got, ok := byTitle[title]; !ok {
			t.Errorf("%q was never queued", title)
		} else if got != wantType {
			t.Errorf("%q has type %q, want %q", title, got, wantType)
		}
	}
}
