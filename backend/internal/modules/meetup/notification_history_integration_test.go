package meetup_test

import (
	"context"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/modules/notification"
)

// The in-app notification list reads the same outbox rows the poller
// delivers from, filtered to one recipient. These pin the three things that
// make that safe to show a user: it is theirs only, it is bounded by the
// retention window, and a row that never reached anybody is not claimed as
// received.
func TestListNotifications_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")
	// A notification row is only written when the recipient has a device
	// registered — queueNotification no-ops on an empty token set. The app
	// registers one at sign-in.
	if err := h.deviceTokens.Upsert(ctx, host, "device-"+host); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	// RequestToJoin notifies the HOST. The guest gets nothing yet.
	got, err := h.svc.ListNotifications(ctx, host)
	if err != nil {
		t.Fatalf("ListNotifications(host): %v", err)
	}
	// Two: the safety-checklist prompt the host gets when the meetup is
	// created, and the join request. Asserted by type rather than by count
	// so an unrelated new notification elsewhere does not fail this test.
	byType := map[string]meetup.UserNotification{}
	for _, n := range got {
		byType[n.Type] = n
	}
	join, ok := byType[meetup.TypeJoinRequest]
	if !ok {
		t.Fatalf("host saw %+v, want a join-request notification among them", got)
	}
	if join.Title != "New join request" {
		t.Errorf("title = %q, want the join-request copy", join.Title)
	}
	// The push's data payload is lifted out so an in-app row can deep-link
	// exactly where the tapped banner would have.
	if join.MeetupID != m.ID {
		t.Errorf("meetup id = %q, want %q", join.MeetupID, m.ID)
	}
	// Newest first — the list renders in this order without re-sorting.
	for i := 1; i < len(got); i++ {
		if got[i].CreatedAt.After(got[i-1].CreatedAt) {
			t.Errorf("row %d is newer than row %d — the list is not newest-first", i, i-1)
		}
	}

	// Nobody else's notifications, ever.
	guestNotifications, err := h.svc.ListNotifications(ctx, guest)
	if err != nil {
		t.Fatalf("ListNotifications(guest): %v", err)
	}
	if len(guestNotifications) != 0 {
		t.Errorf("the requester saw %d notification(s) addressed to the host", len(guestNotifications))
	}
}

// The list window and the retention window are the same constant on purpose
// — a row older than retention is already being swept, so promising it in
// the list would make notifications vanish mid-scroll.
func TestListNotifications_ExcludesRowsPastRetention_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")
	// A notification row is only written when the recipient has a device
	// registered — queueNotification no-ops on an empty token set. The app
	// registers one at sign-in.
	if err := h.deviceTokens.Upsert(ctx, host, "device-"+host); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	// Age the row past the retention window the sweeper uses.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.notification_outbox
		SET created_at = now() - $1::interval
		WHERE user_id = $2`,
		(notification.ProcessedRetention + time.Hour).String(), host,
	); err != nil {
		t.Fatalf("age notification: %v", err)
	}

	got, err := h.svc.ListNotifications(ctx, host)
	if err != nil {
		t.Fatalf("ListNotifications: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("saw %d notification(s) older than retention, want none", len(got))
	}
}

// A dead-lettered row was never delivered to anyone. Showing it would tell
// the user about a notification they did not get.
func TestListNotifications_ExcludesDeadLettered_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")
	// A notification row is only written when the recipient has a device
	// registered — queueNotification no-ops on an empty token set. The app
	// registers one at sign-in.
	if err := h.deviceTokens.Upsert(ctx, host, "device-"+host); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.notification_outbox SET dead_lettered_at = now() WHERE user_id = $1`, host,
	); err != nil {
		t.Fatalf("dead-letter notification: %v", err)
	}

	got, err := h.svc.ListNotifications(ctx, host)
	if err != nil {
		t.Fatalf("ListNotifications: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("saw %d dead-lettered notification(s), want none", len(got))
	}
}
