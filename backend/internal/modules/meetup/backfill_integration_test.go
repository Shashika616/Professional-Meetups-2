package meetup_test

// §C3: the backfill CLIs, exercised as real processes against real Postgres.
//
// `go run` rather than calling an extracted function: a backfill tool's most
// likely failure mode is not a wrong SQL predicate but a wrong environment
// variable, a bad flag, or a build that has drifted — none of which a unit
// test of an internal function would catch. These run the commands the way an
// operator would.

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// backendDir is this package's path relative to the module root, inverted —
// tests run with cwd set to the package directory, and `go run ./cmd/...`
// needs the module root.
const backendDir = "../../.."

func runBackfill(t *testing.T, _ *harness, command string, args ...string) string {
	t.Helper()
	cmd := exec.Command("go", append([]string{"run", "./cmd/" + command}, args...)...)
	cmd.Dir = backendDir
	cmd.Env = append(cmd.Environ(), "DATABASE_URL="+requirePostgres(t))

	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s failed: %v\n%s", command, err, out)
	}
	return string(out)
}

// TestBackfillUserDisplayCache_FillsGapsAndNeverRegresses_Integration is the
// tool's whole reason for existing, plus the guarantee that makes it safe to
// run on a live system.
//
// The second half is the one that matters most: the source's version of this
// command wrote `updated_at = now()` with an unconditional DO UPDATE, so
// running it while the app was live could overwrite a cache row that a newer
// profile-update event had already applied — silently reverting a user's
// just-changed name. This port carries the ordering guard, and this test is
// what pins that.
func TestBackfillUserDisplayCache_FillsGapsAndNeverRegresses_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// missing: authoritative in auth.users, absent from the cache — the
	// lost-event case the tool exists for.
	missing := seedAuthUser(t, h, "Gap User", 3, time.Now().Add(-time.Hour))
	// stale: in the cache with older data than auth.users — must be updated.
	stale := seedAuthUser(t, h, "Corrected Name", 4, time.Now())
	if _, err := h.userDisplayCache.Upsert(ctx, stale, "Old Name", "", 1, time.Now().Add(-24*time.Hour)); err != nil {
		t.Fatalf("seed stale cache row: %v", err)
	}
	// newer: the cache already holds data NEWER than auth.users, as it would
	// if a live event landed while the backfill was running. Must survive
	// untouched.
	newer := seedAuthUser(t, h, "Outdated In Auth", 2, time.Now().Add(-48*time.Hour))
	if _, err := h.userDisplayCache.Upsert(ctx, newer, "Freshly Updated Name", "", 5, time.Now()); err != nil {
		t.Fatalf("seed newer cache row: %v", err)
	}

	out := runBackfill(t, h, "backfill-user-display-cache")
	t.Logf("backfill output: %s", strings.TrimSpace(out))

	if got := displayCacheName(t, h, missing); got != "Gap User" {
		t.Errorf("missing user's cache name = %q, want %q — the backfill did not fill the gap it exists to fill", got, "Gap User")
	}
	if got := displayCacheName(t, h, stale); got != "Corrected Name" {
		t.Errorf("stale user's cache name = %q, want %q", got, "Corrected Name")
	}
	if got := displayCacheName(t, h, newer); got != "Freshly Updated Name" {
		t.Errorf("cache name = %q, want %q — the backfill REGRESSED a row that a newer live event had already applied, which is exactly what the ordering guard must prevent", got, "Freshly Updated Name")
	}
}

// TestBackfillUserDisplayCache_DryRunWritesNothing_Integration covers the
// flag an operator reaches for first when deciding whether to run this
// against production.
func TestBackfillUserDisplayCache_DryRunWritesNothing_Integration(t *testing.T) {
	h := newHarness(t)

	user := seedAuthUser(t, h, "Dry Run User", 3, time.Now())

	out := runBackfill(t, h, "backfill-user-display-cache", "--dry-run")
	if !strings.Contains(out, "DRY RUN") {
		t.Errorf("output does not identify itself as a dry run: %s", out)
	}
	if displayCacheName(t, h, user) != "" {
		t.Error("--dry-run wrote to the cache")
	}
}

// TestBackfillUserLocationCache_SeedsOnlyUsersWithALocation_Integration
// covers the sibling command, including its one selection rule.
func TestBackfillUserLocationCache_SeedsOnlyUsersWithALocation_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	withLocation := seedAuthUser(t, h, "Located User", 3, time.Now())
	if _, err := h.pool.Exec(ctx, `
		UPDATE auth.users
		SET last_location_lat = $2, last_location_lng = $3, last_location_updated_at = now() - interval '1 hour'
		WHERE id = $1`, withLocation, colomboLat, colomboLng); err != nil {
		t.Fatalf("seed location: %v", err)
	}
	// A user who has never had their location read has nothing to seed.
	withoutLocation := seedAuthUser(t, h, "Unlocated User", 3, time.Now())

	out := runBackfill(t, h, "backfill-user-location-cache")
	t.Logf("backfill output: %s", strings.TrimSpace(out))

	if !locationCached(t, h, withLocation) {
		t.Error("a user with a recorded location was not backfilled into the cache")
	}
	if locationCached(t, h, withoutLocation) {
		t.Error("a user with no recorded location was given a cache row")
	}

	// Same ordering guard as its sibling: a newer live event must survive.
	if _, err := h.userLocationCache.Upsert(ctx, withLocation, 1.0, 1.0, time.Now()); err != nil {
		t.Fatalf("apply newer live event: %v", err)
	}
	runBackfill(t, h, "backfill-user-location-cache")

	var lat float64
	if err := h.pool.QueryRow(ctx,
		`SELECT lat FROM meetup.user_location_cache WHERE user_id = $1`, withLocation).Scan(&lat); err != nil {
		t.Fatalf("read back location: %v", err)
	}
	if lat != 1.0 {
		t.Errorf("cached lat = %v, want 1.0 — the backfill regressed a row a newer live event had already applied", lat)
	}
}

// --- helpers ---------------------------------------------------------------

// seedAuthUser inserts an auth.users row directly. The backfill tools read
// that table as the authoritative source, so these tests need real rows in
// it — this is the one place in this package that writes to another module's
// schema, and it is a test fixture standing in for the auth module, not
// production code reaching across a boundary.
func seedAuthUser(t *testing.T, h *harness, fullName string, trustLevel int, updatedAt time.Time) string {
	t.Helper()
	var id string
	err := h.pool.QueryRow(context.Background(), `
		INSERT INTO auth.users (full_name, trust_level, age_confirmed_over_18, updated_at)
		VALUES ($1, $2, true, $3)
		RETURNING id::text`, fullName, trustLevel, updatedAt).Scan(&id)
	if err != nil {
		t.Fatalf("seed auth user: %v", err)
	}
	return id
}

func displayCacheName(t *testing.T, h *harness, userID string) string {
	t.Helper()
	var name string
	err := h.pool.QueryRow(context.Background(),
		`SELECT full_name FROM meetup.user_display_cache WHERE user_id = $1`, userID).Scan(&name)
	if err != nil {
		return "" // no row
	}
	return name
}

func locationCached(t *testing.T, h *harness, userID string) bool {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM meetup.user_location_cache WHERE user_id = $1`, userID).Scan(&n); err != nil {
		t.Fatalf("count location cache rows: %v", err)
	}
	return n > 0
}
