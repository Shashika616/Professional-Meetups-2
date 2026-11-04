package db_test

// Tracker #101 (review N1-B2): migration 0019 replaced
// UNIQUE (meetup_id, requester_id, status) with a partial unique index over
// the live states. The old key allowed one 'pending' AND one 'accepted' row
// for the same person on the same meetup, so a production database can hold
// exactly the pair the new index refuses. This brings a scratch database up
// to 0018, seeds that shape, and migrates through 0019.

import (
	"context"
	"database/sql"
	"net/url"
	"testing"

	"github.com/golang-migrate/migrate/v4"
	migratepostgres "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"github.com/jackc/pgx/v5"
)

// scratchDatabase creates an empty database of its own: this test migrates
// down to an old version, which the shared test database must never be.
func scratchDatabase(t *testing.T, name string) string {
	t.Helper()
	ctx := context.Background()
	base := requirePostgres(t)
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	quoted := pgx.Identifier{name}.Sanitize()
	drop := func() {
		if _, err := admin.Exec(ctx, "DROP DATABASE IF EXISTS "+quoted+" WITH (FORCE)"); err != nil {
			t.Errorf("drop %s: %v", name, err)
		}
	}
	drop()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quoted); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		drop()
		_ = admin.Close(ctx)
	})
	parsed, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	parsed.Path = "/" + name
	return parsed.String()
}

func migrateTo(t *testing.T, databaseURL string, version uint) {
	t.Helper()
	sqlDB, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sqlDB.Close() }()
	driver, err := migratepostgres.WithInstance(sqlDB, &migratepostgres.Config{})
	if err != nil {
		t.Fatal(err)
	}
	m, err := migrate.NewWithDatabaseInstance("file://../../../migrations", "postgres", driver)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Migrate(version); err != nil && err != migrate.ErrNoChange {
		t.Fatalf("migrate to %d: %v", version, err)
	}
}

func TestMigration0019CleansUpAPendingRowBesideAnAcceptedOne_Integration(t *testing.T) {
	ctx := context.Background()
	dbURL := scratchDatabase(t, "monolith_db_migration_0019_test")
	migrateTo(t, dbURL, 18)

	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()

	const (
		meetup    = "00000000-0000-0000-0000-0000000000a1"
		other     = "00000000-0000-0000-0000-0000000000a2"
		host      = "00000000-0000-0000-0000-0000000000b1"
		person    = "00000000-0000-0000-0000-0000000000c1"
		bystand   = "00000000-0000-0000-0000-0000000000c2"
		accepted  = "00000000-0000-0000-0000-0000000000d1"
		dupe      = "00000000-0000-0000-0000-0000000000d2"
		history   = "00000000-0000-0000-0000-0000000000d3"
		alone     = "00000000-0000-0000-0000-0000000000d4"
		elsewhere = "00000000-0000-0000-0000-0000000000d5"
	)
	for _, id := range []string{meetup, other} {
		if _, err := conn.Exec(ctx, `
			INSERT INTO meetup.meetups (id, host_user_id, intent, location_lat, location_lng, location_label,
			                            capacity, window_start, window_end)
			VALUES ($1, $2, 'coffee', 6.9271, 79.8612, 'Colombo', 4, now(), now() + interval '2 hours')`,
			id, host); err != nil {
			t.Fatal(err)
		}
	}
	// The shape the old key allowed and the new index refuses: the same
	// person accepted AND pending on one meetup, plus an earlier withdrawal
	// (so turning the pending row into 'withdrawn' would also have collided
	// with the old key, had it still been in force). Then rows that must not
	// change: another person's lone pending request, and this person's
	// pending request on a different meetup.
	for _, r := range []struct{ id, meetup, requester, status string }{
		{accepted, meetup, person, "accepted"},
		{dupe, meetup, person, "pending"},
		{history, meetup, person, "withdrawn"},
		{alone, meetup, bystand, "pending"},
		{elsewhere, other, person, "pending"},
	} {
		if _, err := conn.Exec(ctx, `
			INSERT INTO meetup.meetup_requests (id, meetup_id, requester_id, status)
			VALUES ($1, $2, $3, $4)`, r.id, r.meetup, r.requester, r.status); err != nil {
			t.Fatalf("seed %s: %v", r.status, err)
		}
	}

	migrateTo(t, dbURL, 19)

	want := map[string]string{
		accepted:  "accepted",
		dupe:      "withdrawn",
		history:   "withdrawn",
		alone:     "pending",
		elsewhere: "pending",
	}
	for id, status := range want {
		var got string
		var resolved bool
		if err := conn.QueryRow(ctx,
			`SELECT status::text, resolved_at IS NOT NULL FROM meetup.meetup_requests WHERE id = $1`, id,
		).Scan(&got, &resolved); err != nil {
			t.Fatal(err)
		}
		if got != status {
			t.Errorf("request %s: status %q, want %q", id, got, status)
		}
		if id == dupe && !resolved {
			t.Error("the withdrawn duplicate has no resolved_at")
		}
	}

	// And the new rule holds from here on: a second live row is refused.
	if _, err := conn.Exec(ctx, `
		INSERT INTO meetup.meetup_requests (meetup_id, requester_id, status)
		VALUES ($1, $2, 'pending')`, meetup, person); err == nil {
		t.Error("a pending request beside an accepted one was accepted after 0019")
	}

	// The down migration still refuses while duplicate history exists
	// (two 'withdrawn' rows for the same person), as it says it does.
	sqlDB, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sqlDB.Close() }()
	driver, err := migratepostgres.WithInstance(sqlDB, &migratepostgres.Config{})
	if err != nil {
		t.Fatal(err)
	}
	m, err := migrate.NewWithDatabaseInstance("file://../../../migrations", "postgres", driver)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Migrate(18); err == nil {
		t.Error("0019 down ran although the old constraint cannot hold two withdrawn rows")
	}
}

// Plan 30C, 0036: contacts become a name and an E.164 number, and everyone
// is active. Seeds what production can hold at 0035.
func TestMigration0036ReshapesTrustedContacts_Integration(t *testing.T) {
	ctx := context.Background()
	dbURL := scratchDatabase(t, "monolith_db_migration_0036_test")
	migrateTo(t, dbURL, 35)
	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()

	const user = "00000000-0000-0000-0000-0000000000e1"
	seed := []struct{ id, phone, email, age string }{
		{"00000000-0000-0000-0000-0000000000f1", "077 123 4567", "a@b.com", "5 days"}, // local, spaced
		{"00000000-0000-0000-0000-0000000000f2", "+94771234567", "", "4 days"},        // the same number: goes
		{"00000000-0000-0000-0000-0000000000f3", "+94 77 765 4321", "", "3 days"},     // pending: becomes active
		{"00000000-0000-0000-0000-0000000000f4", "+94770000000", "", "2 days"},        // a third contact: stays
	}
	for _, c := range seed {
		if _, err := conn.Exec(ctx, `INSERT INTO auth.trusted_contacts (id, user_id, name, phone_number, email, created_at)
			VALUES ($1, $2, 'Contact', $3, NULLIF($4, ''), now() - $5::interval)`, c.id, user, c.phone, c.email, c.age); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := conn.Exec(ctx, `INSERT INTO auth.trusted_contacts (user_id, name, email) VALUES ($1, 'Email only', 'x@y.com')`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `INSERT INTO auth.pending_trusted_contacts (contact_id, token_hash, expires_at)
		VALUES ('00000000-0000-0000-0000-0000000000f3', 'h', now() + interval '1 day')`); err != nil {
		t.Fatal(err)
	}

	migrateTo(t, dbURL, 36)

	rows, err := conn.Query(ctx, `SELECT phone_number FROM auth.trusted_contacts ORDER BY created_at`)
	if err != nil {
		t.Fatal(err)
	}
	phones, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"+94771234567", "+94777654321", "+94770000000"}
	if len(phones) != len(want) {
		t.Fatalf("contacts %v, want %v", phones, want)
	}
	for i := range want {
		if phones[i] != want[i] {
			t.Errorf("contact %d: %s, want %s", i, phones[i], want[i])
		}
	}
	for _, gone := range []string{"auth.pending_trusted_contacts", "auth.contact_invites_sent"} {
		var exists bool
		_ = conn.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, gone).Scan(&exists)
		if exists {
			t.Errorf("%s is still there", gone)
		}
	}
	if _, err := conn.Exec(ctx, `SELECT email FROM auth.trusted_contacts`); err == nil {
		t.Error("the email column is still there")
	}
	if _, err := conn.Exec(ctx, `INSERT INTO auth.trusted_contacts (user_id, name, phone_number, phone_normalized)
		VALUES ($1, 'Dupe', '+94770000000', '+94770000000')`, user); err == nil {
		t.Error("the same number was accepted twice for one user")
	}
	migrateTo(t, dbURL, 35) // the down migration restores the shape
}

// Plan 30D, 0037: photos sit in the database, capped at the stored size.
func TestMigration0037PhotosRoundTrip_Integration(t *testing.T) {
	ctx := context.Background()
	dbURL := scratchDatabase(t, "monolith_db_migration_0037_test")
	migrateTo(t, dbURL, 37)
	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()

	var user string
	if err := conn.QueryRow(ctx, `INSERT INTO auth.users (full_name) VALUES ('Ada') RETURNING id::text`).Scan(&user); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `INSERT INTO auth.user_photos (user_id, jpeg, etag, width, height, bytes)
		VALUES ($1, '\xff'::bytea, 'e', 320, 320, 102401)`, user); err == nil {
		t.Error("a photo over 100 KB was stored")
	}
	if _, err := conn.Exec(ctx, `INSERT INTO auth.user_photos (user_id, jpeg, etag, width, height, bytes)
		VALUES ($1, '\xff'::bytea, 'e', 320, 320, 1)`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `DELETE FROM auth.users WHERE id = $1`, user); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM auth.user_photos`).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("%d photos outlived their account", left)
	}
	migrateTo(t, dbURL, 36)
	migrateTo(t, dbURL, 37)
}
