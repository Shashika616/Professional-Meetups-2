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
	"syscall"

	"google.golang.org/grpc"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/grpcapi"
	"professional-meetups-monolith/backend/internal/modules/auth"
	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/linkedin"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/logging"
	authv1 "professional-meetups-monolith/backend/internal/proto/auth/v1"
)

func main() {
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

	cfg, err := authconfig.Load()
	if err != nil {
		return fmt.Errorf("load auth module config: %w", err)
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

	// Event subscriptions: none in this phase. The auth module PUBLISHES
	// user-onboarded, user-profile-updated and user-location-updated (so
	// Phase 2 has something to subscribe to without touching Phase 1 code
	// again), and it CONSUMES rating-updated — but only the meetup module
	// publishes that, and it doesn't exist yet. Wiring a handler now for an
	// event nothing publishes would be a dangling subscription, so that
	// Subscribe call belongs in Phase 2, next to the publisher that makes it
	// meaningful.

	listener, err := net.Listen("tcp", ":"+port)
	if err != nil {
		return fmt.Errorf("listen on port %s: %w", port, err)
	}

	grpcServer := grpc.NewServer(grpc.ChainUnaryInterceptor(
		logging.UnaryServerInterceptor(),
		logging.RecoveryUnaryServerInterceptor(logger),
	))
	authv1.RegisterAuthServiceServer(grpcServer, grpcapi.NewAuthServer(authService))

	serveErrCh := make(chan error, 1)
	go func() {
		logger.Info("monolith listening", "port", port)
		serveErrCh <- grpcServer.Serve(listener)
	}()

	select {
	case err := <-serveErrCh:
		if err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			return fmt.Errorf("grpc server: %w", err)
		}
		return nil
	case <-ctx.Done():
		logger.Info("shutting down monolith")
		grpcServer.GracefulStop()
		return nil
	}
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
