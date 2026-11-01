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

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/grpcapi"
	"professional-meetups-monolith/backend/internal/modules/analytics"
	analyticsconfig "professional-meetups-monolith/backend/internal/modules/analytics/config"
	analyticsrepo "professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/modules/auth"
	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/billing"
	billingconfig "professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/modules/notification"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/flags"
	"professional-meetups-monolith/backend/internal/platform/geocoding"
	"professional-meetups-monolith/backend/internal/platform/internalauth"
	"professional-meetups-monolith/backend/internal/platform/logging"
	"professional-meetups-monolith/backend/internal/platform/outbox"
	"professional-meetups-monolith/backend/internal/platform/telemetry"
	analyticsv1 "professional-meetups-monolith/backend/internal/proto/analytics/v1"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
	billingv1 "professional-meetups-monolith/backend/internal/proto/billing/v1"
	meetupv1 "professional-meetups-monolith/backend/internal/proto/meetup/v1"
	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
	"professional-meetups-monolith/backend/migrations"
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
	if err := refuseGlobalOTPBypassOnCloudRun(os.Getenv); err != nil {
		return err
	}
	if err := requireRealSendersInProduction(os.Getenv, cfg); err != nil {
		return err
	}
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

		// A malformed entry is a silent dud: it can never match a
		// normalised target, so the number it was meant to cover keeps
		// failing verification and the cause is invisible (#92). The
		// entry is named here because it is a typo in configuration,
		// not a real person's number — and if it DOES look like one,
		// the regex would have accepted it and this line would not
		// fire.
		if invalid := auth.ValidateTestOTPBypassPhones(); len(invalid) > 0 {
			logger.Warn("TEST_OTP_BYPASS_PHONES contains entries that are not E.164 phone numbers — they will never match and the numbers they were meant to cover still cannot verify",
				"invalid_entries", invalid)
		}
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

	// Plan 29D: OpenTelemetry, before the pool so its query spans have a
	// provider. Exporter by configuration (OTEL_EXPORTER, default none).
	telCfg, err := telemetry.ConfigFromEnv("monolith", os.Getenv("K_REVISION"), os.Getenv)
	if err != nil {
		return err
	}
	tel, err := telemetry.Setup(ctx, telCfg)
	if err != nil {
		return fmt.Errorf("telemetry: %w", err)
	}
	defer func() {
		flushCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tel.Shutdown(flushCtx); err != nil {
			logger.Warn("telemetry flush on shutdown", "error", err)
		}
	}()

	pool, err := db.New(ctx, databaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	// Before anything is wired: a schema behind this build must stop the
	// revision here, not on the first request that needs the newer schema.
	if have, err := checkSchemaVersion(ctx, pool, migrations.Latest()); err != nil {
		return err
	} else if have > migrations.Latest() {
		logger.Info("schema is newer than this build; continuing (migrations are backward compatible)",
			"schema_version", have, "build_expects", migrations.Latest())
	}

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

	usersRepo := repository.NewUserRepository(pool, bus, logger)
	authService := auth.New(auth.Deps{
		Users:                   usersRepo,
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
		PublicBaseURL:           cfg.PublicBaseURL,
		Logger:                  logger,
	})

	// --- feature flags and billing (plan 29A, ADR-010, ADR-012) ---
	//
	// The flags service reads ops.feature_flags through a 30-second cache;
	// email_domains rules (the @meetups.test fixtures) resolve an account's
	// email through auth, only when a rule needs it.
	flagService := flags.NewService(flags.NewPostgresStore(pool),
		flags.WithEmailResolver(flagEmailResolver(authService)), flags.WithLogger(logger))
	billingCfg, err := billingconfig.Load()
	if err != nil {
		return err
	}
	appleRoots, err := apple.TrustedRoots()
	if err != nil {
		return err
	}
	billingService := billing.New(billing.Deps{
		Pool:         pool,
		Fingerprints: identityFingerprint{auth: authService, key: workEmailHMACKey},
		Config:       billingCfg,
		Flags:        flagService,
		// Plan 29B: Apple and Google, failing closed without credentials.
		Store:      billingStore(billingCfg, appleRoots, logger),
		AppleRoots: appleRoots,
		GooglePush: googlePush(billingCfg, logger),
		Logger:     logger,
	})
	// --- analytics module (plan 29D) ---
	//
	// Best effort by design: its buffer drops rather than blocks, and its
	// outbox consumers below cannot fail. Without ANALYTICS_USER_KEY_SECRET
	// on Cloud Run it collects nothing (rather than keying users weakly).
	analyticsCfg, err := analyticsconfig.Load()
	if err != nil {
		return err
	}
	if analyticsCfg.Disabled {
		logger.Warn("analytics disabled: collecting nothing", "reason", analyticsCfg.DisabledReason)
	}
	if analyticsCfg.ArchiveBucket == "" {
		logger.Warn("analytics: ANALYTICS_ARCHIVE_BUCKET is not set; raw events are dropped after the retention without an archive")
	}
	analyticsService := analytics.New(analytics.Deps{
		Store:   analyticsrepo.New(pool),
		Config:  analyticsCfg,
		Flags:   flagService,
		Archive: analytics.NewGCS(),
		// Plan 29F: the daily report's email and billing's daily check.
		Mailer:         newReportMailer(emailSender),
		Reconciliation: reconciliationSource{billing: billingService},
		Logger:         logger,
	})
	// Its own context, cancelled only after the gRPC server has drained, so
	// events accepted by the last requests are still flushed.
	analyticsCtx, stopAnalytics := context.WithCancel(context.WithoutCancel(ctx))
	defer func() {
		stopAnalytics()
		select {
		case <-analyticsService.Done():
		case <-time.After(10 * time.Second):
			logger.Warn("analytics: final flush did not finish in time")
		}
	}()
	go analyticsService.Run(analyticsCtx)
	// Today's partition and the next three, now, so the first events after
	// a fresh migration never land in the default partition. The tick keeps
	// it three days ahead.
	if _, err := analyticsService.SweepPartitions(ctx); err != nil {
		logger.Warn("analytics: could not create partitions at start-up; the tick will retry", "error", err)
	}

	// billing.billing_outbox: the Google consume/acknowledge retries
	// (billing's own), subscription changes into the meetup module's
	// subscription_cache, and (29D) credits, purchases and subscriptions
	// for analytics, whose consumer never returns an error.
	subscriptionCache := meetuprepo.NewSubscriptionCacheRepository(pool)
	billingOutbox := billing.NewOutboxStore(pool)
	billingPoller := outbox.New(billingOutbox,
		billing.OutboxProcess(billingService.HandleOutboxEvent, subscriptionCacheConsumer(subscriptionCache),
			analyticsBillingConsumer(analyticsService)),
		outbox.WithLogger(logger))
	// meetup.billing_outbox: a charged meetup's created/cancelled/closed
	// events, delivered to billing (capture; the refund policy). Built
	// before the meetup service, which needs its Wake.
	meetupBillingOutbox := meetuprepo.NewBillingOutboxRepository(pool)
	meetupBillingPoller := outbox.New(meetupBillingOutbox,
		withAnalytics(meetupBillingProcess(billingService), meetupBillingAnalytics(analyticsService)),
		outbox.WithLogger(logger))

	// --- meetup module (Phase 2) ---
	//
	// Its three event-fed caches are read models of data other modules own
	// (ADR-001 §3): they are never written by request-handling code, only by
	// the subscriptions below.
	userDisplayCache := meetuprepo.NewUserDisplayCacheRepository(pool)
	userLocationCache := meetuprepo.NewUserLocationCacheRepository(pool)
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
		withAnalytics(meetup.NewCompletedRecompute(meetupsCompletedOutbox, bus, logger).Process,
			meetupsCompletedAnalytics(analyticsService)),
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
		// meetup -> billing (plan 29 §3.5): price and reserve a creation.
		Charger:     creationCharger{billing: billingService},
		BillingWake: meetupBillingPoller.Wake,
		Logger:      logger,
	})

	registerSubscriptions(subscriptionDeps{
		bus:               bus,
		userDisplayCache:  userDisplayCache,
		userLocationCache: userLocationCache,
		meetupService:     meetupService,
		authService:       authService,
		logger:            logger,
	})

	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		return fmt.Errorf("listen on port %s: %w", port, err)
	}

	// Interceptor order is load-bearing: request-id first (so a rejected
	// call is still traceable in the logs), then the shared-secret check,
	// then recovery closest to the handler. Authentication runs BEFORE any
	// module code — an unauthenticated caller never reaches business logic or
	// the database.
	// Plan 29D: a server span per call, continuing the gateway's trace
	// from the W3C traceparent otelgrpc's client handler sent.
	grpcServer := grpc.NewServer(grpc.StatsHandler(otelgrpc.NewServerHandler()), grpc.ChainUnaryInterceptor(
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
		// The calling app build (X-App-Version, X-Platform), forwarded by
		// the gateway as metadata — plan 29 §2.
		clientinfo.UnaryServerInterceptor(),
		logging.RecoveryUnaryServerInterceptor(logger),
	))
	authv1.RegisterAuthServiceServer(grpcServer, grpcapi.NewAuthServer(authService))
	// Same server, same port, same interceptor chain — the shared-secret
	// check is wired at the server level above, so it covers every meetup RPC
	// automatically, with nothing meetup-specific to add.
	meetupv1.RegisterMeetupServiceServer(grpcServer, grpcapi.NewMeetupServer(meetupService))
	billingv1.RegisterBillingServiceServer(grpcServer, grpcapi.NewBillingServer(billingService))
	analyticsv1.RegisterAnalyticsServiceServer(grpcServer, grpcapi.NewAnalyticsServer(analyticsService))

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

	// --- user-deleted delivery (account deletion, 2026-09-28) ---
	//
	// The auth module deletes an account and, in the same transaction, writes
	// a row to auth.user_deleted_outbox. This poller drains it. It is the one
	// place in the process where the two modules meet over deletion, and it
	// is a composition root doing a broker's job, not either module reaching
	// into the other: auth knows nothing about who listens, meetup knows
	// nothing about where the event came from, and the only contract between
	// them is eventbus.UserDeletedPayload. As separate services this function
	// becomes a Pub/Sub subscription and neither module changes.
	//
	// It calls each consumer DIRECTLY and returns the first error, rather
	// than going through bus.Publish. That is deliberate and load-bearing:
	// Publish always returns nil and only logs a failing handler, so routing
	// through it would let the outbox mark a failed purge as delivered, and a
	// deleted person's name and photo would stay in the meetup schema with no
	// retry ever coming. Every consumer is idempotent, so re-running all of
	// them after a partial failure is safe.
	userDeletedOutbox := repository.NewUserDeletedOutboxRepository(pool)
	userDeletedConsumers := []func(context.Context, eventbus.UserDeletedPayload) error{
		meetupService.HandleUserDeleted,
		billingService.HandleUserDeleted,
		analyticsService.HandleUserDeleted,
	}
	userDeletedPoller := outbox.New(
		userDeletedOutbox,
		userDeletedProcess(userDeletedConsumers),
		outbox.WithLogger(logger),
		outbox.WithObserver(outboxObserver{}),
	)
	// Wake the poller the moment a deletion commits, so another module holds
	// a deleted person's data for milliseconds rather than a tick interval.
	repository.SetDeletedNotifier(usersRepo, userDeletedPoller.Wake)

	// Background loops. All of them share one shape — `go x.Run(ctx)`, stopping
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
	notificationRetention := notification.NewRetention(notificationOutbox, logger)
	meetupsCompletedRetention := notification.NewRetentionFor("meetups-completed outbox", meetupsCompletedOutbox, logger)
	go notificationRetention.Run(ctx)
	go meetupsCompletedRetention.Run(ctx)
	// User-deleted delivery and its retention, same shape as the two above.
	go userDeletedPoller.Run(ctx)
	userDeletedRetention := notification.NewRetentionFor("user-deleted outbox", userDeletedOutbox, logger)
	go userDeletedRetention.Run(ctx)
	go auth.NewRefreshTokenSweeper(authService, logger).Run(ctx)
	// Billing's two outboxes, woken by the writes that fill them.
	go billingPoller.Run(ctx)
	go meetupBillingPoller.Run(ctx)
	billingRetention := notification.NewRetentionFor("billing outbox", billingOutbox, logger)
	meetupBillingRetention := notification.NewRetentionFor("meetup billing outbox", meetupBillingOutbox, logger)
	go billingRetention.Run(ctx)
	go meetupBillingRetention.Run(ctx)
	// meetup.activity_outbox (plan 29D): join requests and accepts, for
	// analytics only. Its process function never fails, so a row is
	// retried only if the process dies mid-delivery.
	activityOutbox := meetuprepo.NewActivityOutboxRepository(pool)
	activityPoller := outbox.New(activityOutbox, meetupActivityProcess(analyticsService), outbox.WithLogger(logger))
	activityRetention := notification.NewRetentionFor("meetup activity outbox", activityOutbox, logger)
	go activityPoller.Run(ctx)
	go activityRetention.Run(ctx)

	// The same work, driven from outside the process.
	//
	// Every loop above needs an instance that is alive and has CPU. On Cloud
	// Run that means minScale "1" with cpu-throttling "false" — a reserved,
	// continuously billed instance, about US$120-130/mo for this container
	// pair against a free allowance of 180,000 vCPU-seconds a month. This
	// project stays inside the free tier (Shashika, 2026-10-22), so the
	// service scales to zero and Cloud Scheduler calls RunScheduledWork
	// instead (service.yaml, runbook §10).
	//
	// The tickers stay. When an instance IS alive they do the work sooner
	// than the next scheduled tick would, and running both paths is harmless:
	// every sweep below claims its rows with FOR UPDATE SKIP LOCKED, so the
	// two paths take disjoint sets rather than doubling up.
	//
	// Order matters in one place only, and it is preserved here: the refresh
	// token sweep must run before the abandoned-guest sweep, because a guest
	// becomes eligible only once its last token row is gone.
	opsServer := grpcapi.NewOpsServer(logger,
		grpcapi.Sweep{Name: "lifecycle: starting-soon", Run: countedInt(meetupService.NotifyStartingSoonSweep)},
		grpcapi.Sweep{Name: "lifecycle: auto-close", Run: countedInt(meetupService.AutoCloseSweep)},
		grpcapi.Sweep{Name: "outbox: notifications", Run: countedInt(notificationPoller.Drain)},
		grpcapi.Sweep{Name: "outbox: meetups-completed", Run: countedInt(meetupsCompletedPoller.Drain)},
		grpcapi.Sweep{Name: "outbox: user-deleted", Run: countedInt(userDeletedPoller.Drain)},
		grpcapi.Sweep{Name: "retention: notifications", Run: retentionSweep(notificationRetention)},
		grpcapi.Sweep{Name: "retention: meetups-completed", Run: retentionSweep(meetupsCompletedRetention)},
		grpcapi.Sweep{Name: "retention: user-deleted", Run: retentionSweep(userDeletedRetention)},
		grpcapi.Sweep{Name: "auth: expired refresh tokens", Run: countedInt(authService.SweepExpiredRefreshTokens)},
		grpcapi.Sweep{Name: "auth: abandoned guests", Run: countedInt(authService.SweepAbandonedGuests)},
		grpcapi.Sweep{Name: "auth: expired safety holds", Run: countedInt(authService.SweepExpiredSafetyHolds)},
		grpcapi.Sweep{Name: "auth: contact invitation log", Run: countedInt(authService.SweepContactInvites)},
		// Billing (plan 29A). Captures and refunds first, so a creation's
		// capture lands before its hold could be expired below.
		grpcapi.Sweep{Name: "outbox: meetup billing events", Run: countedInt(meetupBillingPoller.Drain)},
		grpcapi.Sweep{Name: "billing: expired holds", Run: countedInt(billingService.SweepExpiredHolds)},
		grpcapi.Sweep{Name: "billing: decay and expiry", Run: countedInt(billingService.SweepDecayAndExpiry)},
		grpcapi.Sweep{Name: "outbox: billing", Run: countedInt(billingPoller.Drain)},
		grpcapi.Sweep{Name: "billing: reconciliation", Run: countedInt(billingService.Reconcile)},
		grpcapi.Sweep{Name: "retention: meetup billing events", Run: retentionSweep(meetupBillingRetention)},
		grpcapi.Sweep{Name: "retention: billing outbox", Run: retentionSweep(billingRetention)},
		// Plan 29D. Partitions first, so the day's writes have somewhere to
		// go; the aggregate before the retention, which never drops a day
		// that has not been aggregated (it aggregates first if it must).
		grpcapi.Sweep{Name: "outbox: meetup activity", Run: countedInt(activityPoller.Drain)},
		grpcapi.Sweep{Name: "retention: meetup activity", Run: retentionSweep(activityRetention)},
		grpcapi.Sweep{Name: "analytics: partitions", Run: countedInt(analyticsService.SweepPartitions)},
		grpcapi.Sweep{Name: "analytics: aggregate", Run: countedInt(analyticsService.SweepAggregate)},
		grpcapi.Sweep{Name: "analytics: archive and retention", Run: countedInt(analyticsService.SweepRetention)},
		// After 06:00 Colombo, once a day: yesterday's report, emailed and
		// stored. Idempotent by date; a failed delivery retries next tick.
		grpcapi.Sweep{Name: "analytics: daily report", Run: countedInt(analyticsService.SweepReport)},
	).WithAppConfig(grpcapi.AppConfig{
		Flags:                  flagService,
		MinSupportedAppVersion: minSupportedAppVersion(),
		BillingCatalogVersion:  int32(billingCfg.CatalogVersion),
	})
	// Same server, same port, same interceptor chain as the two services
	// above, so the shared-secret check already covers it.
	opsv1.RegisterOpsServiceServer(grpcServer, opsServer)

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
