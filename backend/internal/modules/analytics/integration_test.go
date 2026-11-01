package analytics_test

// Integration tests: the analytics module against real Postgres and the real
// migrations. Partitioning, deduplication, opt-out and the aggregates are
// properties of the SQL, which no fake can stand in for.

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/analytics"
	"professional-meetups-monolith/backend/internal/modules/analytics/config"
	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/flags"
)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) Set(t time.Time) {
	c.mu.Lock()
	c.t = t
	c.mu.Unlock()
}

type fakeUploader struct {
	mu      sync.Mutex
	objects map[string][]byte
	fail    error
}

func (u *fakeUploader) Upload(_ context.Context, bucket, object string, body []byte, _ analytics.UploadOptions) error {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.fail != nil {
		return u.fail
	}
	u.objects[bucket+"/"+object] = append([]byte(nil), body...)
	return nil
}

type flagStub struct{ on bool }

func (f flagStub) Enabled(context.Context, string, flags.Subject) (bool, error) { return f.on, nil }

type harness struct {
	pool   *pgxpool.Pool
	store  *repository.Store
	clock  *clock
	upload *fakeUploader
	svc    *analytics.Service
	cancel context.CancelFunc
}

var base = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func requirePostgres(t *testing.T) string {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp", parsed.Host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping (run `docker compose up -d postgres`): %v", parsed.Host, err)
	}
	_ = conn.Close()
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatal(err)
	}
	return testURL
}

type option func(*analytics.Deps)

func newHarness(t *testing.T, opts ...option) *harness {
	t.Helper()
	dbURL := requirePostgres(t)
	if err := db.Migrate(dbURL, "file://../../../migrations"); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	release, err := db.AcquireIntegrationTestLock(ctx, pool)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)

	// A clean analytics schema: every partition dropped, every table empty.
	if _, err := pool.Exec(ctx, `
		DO $$ DECLARE d date; BEGIN
			FOR d IN SELECT day FROM analytics.partitions LOOP PERFORM analytics.drop_partition(d); END LOOP;
		END $$;
		TRUNCATE analytics.events, analytics.partitions, analytics.opt_outs, analytics.aggregate_runs,
			analytics.daily_screen_stats, analytics.daily_feature_stats, analytics.daily_funnel_stats,
			analytics.daily_session_stats, analytics.daily_error_stats, analytics.daily_credit_stats,
			analytics.user_first_seen, analytics.report_runs, analytics.user_activity_days,
			analytics.daily_abandon_stats, analytics.daily_credit_band_stats`); err != nil {
		t.Fatalf("reset: %v", err)
	}

	cfg, err := config.LoadFrom(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	cfg.ArchiveBucket = "tiehere-test-bucket"
	h := &harness{pool: pool, store: repository.New(pool), clock: &clock{t: base}, upload: &fakeUploader{objects: map[string][]byte{}}}
	deps := analytics.Deps{
		Store: h.store, Config: cfg, Archive: h.upload, Now: h.clock.Now,
		FlushEvery: time.Hour, // tests flush with Sync
	}
	for _, o := range opts {
		o(&deps)
	}
	h.svc = analytics.New(deps)
	runCtx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	go h.svc.Run(runCtx)
	t.Cleanup(func() { cancel(); <-h.svc.Done() })
	if _, err := h.svc.SweepPartitions(ctx); err != nil {
		t.Fatal(err)
	}
	return h
}

const installID = "4b0c8a1e-3f2d-4c5b-9a8e-7d6c5b4a3f21"

func ev(name, id string, attrs string) registry.Input {
	return registry.Input{
		EventID: id, Name: name, SchemaVersion: 1,
		OccurredAt: base.Add(-time.Minute).Format(time.RFC3339Nano), Attributes: json.RawMessage(attrs),
	}
}

func newID() string { u, _ := uuid.NewV7(); return u.String() }

func (h *harness) ingest(t *testing.T, userID string, events ...registry.Input) analytics.IngestResult {
	t.Helper()
	res, err := h.svc.Ingest(context.Background(), analytics.Batch{
		UserID:  userID,
		Context: analytics.Context{InstallID: installID, AppVersion: "1.1.0+7", OSName: "android", OSVersion: "15", DeviceClass: "phone", Locale: "en-LK"},
		Events:  events,
	})
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	return res
}

func (h *harness) sync() { h.svc.SyncForTest(context.Background()) }

func (h *harness) count(t *testing.T, where string, args ...any) int {
	t.Helper()
	var n int
	if err := h.pool.QueryRow(context.Background(), "SELECT count(*) FROM analytics.events WHERE "+where, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestAnEventIsStoredWithItsContext(t *testing.T) {
	h := newHarness(t)
	e := ev("screen_left", newID(), `{"duration_ms": 1200, "email": "x@y.z"}`)
	e.Screen = "home"
	res := h.ingest(t, "11111111-2222-3333-4444-555555555555", e)
	if res.Accepted != 1 || res.Dropped != 0 {
		t.Fatalf("res = %+v", res)
	}
	h.sync()
	var name, screen, appVersion, os, locale, userKey string
	var attrs []byte
	var day time.Time
	if err := h.pool.QueryRow(context.Background(), `
		SELECT event_name, screen, app_version, os_name, locale, user_key, attributes, received_day
		FROM analytics.events`).Scan(&name, &screen, &appVersion, &os, &locale, &userKey, &attrs, &day); err != nil {
		t.Fatal(err)
	}
	if name != "screen_left" || screen != "home" || appVersion != "1.1.0+7" || os != "android" || locale != "en-LK" {
		t.Errorf("stored %s %s %s %s %s", name, screen, appVersion, os, locale)
	}
	if len(userKey) != 64 || userKey == "11111111-2222-3333-4444-555555555555" {
		t.Errorf("user_key = %q, want a 64-character HMAC", userKey)
	}
	if string(attrs) != `{"duration_ms": 1200}` {
		t.Errorf("attributes = %s (the unknown email attribute must be gone)", attrs)
	}
	if !day.Equal(time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("received_day = %v", day)
	}
	var part string
	if err := h.pool.QueryRow(context.Background(), `SELECT tableoid::regclass::text FROM analytics.events`).Scan(&part); err != nil {
		t.Fatal(err)
	}
	if part != "analytics.events_20261025" {
		t.Errorf("stored in %s, want the day's partition", part)
	}
}

func TestADuplicateEventIDIsStoredOnce(t *testing.T) {
	h := newHarness(t)
	id := newID()
	// Twice in one batch, and again in a later batch (a retry).
	h.ingest(t, "", ev("screen_viewed", id, `{}`), ev("screen_viewed", id, `{}`))
	h.sync()
	h.ingest(t, "", ev("screen_viewed", id, `{}`))
	h.sync()
	if n := h.count(t, "event_id = $1", id); n != 1 {
		t.Errorf("stored %d times, want once", n)
	}
}

func TestIngestLimits(t *testing.T) {
	h := newHarness(t)
	var many []registry.Input
	for i := 0; i < 51; i++ {
		many = append(many, ev("screen_viewed", newID(), `{}`))
	}
	if _, err := h.svc.Ingest(context.Background(), analytics.Batch{Context: analytics.Context{InstallID: installID}, Events: many}); err == nil {
		t.Error("51 events accepted")
	}
	if _, err := h.svc.Ingest(context.Background(), analytics.Batch{Context: analytics.Context{InstallID: "Jane's phone"}}); err == nil {
		t.Error("a free-text install id accepted")
	}
	skewed := ev("screen_viewed", newID(), `{}`)
	skewed.OccurredAt = base.Add(-8 * 24 * time.Hour).Format(time.RFC3339)
	if res := h.ingest(t, "", skewed); res.Accepted != 0 || res.Dropped != 1 {
		t.Errorf("skewed event: %+v", res)
	}
}

func TestTheKillSwitchDropsEverything(t *testing.T) {
	off := newHarness(t, func(d *analytics.Deps) { d.Flags = flagStub{on: false} })
	if res := off.ingest(t, "", ev("screen_viewed", newID(), `{}`)); res.Accepted != 0 || res.Dropped != 1 {
		t.Errorf("with analytics.enabled off: %+v", res)
	}
	off.sync()
	if n := off.count(t, "true"); n != 0 {
		t.Errorf("stored %d events with the flag off", n)
	}
}

func TestTheAppCannotSendServerEvents(t *testing.T) {
	h := newHarness(t)
	res := h.ingest(t, "u1", ev("credits_granted", newID(), `{"credits": 1000, "reason": "grant"}`))
	if res.Accepted != 0 || res.Dropped != 1 {
		t.Errorf("res = %+v", res)
	}
}

func TestOptOutDeletesAndDrops(t *testing.T) {
	h := newHarness(t)
	const user = "aaaaaaaa-0000-0000-0000-000000000001"
	h.ingest(t, user, ev("screen_viewed", newID(), `{}`))
	h.ingest(t, "", ev("screen_viewed", newID(), `{}`))
	h.sync()
	if err := h.svc.SetConsent(context.Background(), user, true); err != nil {
		t.Fatal(err)
	}
	key := h.svc.UserKey(user)
	if n := h.count(t, "user_key = $1", key); n != 0 {
		t.Errorf("%d events kept after opting out", n)
	}
	if n := h.count(t, "user_key IS NULL"); n != 1 {
		t.Errorf("the anonymous event went too: %d left", n)
	}
	// Still sent (an old build, or a race with the toggle): dropped at flush.
	h.ingest(t, user, ev("screen_viewed", newID(), `{}`))
	h.svc.Record(context.Background(), analytics.ServerEvent{Source: "test:" + newID(), Name: "credits_spent", UserID: user,
		Attributes: map[string]any{"credits": 5, "reason": "capture"}})
	h.sync()
	if n := h.count(t, "user_key = $1", key); n != 0 {
		t.Errorf("%d events stored while opted out", n)
	}
	if err := h.svc.SetConsent(context.Background(), user, false); err != nil {
		t.Fatal(err)
	}
	h.ingest(t, user, ev("screen_viewed", newID(), `{}`))
	h.sync()
	if n := h.count(t, "user_key = $1", key); n != 1 {
		t.Errorf("after opting back in, %d stored, want 1", n)
	}
}

func TestUserDeletionRemovesTheirData(t *testing.T) {
	h := newHarness(t)
	const user = "bbbbbbbb-0000-0000-0000-000000000002"
	h.ingest(t, user, ev("screen_viewed", newID(), `{}`))
	h.ingest(t, "cccccccc-0000-0000-0000-000000000003", ev("screen_viewed", newID(), `{}`))
	h.sync()
	h.clock.Set(base.Add(24 * time.Hour))
	if _, err := h.svc.SweepAggregate(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Queued but not flushed when the deletion arrives: must not survive it.
	h.ingest(t, user, registry.Input{EventID: newID(), Name: "screen_viewed", SchemaVersion: 1,
		OccurredAt: base.Add(24 * time.Hour).Format(time.RFC3339)})
	if err := h.svc.HandleUserDeleted(context.Background(), eventbus.UserDeletedPayload{UserID: user}); err != nil {
		t.Fatal(err)
	}
	h.sync() // anything still queued would land now
	key := h.svc.UserKey(user)
	if n := h.count(t, "user_key = $1", key); n != 0 {
		t.Errorf("%d events kept after deletion", n)
	}
	var firstSeen int
	_ = h.pool.QueryRow(context.Background(), `SELECT count(*) FROM analytics.user_first_seen WHERE user_key = $1`, key).Scan(&firstSeen)
	if firstSeen != 0 {
		t.Error("the cohort row was kept")
	}
	var activity int
	_ = h.pool.QueryRow(context.Background(), `SELECT count(*) FROM analytics.user_activity_days WHERE user_key = $1`, key).Scan(&activity)
	if activity != 0 {
		t.Error("the activity days were kept")
	}
	if n := h.count(t, "user_key IS NOT NULL"); n != 1 {
		t.Errorf("the other account's event went too: %d left", n)
	}
	// Idempotent: a redelivered deletion is fine.
	if err := h.svc.HandleUserDeleted(context.Background(), eventbus.UserDeletedPayload{UserID: user}); err != nil {
		t.Fatal(err)
	}
}

// TestNoRawIdentifierIsStoredAnywhere scans every row of every analytics
// table, partitions included, for the raw user id and the personal data an
// event tried to carry.
func TestNoRawIdentifierIsStoredAnywhere(t *testing.T) {
	h := newHarness(t)
	const user = "dddddddd-1234-5678-9abc-def012345678"
	e := ev("error_shown", newID(), `{"kind": "network", "email": "jane@example.com", "name": "Jane Doe", "user_id": "`+user+`"}`)
	e.Screen = "home"
	h.ingest(t, user,
		e,
		ev("cta_tapped", newID(), `{"cta": "schedule_meetup"}`),
		ev("error_shown", newID(), `{"kind": "Jane Doe could not be reached"}`),
	)
	h.svc.Record(context.Background(), analytics.ServerEvent{Source: "test:" + newID(), Name: "credits_spent", UserID: user,
		Attributes: map[string]any{"credits": 14, "reason": "capture"}})
	h.svc.Record(context.Background(), analytics.ServerEvent{Source: "test:" + newID(), Name: "purchase_verified", UserID: user,
		Attributes: map[string]any{"platform": "android", "kind": "consumable", "product_id": "credits_50"}})
	h.sync()
	h.clock.Set(base.Add(24 * time.Hour))
	if _, err := h.svc.SweepAggregate(context.Background()); err != nil {
		t.Fatal(err)
	}

	rows, err := h.pool.Query(context.Background(), `
		SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'analytics' AND c.relkind = 'r'`)
	if err != nil {
		t.Fatal(err)
	}
	var tables []string
	for rows.Next() {
		var name string
		_ = rows.Scan(&name)
		tables = append(tables, name)
	}
	rows.Close()
	if len(tables) < 10 {
		t.Fatalf("only found tables %v", tables)
	}
	scanned := 0
	for _, table := range tables {
		r, err := h.pool.Query(context.Background(), fmt.Sprintf(`SELECT row_to_json(t)::text FROM analytics.%q t`, table))
		if err != nil {
			t.Fatal(err)
		}
		for r.Next() {
			var row string
			_ = r.Scan(&row)
			scanned++
			for _, secret := range []string{user, strings.ReplaceAll(user, "-", ""), "jane", "Jane", "example.com"} {
				if strings.Contains(row, secret) {
					t.Errorf("analytics.%s holds %q: %s", table, secret, row)
				}
			}
		}
		r.Close()
	}
	if scanned < 5 {
		t.Errorf("scanned only %d rows; the test is not looking at real data", scanned)
	}
}

func TestPartitionsAreCreatedAheadIdempotently(t *testing.T) {
	h := newHarness(t)
	made, err := h.svc.SweepPartitions(context.Background())
	if err != nil || made != 0 {
		t.Errorf("second run made %d (%v), want 0", made, err)
	}
	for i := 0; i <= analytics.PartitionsAhead; i++ {
		name := "analytics.events_" + base.AddDate(0, 0, i).Format("20060102")
		var exists bool
		_ = h.pool.QueryRow(context.Background(), `SELECT to_regclass($1) IS NOT NULL`, name).Scan(&exists)
		if !exists {
			t.Errorf("%s missing", name)
		}
	}
	h.clock.Set(base.AddDate(0, 0, 1))
	if made, _ := h.svc.SweepPartitions(context.Background()); made != 1 {
		t.Errorf("a day later it made %d, want 1", made)
	}
}

func TestADayWithoutAPartitionIsRescuedFromTheDefault(t *testing.T) {
	h := newHarness(t)
	// Ten days ahead: no partition exists, so the row lands in the default.
	far := base.AddDate(0, 0, 10)
	h.clock.Set(far)
	e := ev("screen_viewed", newID(), `{}`)
	e.OccurredAt = far.Format(time.RFC3339)
	h.ingest(t, "", e)
	h.sync()
	var part string
	_ = h.pool.QueryRow(context.Background(), `SELECT tableoid::regclass::text FROM analytics.events`).Scan(&part)
	if part != "analytics.events_default" {
		t.Fatalf("landed in %s", part)
	}
	if _, err := h.svc.SweepPartitions(context.Background()); err != nil {
		t.Fatal(err)
	}
	_ = h.pool.QueryRow(context.Background(), `SELECT tableoid::regclass::text FROM analytics.events`).Scan(&part)
	if part != "analytics.events_"+far.Format("20060102") {
		t.Errorf("after the sweep it is in %s", part)
	}
}

func TestAggregationIsIdempotent(t *testing.T) {
	h := newHarness(t)
	sess := uuid.NewString()
	at := func(name string, d time.Duration, screen, attrs string) registry.Input {
		e := ev(name, newID(), attrs)
		e.OccurredAt = base.Add(-time.Hour + d).Format(time.RFC3339Nano)
		e.Screen, e.SessionID = screen, sess
		return e
	}
	flow := func(name, step string) registry.Input {
		e := ev(name, newID(), `{}`)
		e.FlowID, e.FlowStep = "schedule_meetup", step
		return e
	}
	h.ingest(t, "eeeeeeee-0000-0000-0000-000000000005",
		at("session_started", 0, "", `{}`),
		at("screen_viewed", time.Second, "home", `{}`),
		at("screen_left", 2*time.Second, "home", `{"duration_ms": 2000}`),
		at("screen_viewed", 3*time.Second, "credits", `{}`),
		at("screen_left", 4*time.Second, "credits", `{"duration_ms": 10000}`),
		at("cta_tapped", 5*time.Second, "credits", `{"cta": "buy_credits"}`),
		at("error_shown", 6*time.Second, "credits", `{"kind": "network"}`),
		at("session_ended", 7*time.Second, "", `{"duration_ms": 60000}`),
		flow("flow_started", ""), flow("flow_step_viewed", "intent"), flow("flow_step_completed", "intent"),
		flow("flow_step_viewed", "timing"), flow("flow_abandoned", "timing"),
	)
	h.svc.Record(context.Background(), analytics.ServerEvent{Source: "agg:1", Name: "credits_spent", UserID: "eeeeeeee-0000-0000-0000-000000000005",
		Attributes: map[string]any{"credits": 14, "reason": "capture"}})
	h.sync()

	h.clock.Set(base.Add(24 * time.Hour))
	n, err := h.svc.SweepAggregate(context.Background())
	if err != nil || n != 1 {
		t.Fatalf("aggregated %d days (%v), want 1", n, err)
	}
	snapshot := func() string {
		var out strings.Builder
		for _, table := range []string{"daily_screen_stats", "daily_feature_stats", "daily_funnel_stats", "daily_session_stats", "daily_error_stats", "daily_credit_stats", "user_first_seen"} {
			r, err := h.pool.Query(context.Background(), fmt.Sprintf(`SELECT row_to_json(t)::text FROM analytics.%s t ORDER BY 1`, table))
			if err != nil {
				t.Fatal(err)
			}
			for r.Next() {
				var row string
				_ = r.Scan(&row)
				out.WriteString(table + " " + row + "\n")
			}
			r.Close()
		}
		return out.String()
	}
	first := snapshot()
	for _, want := range []string{
		`daily_screen_stats {"day":"2026-10-25","screen":"credits","views":1,"unique_users":1,"median_ms":10000,"p90_ms":10000,"bounces":0,"exits":1}`,
		`daily_screen_stats {"day":"2026-10-25","screen":"home","views":1,"unique_users":1,"median_ms":2000,"p90_ms":2000,"bounces":1,"exits":0}`,
		`daily_feature_stats {"day":"2026-10-25","feature":"buy_credits","uses":1,"unique_users":1}`,
		`daily_funnel_stats {"day":"2026-10-25","flow_id":"schedule_meetup","step":"","entered":1,"completed":0,"abandoned":1,"median_step_ms":null}`,
		`daily_funnel_stats {"day":"2026-10-25","flow_id":"schedule_meetup","step":"intent","entered":1,"completed":1,"abandoned":0,"median_step_ms":null}`,
		`daily_funnel_stats {"day":"2026-10-25","flow_id":"schedule_meetup","step":"timing","entered":1,"completed":0,"abandoned":1,"median_step_ms":null}`,
		`daily_session_stats {"day":"2026-10-25","sessions":1,"users":1,"signed_in_users":1,"median_session_ms":60000,"mean_session_ms":60000}`,
		`daily_error_stats {"day":"2026-10-25","kind":"error","screen":"credits","detail":"network","count":1}`,
		`daily_credit_stats {"day":"2026-10-25","event_name":"credits_spent","detail":"capture","events":1,"users":1,"credits":14}`,
	} {
		if !strings.Contains(first, want+"\n") {
			t.Errorf("missing %s\nhave:\n%s", want, first)
		}
	}

	// Again through the sweep: nothing to do.
	if n, _ := h.svc.SweepAggregate(context.Background()); n != 0 {
		t.Errorf("second sweep aggregated %d days", n)
	}
	// And a forced re-run replaces rather than adds.
	if _, err := h.store.Aggregate(context.Background(), time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	if again := snapshot(); again != first {
		t.Errorf("re-aggregating changed the rows:\nbefore:\n%s\nafter:\n%s", first, again)
	}
}

func TestRetentionArchivesThenDrops(t *testing.T) {
	h := newHarness(t)
	h.ingest(t, "", ev("screen_viewed", newID(), `{}`), ev("app_opened", newID(), `{"cold_start": true}`))
	h.sync()

	// 14 days later the day is still inside the window.
	h.clock.Set(base.AddDate(0, 0, 14))
	if n, err := h.svc.SweepRetention(context.Background()); err != nil || n != 0 {
		t.Fatalf("dropped %d (%v) inside the window", n, err)
	}

	// A failed upload keeps the partition.
	h.clock.Set(base.AddDate(0, 0, 15))
	h.upload.fail = errors.New("bucket unavailable")
	if _, err := h.svc.SweepRetention(context.Background()); err == nil {
		t.Fatal("a failed upload was not reported")
	}
	if n := h.count(t, "received_day = '2026-10-25'"); n != 2 {
		t.Fatalf("the partition lost its rows after a failed upload: %d", n)
	}

	h.upload.fail = nil
	n, err := h.svc.SweepRetention(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// The 25th plus the three days made ahead with it, all now past.
	if n < 1 {
		t.Fatalf("dropped %d partitions", n)
	}
	body := h.upload.objects["tiehere-test-bucket/analytics/raw/2026/10/25.ndjson.gz"]
	if body == nil {
		t.Fatalf("no archive; objects: %v", keys(h.upload.objects))
	}
	zr, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(zr)
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 2 || !strings.Contains(string(raw), `"event_name":"app_opened"`) || !strings.Contains(string(raw), `"cold_start":true`) {
		t.Errorf("archive = %s", raw)
	}
	var exists bool
	_ = h.pool.QueryRow(context.Background(), `SELECT to_regclass('analytics.events_20261025') IS NOT NULL`).Scan(&exists)
	if exists {
		t.Error("the partition is still there")
	}
	var aggregated bool
	_ = h.pool.QueryRow(context.Background(), `SELECT EXISTS (SELECT 1 FROM analytics.aggregate_runs WHERE day = '2026-10-25')`).Scan(&aggregated)
	if !aggregated {
		t.Error("the day was dropped without being aggregated")
	}
	if n, err := h.svc.SweepRetention(context.Background()); err != nil || n != 0 {
		t.Errorf("second run dropped %d (%v), want 0", n, err)
	}
}

func TestRetentionWithoutABucketSkipsTheArchiveCleanly(t *testing.T) {
	h := newHarness(t, func(d *analytics.Deps) { d.Config.ArchiveBucket = ""; d.Archive = nil })
	h.ingest(t, "", ev("screen_viewed", newID(), `{}`))
	h.sync()
	h.clock.Set(base.AddDate(0, 0, 15))
	n, err := h.svc.SweepRetention(context.Background())
	if err != nil || n < 1 {
		t.Fatalf("dropped %d (%v)", n, err)
	}
	var archived int
	_ = h.pool.QueryRow(context.Background(), `SELECT count(*) FROM analytics.partitions WHERE archived_at IS NOT NULL`).Scan(&archived)
	if archived != 0 {
		t.Errorf("%d partitions marked archived with no bucket", archived)
	}
}

func keys(m map[string][]byte) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func date(t time.Time) pgtype.Date { return pgtype.Date{Time: t, Valid: true} }
