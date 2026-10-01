package auth_test

import (
	"context"
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Account deletion against real Postgres. The unit tests prove the service's
// decisions; these prove the SQL: that one delete removes every row this
// account owns across six tables, touches nothing anybody else owns, announces
// itself in the same transaction, and is safe to repeat.

func countRows(t *testing.T, pool *pgxpool.Pool, query string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func seedUser(t *testing.T, pool *pgxpool.Pool, name string) string {
	t.Helper()
	var id string
	err := pool.QueryRow(context.Background(), `
		INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18)
		VALUES ($1, 1, true) RETURNING id::text`, name).Scan(&id)
	if err != nil {
		t.Fatalf("seed user %q: %v", name, err)
	}
	return id
}

func mustExec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func TestDeleteUser_RemovesOnlyTheAccountsOwnRowsAndAnnouncesIt(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))

	ada := seedUser(t, h.pool, "Ada Lovelace")
	grace := seedUser(t, h.pool, "Grace Hopper")
	mustExec(t, h.pool, `UPDATE auth.users SET legal_name = 'Augusta Ada King', phone_number = '+94770000001', personal_email = 'ada@example.com', address = '1 Engine Lane' WHERE id = $1`, ada)

	// Everything Ada owns, one row in each table the delete must reach: the
	// four that cascade from auth.users and the two that do not.
	mustExec(t, h.pool, `INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, 'h-ada', now() + interval '1 day')`, ada)
	mustExec(t, h.pool, `INSERT INTO auth.verification_codes (user_id, purpose, target, code_hash, expires_at) VALUES ($1, 'phone', '+94770000001', 'c', now() + interval '5 minutes')`, ada)
	mustExec(t, h.pool, `INSERT INTO auth.user_identities (user_id, provider, subject, email) VALUES ($1, 'apple', 'apple-sub-ada', 'ada@example.com')`, ada)
	mustExec(t, h.pool, `INSERT INTO auth.unverified_company_claims (user_id, company_name_entered, domain) VALUES ($1, 'Analytical Engines', 'engines.example')`, ada)
	// Ada's emergency contact is not a user of the app at all, which is the
	// normal case. It is still Ada's data and goes with her.
	mustExec(t, h.pool, `INSERT INTO auth.trusted_contacts (user_id, name, phone_number) VALUES ($1, 'Mum', '+94770000002')`, ada)
	mustExec(t, h.pool, `INSERT INTO auth.sos_events (user_id, context_message, latitude, longitude, contacts_notified) VALUES ($1, 'help', 6.9, 79.8, 1)`, ada)

	// Grace lists ADA as HER emergency contact, by Ada's own name and number.
	// That row is Grace's address book, not Ada's data, and must survive
	// Ada's deletion untouched — as must everything else Grace owns.
	mustExec(t, h.pool, `INSERT INTO auth.trusted_contacts (user_id, name, phone_number) VALUES ($1, 'Ada Lovelace', '+94770000001')`, grace)
	mustExec(t, h.pool, `INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, 'h-grace', now() + interval '1 day')`, grace)
	mustExec(t, h.pool, `INSERT INTO auth.sos_events (user_id, context_message, latitude, longitude, contacts_notified) VALUES ($1, 'fine', 6.9, 79.8, 1)`, grace)

	if err := repo.Delete(ctx, ada); err != nil {
		t.Fatalf("Delete() error: %v", err)
	}

	for _, table := range []string{
		"auth.refresh_tokens", "auth.verification_codes", "auth.user_identities",
		"auth.unverified_company_claims", "auth.trusted_contacts", "auth.sos_events",
	} {
		if n := countRows(t, h.pool, "SELECT count(*) FROM "+table+" WHERE user_id = $1", ada); n != 0 {
			t.Errorf("%s still holds %d row(s) for the deleted account", table, n)
		}
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.users WHERE id = $1", ada); n != 0 {
		t.Error("the auth.users row still exists")
	}

	// Nothing of Grace's was touched, including the entry that names Ada.
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.users WHERE id = $1", grace); n != 1 {
		t.Error("another member's account was deleted")
	}
	if n := countRows(t, h.pool, `SELECT count(*) FROM auth.trusted_contacts WHERE user_id = $1 AND name = 'Ada Lovelace'`, grace); n != 1 {
		t.Error("another member's emergency contact was deleted because it named the deleted account")
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.refresh_tokens WHERE user_id = $1", grace); n != 1 {
		t.Error("another member's session was revoked")
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.sos_events WHERE user_id = $1", grace); n != 1 {
		t.Error("another member's SOS history was deleted")
	}

	// Announced exactly once, in the same transaction, carrying only the id.
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.user_deleted_outbox WHERE user_id = $1 AND processed_at IS NULL", ada); n != 1 {
		t.Errorf("user-deleted outbox rows = %d, want exactly 1 pending", n)
	}

	// Ada triggered SOS, so her record went into a safety hold: who she was
	// and what happened, nothing else, and set to purge itself in 90 days.
	var name, legal, phone, email string
	var events int
	var days float64
	err := h.pool.QueryRow(ctx, `
		SELECT full_name, legal_name, phone_number, personal_email,
		       jsonb_array_length(sos_events),
		       extract(epoch FROM purge_after - held_at) / 86400
		FROM auth.safety_holds WHERE deleted_user_id = $1`, ada).
		Scan(&name, &legal, &phone, &email, &events, &days)
	if err != nil {
		t.Fatalf("read safety hold: %v (an account with SOS events must get one)", err)
	}
	if name != "Ada Lovelace" || legal != "Augusta Ada King" || phone != "+94770000001" || email != "ada@example.com" {
		t.Errorf("hold identity = %q %q %q %q, want the account's own", name, legal, phone, email)
	}
	if events != 1 {
		t.Errorf("hold holds %d SOS events, want 1", events)
	}
	if days < 89.9 || days > 90.1 {
		t.Errorf("hold lasts %.2f days, want 90", days)
	}
	// Minimal by construction: the hold has no column for anything else,
	// the address for example, so it cannot keep it.
	if n := countRows(t, h.pool, `SELECT count(*) FROM information_schema.columns WHERE table_schema = 'auth' AND table_name = 'safety_holds' AND column_name IN ('address', 'profile_photo_url', 'last_known_location')`); n != 0 {
		t.Errorf("the safety hold has %d column(s) for data it has no reason to keep", n)
	}
	// Grace was not deleted, so nothing of hers is held.
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.safety_holds WHERE deleted_user_id = $1", grace); n != 0 {
		t.Error("a safety hold exists for an account that was not deleted")
	}
}

// TestDeleteUser_NoSOSMeansNoHold: holding data about everyone "in case" is
// exactly what data-protection law forbids. The hold exists only where there
// is a reason, and for most accounts there is none.
func TestDeleteUser_NoSOSMeansNoHold(t *testing.T) {
	h := newHarness(t)
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))
	ada := seedUser(t, h.pool, "Ada Lovelace")
	mustExec(t, h.pool, `INSERT INTO auth.trusted_contacts (user_id, name, phone_number) VALUES ($1, 'Mum', '+94770000002')`, ada)

	if err := repo.Delete(context.Background(), ada); err != nil {
		t.Fatalf("Delete() error: %v", err)
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.safety_holds"); n != 0 {
		t.Errorf("safety holds = %d for an account that never triggered SOS, want 0", n)
	}
}

// TestDeleteExpiredSafetyHolds_PurgesOnlyExpiredHolds: the privacy policy
// promises the hold is gone after 90 days, and a hold still inside its window
// must not be touched.
func TestDeleteExpiredSafetyHolds_PurgesOnlyExpiredHolds(t *testing.T) {
	h := newHarness(t)
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))
	mustExec(t, h.pool, `INSERT INTO auth.safety_holds (deleted_user_id, full_name, sos_events, purge_after) VALUES (gen_random_uuid(), 'Expired', '[]', now() - interval '1 minute')`)
	mustExec(t, h.pool, `INSERT INTO auth.safety_holds (deleted_user_id, full_name, sos_events, purge_after) VALUES (gen_random_uuid(), 'Still held', '[]', now() + interval '30 days')`)

	purged, err := repo.DeleteExpiredSafetyHolds(context.Background(), 100)
	if err != nil {
		t.Fatalf("DeleteExpiredSafetyHolds() error: %v", err)
	}
	if purged != 1 {
		t.Errorf("purged = %d, want 1", purged)
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.safety_holds WHERE full_name = 'Still held'"); n != 1 {
		t.Error("a hold still inside its window was purged")
	}
}

// TestDeleteAbandonedGuests_AnnouncesEveryDeletion: guest cleanup is a second
// way an account is deleted, and it used to be a silent one: the meetup
// module was never told and kept each guest's cached name, location and
// device tokens forever. It now announces each guest it removes, in the same
// statement as the delete.
func TestDeleteAbandonedGuests_AnnouncesEveryDeletion(t *testing.T) {
	h := newHarness(t)
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))
	var guest string
	if err := h.pool.QueryRow(context.Background(), `
		INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18, is_guest, updated_at)
		VALUES ('Guest-JollyRaven1468', 0, true, true, now() - interval '400 days')
		RETURNING id::text`).Scan(&guest); err != nil {
		t.Fatalf("seed guest: %v", err)
	}

	deleted, err := repo.DeleteAbandonedGuests(context.Background(), 24*time.Hour, 100)
	if err != nil {
		t.Fatalf("DeleteAbandonedGuests() error: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted = %d, want 1", deleted)
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.user_deleted_outbox WHERE user_id = $1", guest); n != 1 {
		t.Errorf("user-deleted rows for the guest = %d, want 1: the meetup module must be told", n)
	}
}

// TestDeleteUser_SecondDeleteIsNotFoundAndAnnouncesNothing: the repository
// must know when there was nothing to delete, or a retry would commit a
// second user-deleted event for an account already announced.
func TestDeleteUser_SecondDeleteIsNotFoundAndAnnouncesNothing(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))
	ada := seedUser(t, h.pool, "Ada Lovelace")

	if err := repo.Delete(ctx, ada); err != nil {
		t.Fatalf("first Delete() error: %v", err)
	}
	err := repo.Delete(ctx, ada)
	if !errors.Is(err, apperror.ErrNotFound) {
		t.Fatalf("second Delete() error = %v, want apperror.ErrNotFound", err)
	}
	if n := countRows(t, h.pool, "SELECT count(*) FROM auth.user_deleted_outbox WHERE user_id = $1", ada); n != 1 {
		t.Errorf("outbox rows = %d after a repeated delete, want still exactly 1", n)
	}
}

// TestDeleteUser_OutboxIsDrainedByTheGenericStore closes the loop the
// meetup module depends on: the row written in the delete transaction is
// what the poller's store hands out, carrying the right id.
func TestDeleteUser_OutboxIsDrainedByTheGenericStore(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	repo := repository.NewUserRepository(h.pool, h.bus, slog.New(slog.DiscardHandler))
	store := repository.NewUserDeletedOutboxRepository(h.pool)
	ada := seedUser(t, h.pool, "Ada Lovelace")

	if err := repo.Delete(ctx, ada); err != nil {
		t.Fatalf("Delete() error: %v", err)
	}
	rows, err := store.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch() error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("claimed %d rows, want 1", len(rows))
	}
	if want := `{"user_id":"` + ada + `"}`; string(rows[0].Payload) != want {
		t.Errorf("payload = %s, want %s", rows[0].Payload, want)
	}
	if err := store.MarkProcessed(ctx, rows[0].ID); err != nil {
		t.Fatalf("MarkProcessed() error: %v", err)
	}
	if n, err := store.CountPending(ctx); err != nil || n != 0 {
		t.Errorf("pending after processing = %d (err %v), want 0", n, err)
	}
}
