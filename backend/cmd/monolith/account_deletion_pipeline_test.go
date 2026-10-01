package main

import (
	"context"
	"log/slog"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	authrepo "professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// The SEAM between the two modules, against real Postgres.
//
// Each module's own half of account deletion is covered by its own
// integration test. Neither covers the join between them, because the join
// does not exist inside either module: it is the wiring in main.go, where
// the auth module's outbox rows are claimed, decoded, and handed to the
// meetup module's handler. That wiring is rebuilt here, from the same
// constructors main.go calls, and driven end to end.
//
// # WHY THIS IS WORTH A TEST OF ITS OWN
//
// The payload crosses the seam as JSON: the auth repository encodes
// eventbus.UserDeletedPayload when it claims a row, and main.go decodes it
// before calling the handler. If that round trip ever broke — a renamed
// JSON tag, a changed field — UserID would arrive as the empty string, and
// PurgeUser would run happily against "no such user", delete nothing, and
// report success. The outbox row would be marked processed. Nothing would
// error, nothing would retry, and a deleted person's name and photograph
// would stay in the meetup schema for good.
//
// A silent failure is exactly the kind a test has to catch, so this asserts
// on the rows being gone, never on the absence of an error.

const pipelineMigrationsURL = "file://../../migrations"

func requirePipelinePostgres(t *testing.T) string {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatalf("DATABASE_URL %q is not a URL: %v", dbURL, err)
	}
	hostPort := parsed.Host
	if !strings.Contains(hostPort, ":") {
		hostPort += ":5432"
	}
	conn, err := net.DialTimeout("tcp", hostPort, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable on %s, skipping (run `docker compose up -d postgres` first): %v", hostPort, err)
	}
	_ = conn.Close()

	// Its OWN database, never the one a running monolith is attached to.
	// This is not hygiene, it is a correctness requirement, and this test
	// makes it a sharper one than most: the harness below TRUNCATEs
	// auth.users, so pointed at the application's database it would delete
	// every real account there, and the live poller would be claiming the
	// outbox rows this test queues. Same call the auth and meetup harnesses
	// make (see db.EnsureTestDatabase); omitting it here is precisely the
	// mistake that wiped a developer's seeded accounts twice.
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("prepare isolated test database: %v", err)
	}
	return testURL
}

type pipelineHarness struct {
	pool    *pgxpool.Pool
	users   authrepo.UserRepository
	poller  *outbox.Poller
	pending func(t *testing.T) int
}

// newPipelineHarness builds the same objects, in the same order, that
// main.go builds: the auth user repository, the auth user-deleted outbox,
// the meetup service, and the poller that carries rows from the first to
// the last. The process function is the one from main.go, decode included.
func newPipelineHarness(t *testing.T) *pipelineHarness {
	t.Helper()
	dbURL := requirePipelinePostgres(t)
	if err := db.Migrate(dbURL, pipelineMigrationsURL); err != nil {
		t.Fatalf("run migrations: %v", err)
	}

	ctx := context.Background()
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	// Same lock every other integration harness takes: this one truncates
	// both schemas, which the module harnesses are populating when packages
	// run in parallel.
	release, err := db.AcquireIntegrationTestLock(ctx, pool)
	if err != nil {
		t.Fatalf("acquire integration test lock: %v", err)
	}
	t.Cleanup(release)

	if _, err := pool.Exec(ctx, `
		TRUNCATE meetup.meetups, meetup.meetup_requests, meetup.safety_state,
		         meetup.meetup_feedback, meetup.device_tokens, meetup.meetup_user_ratings,
		         meetup.user_display_cache, meetup.user_location_cache, meetup.subscription_cache,
		         meetup.notification_outbox, meetup.meetups_completed_outbox,
		         meetup.safety_share,
		         auth.users, auth.user_deleted_outbox, auth.safety_holds
		RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	logger := slog.New(slog.DiscardHandler)
	bus := eventbus.New(logger)

	usersRepo := authrepo.NewUserRepository(pool, bus, logger)
	userDeletedOutbox := authrepo.NewUserDeletedOutboxRepository(pool)

	meetupService := meetup.New(meetup.Deps{
		Meetups:       meetuprepo.NewMeetupRepository(pool, bus, logger, func() {}),
		Requests:      meetuprepo.NewMeetupRequestRepository(pool, bus, logger),
		SafetyState:   meetuprepo.NewSafetyStateRepository(pool),
		Feedback:      meetuprepo.NewFeedbackRepository(pool),
		Ratings:       meetuprepo.NewRatingRepository(pool, bus, logger),
		DeviceTokens:  meetuprepo.NewDeviceTokenRepository(pool),
		UserLocations: meetuprepo.NewUserLocationCacheRepository(pool),
		Outbox:        meetuprepo.NewNotificationOutboxRepository(pool),
		Logger:        logger,
	})

	// userDeletedProcess is the production delivery step itself, not a copy
	// of it: a reproduction here could drift from main.go and still pass.
	poller := outbox.New(
		userDeletedOutbox,
		userDeletedProcess([]func(context.Context, eventbus.UserDeletedPayload) error{
			meetupService.HandleUserDeleted,
		}),
		outbox.WithLogger(logger),
	)
	authrepo.SetDeletedNotifier(usersRepo, poller.Wake)

	return &pipelineHarness{
		pool:   pool,
		users:  usersRepo,
		poller: poller,
		pending: func(t *testing.T) int {
			t.Helper()
			n, err := userDeletedOutbox.CountPending(context.Background())
			if err != nil {
				t.Fatalf("count pending: %v", err)
			}
			return n
		},
	}
}

func pipelineCount(t *testing.T, pool *pgxpool.Pool, query string, args ...any) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

// TestAccountDeletionPipeline_CarriesTheDeletionAcrossBothModules is the
// whole point: delete in auth, and the meetup module's copy of that person
// goes away, with nothing but the outbox connecting the two.
func TestAccountDeletionPipeline_CarriesTheDeletionAcrossBothModules(t *testing.T) {
	h := newPipelineHarness(t)
	ctx := context.Background()

	var ada string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.users (full_name, trust_level)
		VALUES ('Ada Lovelace', 1) RETURNING id::text`).Scan(&ada); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	// The meetup module's own copies of this person. The display cache is
	// the one that matters most: it is where their name and photograph live
	// in this schema.
	if _, err := h.pool.Exec(ctx, `
		INSERT INTO meetup.user_display_cache (user_id, full_name, profile_photo_url, trust_level)
		VALUES ($1, 'Ada Lovelace', 'https://example.com/ada.jpg', 1)`, ada); err != nil {
		t.Fatalf("seed display cache: %v", err)
	}
	if _, err := h.pool.Exec(ctx, `
		INSERT INTO meetup.device_tokens (user_id, fcm_token)
		VALUES ($1, 'token-ada')`, ada); err != nil {
		t.Fatalf("seed device token: %v", err)
	}

	if err := h.users.Delete(ctx, ada); err != nil {
		t.Fatalf("Delete() error: %v", err)
	}

	// Committed, and waiting to be carried across.
	if got := h.pending(t); got != 1 {
		t.Fatalf("pending outbox rows after delete = %d, want 1", got)
	}
	if got := pipelineCount(t, h.pool,
		`SELECT count(*) FROM meetup.user_display_cache WHERE user_id = $1`, ada); got != 1 {
		t.Fatalf("display cache rows before the drain = %d, want 1 (the delete must not reach across by itself)", got)
	}

	h.poller.DrainOnce(ctx)

	// The assertions that would fail if the payload did not round-trip:
	// an empty UserID purges nothing and reports success.
	if got := pipelineCount(t, h.pool,
		`SELECT count(*) FROM meetup.user_display_cache WHERE user_id = $1`, ada); got != 0 {
		t.Errorf("display cache rows after the drain = %d, want 0: their name and photo are still in the meetup schema", got)
	}
	if got := pipelineCount(t, h.pool,
		`SELECT count(*) FROM meetup.device_tokens WHERE user_id = $1`, ada); got != 0 {
		t.Errorf("device token rows after the drain = %d, want 0", got)
	}
	if got := pipelineCount(t, h.pool,
		`SELECT count(*) FROM auth.users WHERE id = $1`, ada); got != 0 {
		t.Errorf("auth.users rows = %d, want 0", got)
	}
	if got := h.pending(t); got != 0 {
		t.Errorf("pending outbox rows after the drain = %d, want 0", got)
	}
}

// TestAccountDeletionPipeline_RedeliveryIsHarmless covers the retry the
// outbox is built to perform: a row delivered twice must leave the same
// result, not an error and not a second round of damage.
func TestAccountDeletionPipeline_RedeliveryIsHarmless(t *testing.T) {
	h := newPipelineHarness(t)
	ctx := context.Background()

	var ada string
	if err := h.pool.QueryRow(ctx, `
		INSERT INTO auth.users (full_name, trust_level)
		VALUES ('Ada Lovelace', 1) RETURNING id::text`).Scan(&ada); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if _, err := h.pool.Exec(ctx, `
		INSERT INTO meetup.user_display_cache (user_id, full_name, profile_photo_url, trust_level)
		VALUES ($1, 'Ada Lovelace', '', 1)`, ada); err != nil {
		t.Fatalf("seed display cache: %v", err)
	}
	if err := h.users.Delete(ctx, ada); err != nil {
		t.Fatalf("Delete() error: %v", err)
	}

	h.poller.DrainOnce(ctx)
	// A second row for the same account, as a redelivery would produce.
	if _, err := h.pool.Exec(ctx,
		`INSERT INTO auth.user_deleted_outbox (user_id) VALUES ($1)`, ada); err != nil {
		t.Fatalf("enqueue redelivery: %v", err)
	}
	h.poller.DrainOnce(ctx)

	if got := h.pending(t); got != 0 {
		t.Errorf("pending after redelivery = %d, want 0: the second delivery must succeed, not fail and retry forever", got)
	}
	if got := pipelineCount(t, h.pool,
		`SELECT count(*) FROM meetup.user_display_cache WHERE user_id = $1`, ada); got != 0 {
		t.Errorf("display cache rows = %d, want 0", got)
	}
}
