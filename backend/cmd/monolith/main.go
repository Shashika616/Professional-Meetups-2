// Command monolith wires up and runs the backend's single gRPC server. This
// file is wiring only: load config, construct dependencies, subscribe each
// module's event handlers, start serving, handle SIGTERM gracefully.
// Business logic lives in internal/modules/*.
//
// One process, one port, every module (ADR-001 §1). Phases 2-4 add the
// meetup, billing and notification modules here — additively: another
// module's New(...), another RegisterXServiceServer on the same server,
// another Subscribe or two. This file is not rewritten by those phases.
//
// What it deliberately never constructs: a jwt.Signer. The private key lives
// with the gateway now (ADR-001 §6) and this binary has no way to mint a
// token — a smaller blast radius if it is ever compromised.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/grpcapi"
	"professional-meetups-monolith/backend/internal/modules/auth"
	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/modules/notification"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/geocoding"
	"professional-meetups-monolith/backend/internal/platform/internalauth"
	"professional-meetups-monolith/backend/internal/platform/logging"
	"professional-meetups-monolith/backend/internal/platform/metrics"
	"professional-meetups-monolith/backend/internal/platform/outbox"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
	meetupv1 "professional-meetups-monolith/backend/internal/proto/meetup/v1"
)

func main() {
	// `monolith -healthcheck` probes an already-running instance and exits,
	// rather than starting a server (§D1). It is what docker-compose.yml's
	// healthcheck runs — see healthcheck.go for why this is a mode of this
	// binary instead of a separate grpc-health-probe artifact.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		if err := runHealthcheck(); err != nil {
			// Plain stderr, not the JSON logger: this output is read by a
			// human running `docker inspect` on a failing container, and one
			// legible line beats a structured record nobody will query.
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	logger := logging.New()
	// apperror.ToGRPCStatus and the modules log unclassified/redacted error
	// detail via slog.Default() rather than threading a *slog.Logger through
	// every call site — this makes that output match the rest of the
	// process's JSON format instead of slog's plain-text default.
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("monolith exited with error", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	port := os.Getenv("MONOLITH_PORT")
	if port == "" {
		return fmt.Errorf("config: required environment variable MONOLITH_PORT is not set")
	}
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return fmt.Errorf("config: required environment variable DATABASE_URL is not set")
	}
	// Required, never defaulted and never empty-means-off: an empty secret
	// with a "skip the check when unset" fallback is how this protection
	// silently stops existing. A monolith that can't authenticate its caller
	// should refuse to start, not accept anyone.
	//
	// The value may be a comma-separated LIST so a secret can be rotated
	// without a coordinated restart of both processes — see
	// internal/platform/internalauth's package doc for the three-deploy
	// procedure. ParseSecrets refuses an empty entry rather than letting a
	// trailing comma quietly make "" an accepted secret.
	internalSecrets, err := internalauth.ParseSecrets(os.Getenv("INTERNAL_GRPC_SHARED_SECRET"))
	if err != nil {
		return fmt.Errorf("config: INTERNAL_GRPC_SHARED_SECRET: %w", err)
	}

	cfg, err := authconfig.Load()
	if err != nil {
		return fmt.Errorf("load auth module config: %w", err)
	}

	// Loud, impossible-to-miss reminder every time this is on — see
	// TESTING-NOTES.md and internal/modules/auth/otp.go's allowTestOTPBypass.
	// This must never be true outside local development; the warning fires
	// on every single startup for as long as the flag is set, specifically
	// so it can't go unnoticed in a deployed environment's logs.
	if os.Getenv("ALLOW_TEST_OTP_BYPASS") == "true" {
		logger.Warn("ALLOW_TEST_OTP_BYPASS is enabled — the fixed code \"123456\" is accepted for every OTP purpose in addition to the real one. This MUST NOT be true outside local development. See TESTING-NOTES.md.")
	}

	// A SEPARATE warning line for the narrower mechanism (Plan 16), not a
	// branch of the one above: the two are independent, and either has to be
	// identifiable on its own in `gcloud run services logs read`.
	//
	// The COUNT is logged, never the numbers themselves — there is no reason
	// to put real phone numbers into log output, and this line fires on every
	// startup for as long as the var is set.
	if raw := os.Getenv("TEST_OTP_BYPASS_PHONES"); raw != "" {
		n := 0
		for _, p := range strings.Split(raw, ",") {
			if strings.TrimSpace(p) != "" {
				n++
			}
		}
		logger.Warn("TEST_OTP_BYPASS_PHONES is set — the fixed code \"123456\" is accepted for phone verification on specific allowlisted numbers, and the real SMS send is skipped for them. Scoped to phone purpose only. See TESTING-NOTES.md.", "allowlisted_numbers", n)
	}

	// The email twin, again a separate line rather than a branch of either
	// above. Deliberately louder than the phone one: the phone list exposes
	// numbers that cannot complete verification anyway, while an allowlisted
	// EMAIL address is an account anyone knowing the address can sign in as.
	// That warrants noticing on every boot.
	//
	// Count only, never the addresses — the same rule as above, and here it
	// matters more, since an address in this list IS the credential.
	if raw := os.Getenv("TEST_OTP_BYPASS_EMAILS"); raw != "" {
		// The safety argument for this list is that no entry can be a real
		// mailbox. Enforce it before anything else: a deliverable address
		// here is a credential-free login, so the process refuses to start
		// rather than warn and continue. Same exit path as any other
		// invalid required configuration (run() returns, main exits 1).
		if err := auth.ValidateTestOTPBypassEmails(raw); err != nil {
			return fmt.Errorf("config: %w", err)
		}
		n := 0
		for _, e := range strings.Split(raw, ",") {
			if strings.TrimSpace(e) != "" {
				n++
			}
		}
		logger.Warn("TEST_OTP_BYPASS_EMAILS is set — the fixed code \"123456\" is accepted for ALL FOUR email verification purposes (signup, login, personal, corporate) on specific allowlisted addresses, and the real email send is skipped for them. Anyone who knows an allowlisted address can sign in as it: every entry must be an unroutable test address, never a deliverable one. See TESTING-NOTES.md.", "allowlisted_addresses", n)
	}

	pool, err := db.New(ctx, databaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	// One bus for the whole process (ADR-001 §4). Modules publish and
	// subscribe on it; nothing else exists between them.
	bus := eventbus.New(logger)

	// The work-email HMAC key, held the way a signing key is (a secrets/
	// mount, this process only). A key that won't read should crash at
	// startup, not surface on the first corporate-email verification that
	// needs it.
	workEmailHMACKey, err := os.ReadFile(cfg.WorkEmailHMACKeyPath)
	if err != nil {
		return fmt.Errorf("read work email hmac key: %w", err)
	}

	linkedInClient := linkedin.New(linkedin.Config{
		ClientID:     cfg.LinkedInClientID,
		ClientSecret: cfg.LinkedInClientSecret,
	})

	// AppleServicesID/GoogleClientID may legitimately be "" here (real
	// credentials not yet issued) — both providers still construct
	// successfully and fetch their real JWKS; Verify simply rejects every
	// token until a real audience is configured. Fails closed, not open.
	appleProvider, err := identity.NewAppleProvider(ctx, cfg.AppleServicesID)
	if err != nil {
		return fmt.Errorf("construct apple identity provider: %w", err)
	}
	googleProvider, err := identity.NewGoogleProvider(ctx, cfg.GoogleClientID)
	if err != nil {
		return fmt.Errorf("construct google identity provider: %w", err)
	}

	emailSender := newEmailSender(cfg, logger)
	smsSender := newSmsSender(cfg, logger)

	authService := auth.New(auth.Deps{
		Users:                   repository.NewUserRepository(pool, bus, logger),
		Identities:              repository.NewUserIdentityRepository(pool),
		RefreshTokens:           repository.NewRefreshTokenRepository(pool),
		VerificationCodes:       repository.NewVerificationCodeRepository(pool),
		KnownCompanies:          repository.NewKnownCompanyRepository(pool),
		UnverifiedCompanyClaims: repository.NewUnverifiedCompanyClaimRepository(pool),
		TrustedContacts:         repository.NewTrustedContactRepository(pool),
		SOSEvents:               repository.NewSOSEventRepository(pool),
		LinkedIn:                linkedInClient,
		Apple:                   appleProvider,
		Google:                  googleProvider,
		Email:                   emailSender,
		SMS:                     smsSender,
		WorkEmailHMACKey:        workEmailHMACKey,
		Logger:                  logger,
	})

	// --- meetup module (Phase 2) ---
	//
	// Its three event-fed caches are read models of data other modules own
	// (ADR-001 §3): they are never written by request-handling code, only by
	// the subscriptions below.
	userDisplayCache := meetuprepo.NewUserDisplayCacheRepository(pool)
	userLocationCache := meetuprepo.NewUserLocationCacheRepository(pool)
	subscriptionCache := meetuprepo.NewSubscriptionCacheRepository(pool)
	meetupDeviceTokens := meetuprepo.NewDeviceTokenRepository(pool)

	notificationOutbox := meetuprepo.NewNotificationOutboxRepository(pool)
	meetupsCompletedOutbox := meetuprepo.NewMeetupsCompletedOutboxRepository(pool)

	// The second outbox poller (docs/plans/06-async-meetups-completed-
	// recompute.md): the profile "meetups completed" recompute, moved off
	// the transaction that closes a meetup. Same generic machinery as the
	// notification poller below, a different table and process function.
	//
	// Constructed BEFORE the meetup repository for the same reason the
	// notification poller is constructed before the meetup service — the
	// repository needs this poller's Wake, so the poller has to exist first.
	//
	// NO OBSERVER, deliberately. outboxObserver writes to metrics named
	// notification_outbox_* (see internal/platform/metrics) — folding a
	// second, unrelated poller's deliveries into counters explicitly
	// documented as the notification outbox's would silently corrupt what
	// they mean, and OutboxPending is a Set() gauge that two pollers would
	// race on, each overwriting the other's value with its own table's
	// count. This poller is therefore logged but not instrumented; giving it
	// its own metric names is a small, separate change, not something to
	// smuggle in by reusing the wrong ones.
	meetupsCompletedPoller := outbox.New(
		meetupsCompletedOutbox,
		meetup.NewCompletedRecompute(meetupsCompletedOutbox, bus, logger).Process,
		outbox.WithLogger(logger),
	)

	// --- notification module (Phase 4, pulled forward — §E/§F) ---
	//
	// Constructed BEFORE the meetup service because the meetup service needs
	// the poller's Wake (§F5): a business write nudges the poller the instant
	// it commits, so common-case delivery latency is an FCM round trip rather
	// than up to one tick interval.
	pushSender := newPushSender(ctx, logger)
	notificationPoller := outbox.New(
		notificationOutbox,
		notification.NewDelivery(pushSender, meetupDeviceTokens, logger).Process,
		outbox.WithLogger(logger),
		outbox.WithObserver(outboxObserver{}),
	)

	meetupService := meetup.New(meetup.Deps{
		Meetups:       meetuprepo.NewMeetupRepository(pool, bus, logger, meetupsCompletedPoller.Wake),
		Requests:      meetuprepo.NewMeetupRequestRepository(pool, bus, logger),
		SafetyState:   meetuprepo.NewSafetyStateRepository(pool),
		Feedback:      meetuprepo.NewFeedbackRepository(pool),
		Ratings:       meetuprepo.NewRatingRepository(pool, bus, logger),
		DeviceTokens:  meetupDeviceTokens,
		UserLocations: userLocationCache,
		Outbox:        notificationOutbox,
		Wake:          notificationPoller.Wake,
		Geocoder:      geocoding.NewNominatimReverseGeocoder(),
		// meetup -> auth, for "tell my trusted contacts about this meetup".
		// An adapter rather than a direct dependency: the meetup module owns
		// the meetup facts, auth owns the contacts and the SMS/email
		// senders, and neither reads the other's schema (ADR-001 §3). The
		// translation between the two modules' own types lives here, in the
		// same place every other cross-module wire is made.
		ContactNotifier: contactNotifier{auth: authService},
		Logger:          logger,
	})

	// --- event subscriptions ---
	//
	// Every handler below is idempotent and order-guarded on the payload's
	// own OccurredAt (never time.Now()), so a redelivered or out-of-order
	// event no-ops rather than regressing newer data. A handler returning an
	// error is logged and swallowed by the bus (ADR-001 §4) — a consumer
	// problem must never fail the business write that triggered it.

	// auth -> meetup: keep the display cache current. Both topics carry the
	// same payload shape and mean the same thing to this cache ("here is
	// this user's current display info"), so they share one handler.
	displayCacheHandler := func(ctx context.Context, e eventbus.Event) error {
		switch payload := e.Payload.(type) {
		case eventbus.UserOnboardedPayload:
			_, err := userDisplayCache.Upsert(ctx, payload.UserID, payload.FullName, payload.ProfilePhotoURL, payload.TrustLevel, payload.OccurredAt)
			return err
		case eventbus.UserProfileUpdatedPayload:
			_, err := userDisplayCache.Upsert(ctx, payload.UserID, payload.FullName, payload.ProfilePhotoURL, payload.TrustLevel, payload.OccurredAt)
			return err
		default:
			return fmt.Errorf("user display cache: unexpected payload type %T on %s", e.Payload, e.Topic)
		}
	}
	bus.Subscribe(eventbus.TopicUserOnboarded, displayCacheHandler)
	bus.Subscribe(eventbus.TopicUserProfileUpdated, displayCacheHandler)

	// auth -> meetup: last-known location, which backs the nearby-notify
	// fan-out (never the browse-screen radius filter — that uses the
	// caller's own fresh coordinate, passed per request).
	bus.Subscribe(eventbus.TopicUserLocationUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.UserLocationUpdatedPayload)
		if !ok {
			return fmt.Errorf("user location cache: unexpected payload type %T", e.Payload)
		}
		_, err := userLocationCache.Upsert(ctx, payload.UserID, payload.Lat, payload.Lng, payload.OccurredAt)
		return err
	})

	// billing -> meetup: entitlement cache. NOTHING PUBLISHES THESE UNTIL
	// PHASE 3 — wired now anyway, the same bootstrapping pattern Phase 1
	// used for publishing events nothing consumed yet, so Phase 3 adds a
	// publisher rather than also having to add plumbing here.
	bus.Subscribe(eventbus.TopicSubscriptionActivated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.SubscriptionActivatedPayload)
		if !ok {
			return fmt.Errorf("subscription cache: unexpected payload type %T", e.Payload)
		}
		_, err := subscriptionCache.Upsert(ctx, payload.UserID, payload.Tier, true, payload.OccurredAt)
		return err
	})
	bus.Subscribe(eventbus.TopicSubscriptionDeactivated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.SubscriptionDeactivatedPayload)
		if !ok {
			return fmt.Errorf("subscription cache: unexpected payload type %T", e.Payload)
		}
		_, err := subscriptionCache.Upsert(ctx, payload.UserID, payload.Tier, false, payload.OccurredAt)
		return err
	})

	// meetup -> meetup: the nearby-notify fan-out. The one same-module,
	// different-subscription consumer — CreateMeetup publishes it, and this
	// handler notifies everyone with a non-stale cached location within 40km.
	bus.Subscribe(eventbus.TopicMeetupCreated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.MeetupCreatedPayload)
		if !ok {
			return fmt.Errorf("nearby notify: unexpected payload type %T", e.Payload)
		}
		return meetupService.HandleMeetupCreated(ctx, meetup.NearbyNotifyPayload{
			MeetupID:    payload.MeetupID,
			HostUserID:  payload.HostUserID,
			Intent:      payload.Intent,
			LocationLat: payload.LocationLat,
			LocationLng: payload.LocationLng,
		})
	})

	// meetup -> auth: the rating cache Phase 1 deliberately left unwired,
	// because only the meetup module publishes this and it didn't exist yet.
	// Its publisher exists as of this phase, so the subscription does too.
	bus.Subscribe(eventbus.TopicRatingUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.RatingUpdatedPayload)
		if !ok {
			return fmt.Errorf("rating cache: unexpected payload type %T", e.Payload)
		}
		_, err := authService.ApplyRatingUpdate(ctx, payload.UserID, payload.RatingAverage, payload.RatingCount, payload.OccurredAt)
		return err
	})

	// meetup -> auth: the profile's "meetups completed" figure, on exactly
	// the same terms as the rating cache above — the meetup module owns the
	// meetups and recomputes the total whenever one completes, this is the
	// only writer of auth.users.meetups_completed.
	bus.Subscribe(eventbus.TopicMeetupsCompletedUpdated, func(ctx context.Context, e eventbus.Event) error {
		payload, ok := e.Payload.(eventbus.MeetupsCompletedUpdatedPayload)
		if !ok {
			return fmt.Errorf("meetups-completed cache: unexpected payload type %T", e.Payload)
		}
		_, err := authService.ApplyMeetupsCompletedUpdate(ctx, payload.UserID, payload.MeetupsCompleted, payload.OccurredAt)
		return err
	})

	// push-notification-requested is NO LONGER AN EVENT-BUS TOPIC at all.
	// The meetup module writes those notifications into
	// meetup.notification_outbox inside the same transaction as the business
	// write that implies them, and the poller started below delivers them
	// (ADR-001's durable-notification-delivery correction, §F). Every other
	// topic above is unchanged: still the in-memory bus, still synchronous,
	// still the ADR-001 §4 trade-off as originally reasoned.

	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		return fmt.Errorf("listen on port %s: %w", port, err)
	}

	// Interceptor order is load-bearing: request-id first (so a rejected
	// call is still traceable in the logs), then the shared-secret check,
	// then recovery closest to the handler. Authentication runs BEFORE any
	// module code — an unauthenticated caller never reaches business logic or
	// the database.
	grpcServer := grpc.NewServer(grpc.ChainUnaryInterceptor(
		logging.UnaryServerInterceptor(),
		// Outside the deadline and recovery interceptors on purpose: a call
		// that times out or panics still has to be counted, or the metrics
		// look healthiest exactly when the process is not (§D3).
		logging.MetricsUnaryServerInterceptor(),
		// Bounds every handler (§B2). Ahead of authentication so the bound
		// covers that too, and paired with db.StatementTimeout, which is the
		// server-side backstop beneath it.
		logging.DeadlineUnaryServerInterceptor(logging.DefaultRPCTimeout),
		internalauth.UnaryServerInterceptor(internalSecrets),
		logging.RecoveryUnaryServerInterceptor(logger),
	))
	authv1.RegisterAuthServiceServer(grpcServer, grpcapi.NewAuthServer(authService))
	// Same server, same port, same interceptor chain — the shared-secret
	// check is wired at the server level above, so it covers every meetup RPC
	// automatically, with nothing meetup-specific to add.
	meetupv1.RegisterMeetupServiceServer(grpcServer, grpcapi.NewMeetupServer(meetupService))

	// The standard gRPC health service (§D1/§D3). Compose uses it to gate
	// the gateway's start on the monolith being genuinely ready to SERVE,
	// not merely to have launched a process — the difference that causes
	// early-request failures on a cold start or a rolling redeploy. The
	// gateway's own /readyz proxies to it.
	//
	// Registered but NOT yet marked SERVING: that happens once the listener
	// is actually accepting, below. Announcing readiness before it is true
	// is the exact failure this is meant to remove.
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)

	// Background loops. All four share one shape — `go x.Run(ctx)`, stopping
	// cleanly when ctx is cancelled by SIGTERM — deliberately, so periodic
	// work in this process is one recognisable pattern rather than four.
	//
	// The lifecycle poller: two sweeps a minute (starting-soon reminders,
	// auto-close), the same way the source starts its own alongside the gRPC
	// server.
	go meetup.NewPoller(meetupService, logger).Run(ctx)
	// Notification delivery (§F4): claims outbox rows and pushes them, woken
	// immediately by each committing write and ticking as the safety net.
	go notificationPoller.Run(ctx)
	// Meetups-completed recompute: same shape, woken by each committing
	// completion (Close and the auto-close sweep) and ticking as the safety
	// net.
	go meetupsCompletedPoller.Run(ctx)
	// Outbox retention (§F8) and refresh-token retention (§B3): all hourly,
	// all batched, each closing an otherwise-unbounded table. One Retention
	// type serves both outboxes — it takes a store, not a table name, so the
	// second table needed a second instance rather than a second copy of the
	// job.
	go notification.NewRetention(notificationOutbox, logger).Run(ctx)
	go notification.NewRetentionFor("meetups-completed outbox", meetupsCompletedOutbox, logger).Run(ctx)
	go auth.NewRefreshTokenSweeper(authService, logger).Run(ctx)

	serveErrCh := make(chan error, 1)
	go func() {
		logger.Info("monolith listening", "port", port)
		serveErrCh <- grpcServer.Serve(listener)
	}()

	// The listener is bound and Serve is running: it is now true that this
	// process can handle a request, so say so.
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)

	select {
	case err := <-serveErrCh:
		if err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			return fmt.Errorf("grpc server: %w", err)
		}
		return nil
	case <-ctx.Done():
		logger.Info("shutting down monolith")
		// Fail the health check first, so anything watching it (Compose, a
		// load balancer) stops sending new work while in-flight calls drain.
		healthServer.Shutdown()
		shutdownGRPCServer(grpcServer, logger)
		return nil
	}
}

// shutdownGracePeriod bounds how long GracefulStop may take before the
// server is stopped outright (§D7).
//
// Matches the gateway's own 10s shutdown budget. Unbounded GracefulStop —
// what this was before — waits for EVERY in-flight RPC to finish, so one
// stuck call (the exact scenario §B2's deadline interceptor exists to
// prevent, but which the interceptor cannot cover for a handler that ignores
// its context) holds shutdown open indefinitely, until the orchestrator's
// own patience runs out and SIGKILLs the process mid-write instead.
func shutdownGRPCServer(server *grpc.Server, logger *slog.Logger) {
	const shutdownGracePeriod = 10 * time.Second

	stopped := make(chan struct{})
	go func() {
		server.GracefulStop()
		close(stopped)
	}()

	select {
	case <-stopped:
		return
	case <-time.After(shutdownGracePeriod):
		// Deliberately loud: forcing a stop means at least one RPC was
		// killed mid-flight, which is worth knowing about rather than
		// absorbing silently.
		logger.Warn("graceful shutdown exceeded its grace period, forcing stop",
			"grace_period", shutdownGracePeriod)
		server.Stop()
	}
}

// contactNotifier adapts the auth module's trusted-contact fan-out to the
// narrow interface the meetup module declares. Both modules run in this one
// process, so this is a direct call rather than an event — but it stays an
// interface so neither package imports the other.
type contactNotifier struct{ auth auth.Service }

func (c contactNotifier) NotifyMeetupShare(ctx context.Context, userID string, share meetup.ContactShare) (int, error) {
	return c.auth.NotifyMeetupShare(ctx, userID, auth.MeetupShare{
		ContactIDs:    share.ContactIDs,
		LocationLabel: share.LocationLabel,
		Latitude:      share.Latitude,
		Longitude:     share.Longitude,
		WindowStart:   share.WindowStart,
		WindowEnd:     share.WindowEnd,
	})
}

// outboxObserver adapts the generic poller's Observer to this process's
// Prometheus counters. It lives here rather than in internal/platform/outbox
// so that package stays usable, and testable, without a metrics registry.
type outboxObserver struct{}

func (outboxObserver) Delivered()    { metrics.Default.OutboxDelivered.Inc() }
func (outboxObserver) Failed()       { metrics.Default.OutboxFailed.Inc() }
func (outboxObserver) DeadLettered() { metrics.Default.OutboxDeadLettered.Inc() }
func (outboxObserver) Pending(n int) { metrics.Default.OutboxPending.Set(float64(n)) }

// newPushSender chooses the delivery mechanism, same env-var-gated pattern
// as the auth module's email and SMS senders (§E2).
//
// An empty FIREBASE_SERVICE_ACCOUNT_JSON means LoggingPushSender, which is
// the normal, expected state for local development and CI — hence Info, not
// Warn. It is not a bypass of anything; there is simply no credential to
// talk to FCM with, and the alternative (failing to start) would make the
// backend unrunnable without a Firebase project.
//
// The variable holds the service account's RAW JSON CONTENT, not a path —
// confirmed against the source's own config, and already the shape of the
// value in backend/.env.
//
// A credential that is PRESENT but unusable fails the process at startup
// rather than falling back: silently logging notifications instead of
// sending them, in an environment that was configured to send them, is the
// kind of failure nobody notices until users report missing notifications.
func newPushSender(ctx context.Context, logger *slog.Logger) notification.Sender {
	raw := os.Getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
	if raw == "" {
		logger.Info("push notification delivery: LoggingPushSender (FIREBASE_SERVICE_ACCOUNT_JSON not set)")
		return notification.NewLoggingPushSender(logger)
	}

	sender, err := notification.NewFCMPushSender(ctx, []byte(raw))
	if err != nil {
		// The error is logged, never the credential — a service-account JSON
		// contains a private key.
		logger.Error("push notification delivery: FIREBASE_SERVICE_ACCOUNT_JSON is set but unusable", "error", err)
		panic("monolith: FIREBASE_SERVICE_ACCOUNT_JSON is set but could not be used; fix it or unset it to fall back to logging")
	}
	logger.Info("push notification delivery: FCM", "project_id", sender.ProjectID())
	return sender
}

// newEmailSender prefers Gmail SMTP when GMAIL_ADDRESS/GMAIL_APP_PASSWORD
// are both set — a Gmail account can send to any recipient immediately,
// unlike a Resend sandbox account (limited to the account owner's own inbox
// until a domain is verified there), which makes it the better default for
// testing signup with arbitrary addresses. Falls back to Resend if only that
// is configured, then to LoggingEmailSender if neither is, so local dev and
// tests keep working before either exists.
func newEmailSender(cfg authconfig.Config, logger *slog.Logger) email.EmailSender {
	if cfg.GmailAddress != "" && cfg.GmailAppPassword != "" {
		logger.Info("verification email delivery: Gmail SMTP")
		return email.NewGmailSMTPEmailSender(cfg.GmailAddress, cfg.GmailAppPassword)
	}
	if cfg.ResendAPIKey != "" && cfg.ResendFromEmail != "" {
		logger.Info("verification email delivery: Resend")
		return email.NewResendEmailSender(cfg.ResendAPIKey, cfg.ResendFromEmail)
	}
	logger.Info("verification email delivery: LoggingEmailSender (GMAIL_ADDRESS/GMAIL_APP_PASSWORD and RESEND_API_KEY/RESEND_FROM_EMAIL not set)")
	return email.NewLoggingEmailSender()
}

// newSmsSender uses Twilio only once all three TWILIO_* vars are non-empty —
// LoggingSmsSender otherwise, same fallback pattern as email.
func newSmsSender(cfg authconfig.Config, logger *slog.Logger) sms.SmsSender {
	if cfg.TwilioAccountSID != "" && cfg.TwilioAuthToken != "" && cfg.TwilioPhoneNumber != "" {
		logger.Info("verification SMS delivery: Twilio")
		return sms.NewTwilioSmsSender(cfg.TwilioAccountSID, cfg.TwilioAuthToken, cfg.TwilioPhoneNumber)
	}
	logger.Info("verification SMS delivery: LoggingSmsSender (TWILIO_* not fully set)")
	return sms.NewLoggingSmsSender()
}
