package meetup_test

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
)

// The meetup module's side of account deletion, against real Postgres.
//
// The rule it proves: a user-deleted event removes only what the deleted
// person owns or wrote, and never what merely mentions them. Their requests,
// shares, checklist state, write-ups, device tokens and cached copies of their
// auth data go. Ratings (in both directions), meetups they hosted, and every
// row another member wrote stay. A meetup they still host is CANCELLED, so the
// people attending hear about it, never deleted and never left hostless.

func count(t *testing.T, pool *pgxpool.Pool, query string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func execSQL(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func insertMeetup(t *testing.T, pool *pgxpool.Pool, host, status string, start, end time.Time) string {
	t.Helper()
	var id string
	err := pool.QueryRow(context.Background(), `
		INSERT INTO meetup.meetups
		  (host_user_id, intent, location_lat, location_lng, location_label,
		   capacity, window_start, window_end, status)
		VALUES ($1, 'coffee', 6.9271, 79.8612, 'Galle Face Green', 4, $2, $3, $4)
		RETURNING id::text`, host, start, end, status).Scan(&id)
	if err != nil {
		t.Fatalf("insert meetup: %v", err)
	}
	return id
}

func TestHandleUserDeleted_RemovesOnlyWhatTheAccountOwns(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	ada := newUUID(t)   // the account being deleted
	grace := newUUID(t) // everybody else

	now := time.Now().UTC()
	past := insertMeetup(t, h.pool, ada, "completed", now.Add(-48*time.Hour), now.Add(-47*time.Hour))
	gracesLive := insertMeetup(t, h.pool, grace, "open", now.Add(48*time.Hour), now.Add(49*time.Hour))

	// Ada's own rows.
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_requests (meetup_id, requester_id, status) VALUES ($1, $2, 'pending')`, gracesLive, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.safety_state (meetup_id, user_id) VALUES ($1, $2)`, past, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened) VALUES ($1, $2, true)`, past, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.safety_share (meetup_id, user_id, contact_id) VALUES ($1, $2, gen_random_uuid())`, past, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.device_tokens (user_id, fcm_token) VALUES ($1, 'tok-ada')`, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.user_display_cache (user_id, full_name, trust_level) VALUES ($1, 'Ada Lovelace', 1)`, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.user_location_cache (user_id, lat, lng) VALUES ($1, 6.9, 79.8)`, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.subscription_cache (user_id, tier, entitled) VALUES ($1, 'premium', true)`, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.notification_outbox (user_id, fcm_tokens, title, body) VALUES ($1, ARRAY['tok-ada'], 'Hi', 'A push to Ada')`, ada)
	execSQL(t, h.pool, `INSERT INTO meetup.notification_outbox (user_id, fcm_tokens, title, body) VALUES ($1, ARRAY['tok-grace'], 'Hi', 'A push to Grace')`, grace)

	// Grace's rows, several of which are ABOUT Ada or sit on Ada's meetup.
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_requests (meetup_id, requester_id, status) VALUES ($1, $2, 'accepted')`, past, grace)
	execSQL(t, h.pool, `INSERT INTO meetup.safety_state (meetup_id, user_id) VALUES ($1, $2)`, past, grace)
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, notes) VALUES ($1, $2, true, 'Ada was lovely')`, past, grace)
	execSQL(t, h.pool, `INSERT INTO meetup.device_tokens (user_id, fcm_token) VALUES ($1, 'tok-grace')`, grace)
	execSQL(t, h.pool, `INSERT INTO meetup.user_display_cache (user_id, full_name, trust_level) VALUES ($1, 'Grace Hopper', 1)`, grace)

	// Ratings in both directions on Ada's past meetup.
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_user_ratings (meetup_id, rater_user_id, rated_user_id, score) VALUES ($1, $2, $3, 5)`, past, ada, grace)
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_user_ratings (meetup_id, rater_user_id, rated_user_id, score) VALUES ($1, $2, $3, 4)`, past, grace, ada)

	payload := eventbus.UserDeletedPayload{UserID: ada}
	if err := h.svc.HandleUserDeleted(ctx, payload); err != nil {
		t.Fatalf("HandleUserDeleted() error: %v", err)
	}

	// Gone: everything Ada owns.
	for _, c := range []struct{ what, query string }{
		{"her join requests", `SELECT count(*) FROM meetup.meetup_requests WHERE requester_id = $1`},
		{"her checklist state", `SELECT count(*) FROM meetup.safety_state WHERE user_id = $1`},
		{"her write-ups", `SELECT count(*) FROM meetup.meetup_feedback WHERE user_id = $1`},
		{"her contact shares", `SELECT count(*) FROM meetup.safety_share WHERE user_id = $1`},
		{"her device tokens", `SELECT count(*) FROM meetup.device_tokens WHERE user_id = $1`},
		{"her name and photo", `SELECT count(*) FROM meetup.user_display_cache WHERE user_id = $1`},
		{"her location", `SELECT count(*) FROM meetup.user_location_cache WHERE user_id = $1`},
		{"her subscription", `SELECT count(*) FROM meetup.subscription_cache WHERE user_id = $1`},
		{"pushes sent to her", `SELECT count(*) FROM meetup.notification_outbox WHERE user_id = $1`},
	} {
		if n := count(t, h.pool, c.query, ada); n != 0 {
			t.Errorf("%s: %d row(s) remain, want 0", c.what, n)
		}
	}

	// Kept, but ANONYMISED: the meetup she hosted, which is Grace's history
	// too. It still exists; it just no longer names Ada as its host.
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetups WHERE id = $1`, past); n != 1 {
		t.Error("the past meetup she hosted was deleted, taking other attendees' history with it")
	}
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetups WHERE host_user_id = $1`, ada); n != 0 {
		t.Errorf("%d meetup(s) still name the deleted account as host", n)
	}

	// Ratings: both rows survive, neither points at Ada any more, and
	// Grace's side of each is exactly as it was.
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetup_user_ratings`); n != 2 {
		t.Errorf("ratings = %d, want 2: ratings are part of other members' records and must survive", n)
	}
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetup_user_ratings WHERE rater_user_id = $1 OR rated_user_id = $1`, ada); n != 0 {
		t.Errorf("%d rating(s) still point at the deleted account: kept ratings must be anonymised", n)
	}
	// Grace's reputation: the 5 Ada gave her still counts toward her average.
	var graceAvg float64
	if err := h.pool.QueryRow(ctx, `SELECT avg(score) FROM meetup.meetup_user_ratings WHERE rated_user_id = $1`, grace).Scan(&graceAvg); err != nil {
		t.Fatalf("read Grace's average: %v", err)
	}
	if graceAvg != 5 {
		t.Errorf("Grace's average = %v, want 5: a departing member must not change anyone else's rating", graceAvg)
	}
	// The rating Grace wrote is still hers.
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetup_user_ratings WHERE rater_user_id = $1 AND score = 4`, grace); n != 1 {
		t.Error("the rating Grace wrote is no longer attributed to her")
	}
	// Per-row random ids: the two anonymised values are distinct, so the
	// rows cannot be grouped back together as one person's.
	if n := count(t, h.pool, `
		SELECT count(DISTINCT anon) FROM (
		  SELECT rater_user_id AS anon FROM meetup.meetup_user_ratings WHERE rater_user_id <> $1
		  UNION ALL
		  SELECT rated_user_id FROM meetup.meetup_user_ratings WHERE rated_user_id <> $1
		) ids`, grace); n != 2 {
		t.Errorf("distinct anonymised ids = %d, want 2 (one fresh id per row)", n)
	}
	// Kept: everything Grace owns, including what is about Ada or on Ada's meetup.
	for _, c := range []struct{ what, query string }{
		{"Grace's request on Ada's meetup", `SELECT count(*) FROM meetup.meetup_requests WHERE requester_id = $1`},
		{"Grace's checklist state", `SELECT count(*) FROM meetup.safety_state WHERE user_id = $1`},
		{"Grace's write-up that mentions Ada", `SELECT count(*) FROM meetup.meetup_feedback WHERE user_id = $1`},
		{"Grace's device token", `SELECT count(*) FROM meetup.device_tokens WHERE user_id = $1`},
		{"Grace's name and photo", `SELECT count(*) FROM meetup.user_display_cache WHERE user_id = $1`},
		{"pushes sent to Grace", `SELECT count(*) FROM meetup.notification_outbox WHERE user_id = $1`},
	} {
		if n := count(t, h.pool, c.query, grace); n != 1 {
			t.Errorf("%s: %d row(s), want 1: another member's data was touched", c.what, n)
		}
	}

	// A second delivery is harmless: the outbox is at-least-once.
	if err := h.svc.HandleUserDeleted(ctx, payload); err != nil {
		t.Fatalf("second HandleUserDeleted() error: %v, delivery must be idempotent", err)
	}
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetup_user_ratings`); n != 2 {
		t.Errorf("ratings after a repeat delivery = %d, want 2", n)
	}
}

// TestHandleUserDeleted_CancelsALiveMeetupTheyStillHost covers the meetup
// created in the gap between the gateway's check and the delete. It must be
// cancelled through the ordinary path, which tells the people attending, and
// must not be deleted (that would cascade away their requests) or left open
// with a host who no longer exists.
func TestHandleUserDeleted_CancelsALiveMeetupTheyStillHost(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	ada := newUUID(t)
	grace := newUUID(t)
	now := time.Now().UTC()
	live := insertMeetup(t, h.pool, ada, "open", now.Add(24*time.Hour), now.Add(25*time.Hour))
	execSQL(t, h.pool, `INSERT INTO meetup.meetup_requests (meetup_id, requester_id, status) VALUES ($1, $2, 'accepted')`, live, grace)
	// A push can only be queued for someone with a device to send it to;
	// queueNotifications skips everyone else, deliberately.
	execSQL(t, h.pool, `INSERT INTO meetup.device_tokens (user_id, fcm_token) VALUES ($1, 'tok-grace')`, grace)

	if err := h.svc.HandleUserDeleted(ctx, eventbus.UserDeletedPayload{UserID: ada}); err != nil {
		t.Fatalf("HandleUserDeleted() error: %v", err)
	}

	var status, reason string
	if err := h.pool.QueryRow(ctx, `SELECT status::text, coalesce(cancellation_reason, '') FROM meetup.meetups WHERE id = $1`, live).Scan(&status, &reason); err != nil {
		t.Fatalf("read meetup: %v (it must still exist, cancelled, not deleted)", err)
	}
	if status != "cancelled" {
		t.Errorf("status = %q, want cancelled", status)
	}
	if reason == "" {
		t.Error("cancelled with no reason: the attendee is owed an explanation")
	}
	// Grace's accepted request survives, so her history shows a cancellation.
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.meetup_requests WHERE requester_id = $1`, grace); n != 1 {
		t.Error("the attendee's request was removed along with the host")
	}
	// And she is told, through the same outbox every other cancellation uses.
	if n := count(t, h.pool, `SELECT count(*) FROM meetup.notification_outbox WHERE user_id = $1`, grace); n == 0 {
		t.Error("the attendee was not notified that the meetup was cancelled")
	}

	// Repeat delivery: already cancelled, still no error.
	if err := h.svc.HandleUserDeleted(ctx, eventbus.UserDeletedPayload{UserID: ada}); err != nil {
		t.Fatalf("second HandleUserDeleted() error: %v", err)
	}
}

// TestHandleUserDeleted_NothingToDeleteIsNotAnError: most accounts never
// host, join or share anything, and most trusted contacts are not users.
// A deletion with nothing on this side is the common case, not an error.
func TestHandleUserDeleted_NothingToDeleteIsNotAnError(t *testing.T) {
	h := newHarness(t)
	if err := h.svc.HandleUserDeleted(context.Background(), eventbus.UserDeletedPayload{UserID: newUUID(t)}); err != nil {
		t.Fatalf("HandleUserDeleted() error: %v for an account with no meetup data", err)
	}
}
