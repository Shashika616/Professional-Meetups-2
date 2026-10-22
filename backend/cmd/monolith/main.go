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

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/grpcapi"
	"professional-meetups-monolith/backend/internal/modules/auth"
	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/modules/notification"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/geocoding"
	"professional-meetups-monolith/backend/internal/platform/internalauth"
	"professional-meetups-monolith/backend/internal/platform/logging"
	"professional-meetups-monolith/backend/internal/platform/outbox"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
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

	registerSubscriptions(subscriptionDeps{
		bus:               bus,
		userDisplayCache:  userDisplayCache,
		userLocationCache: userLocationCache,
		subscriptionCache: subscriptionCache,
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
	)
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
