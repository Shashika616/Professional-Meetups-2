package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/auth"
	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/modules/notification"
	"professional-meetups-monolith/backend/internal/platform/metrics"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// Constructors and small adapters run() wires together. Moved out of main.go
// unchanged (#96).

// refuseGlobalOTPBypassOnCloudRun turns the global test-OTP bypass into a
// startup failure on Cloud Run (tracker #92, review finding N-A6).
//
// # WHY A WARNING WAS NOT ENOUGH
//
// A warning is the right volume for a local machine and the wrong one for
// a deployed service: it scrolls past in `gcloud run services logs read`
// and the service serves traffic anyway, with "123456" accepted for EVERY
// OTP purpose and every account. That is a complete authentication
// bypass, reachable by anyone who knows an email address, and the only
// thing standing between it and production was somebody reading a log
// line.
//
// K_SERVICE is set by Cloud Run in every container it starts and by
// nothing else, so it is the signal for "this is not a laptop". Checking
// it costs one lookup and turns "we hope nobody deployed this" into a
// failure the deploy itself surfaces.
//
// It refuses ONLY the global flag. The scoped mechanisms are untouched
// and stay usable in every environment: TEST_OTP_BYPASS_EMAILS keeps its
// reserved-TLD enforcement and TEST_OTP_BYPASS_PHONES its exact-match
// allowlist, both safe by construction and documented in
// TESTING-NOTES.md.
//
// getenv is a parameter so this is testable without mutating the real
// process environment.
func refuseGlobalOTPBypassOnCloudRun(getenv func(string) string) error {
	if getenv("ALLOW_TEST_OTP_BYPASS") != "true" {
		return nil
	}
	service := getenv("K_SERVICE")
	if service == "" {
		return nil
	}
	return fmt.Errorf(
		"ALLOW_TEST_OTP_BYPASS=true on Cloud Run (K_SERVICE=%q): the fixed code "+
			"\"123456\" would be accepted for every OTP purpose and every account. "+
			"Refusing to start. Unset it on the service; for scoped test accounts "+
			"use TEST_OTP_BYPASS_EMAILS, which is restricted to reserved test TLDs "+
			"(TESTING-NOTES.md)", service)
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

// requireRealSendersInProduction refuses to start a deployed service that
// cannot actually deliver (tracker #92, review finding N-A9).
//
// The logging senders are the right default for a laptop: they let signup
// work before anyone has a Twilio account. On Cloud Run they are a silent
// outage with a security twist — a misconfigured deploy keeps serving,
// every OTP "send" succeeds from the caller's point of view, nobody
// receives anything, and the codes themselves are written to logs that a
// wider set of people can read than should ever see them.
//
// Nothing in the service can tell that apart from working, which is why
// it has to be a startup check rather than an alert: by the time anyone
// notices, the codes are already in the log.
//
// K_SERVICE is set by Cloud Run and by nothing else, the same signal the
// OTP-bypass guard uses.
func requireRealSendersInProduction(getenv func(string) string, cfg authconfig.Config) error {
	if getenv("K_SERVICE") == "" {
		return nil
	}
	var missing []string
	if !(cfg.GmailAddress != "" && cfg.GmailAppPassword != "") &&
		!(cfg.ResendAPIKey != "" && cfg.ResendFromEmail != "") {
		missing = append(missing,
			"email (set GMAIL_ADDRESS+GMAIL_APP_PASSWORD or RESEND_API_KEY+RESEND_FROM_EMAIL)")
	}
	if !(cfg.TwilioAccountSID != "" && cfg.TwilioAuthToken != "" && cfg.TwilioPhoneNumber != "") {
		missing = append(missing,
			"SMS (set TWILIO_ACCOUNT_SID+TWILIO_AUTH_TOKEN+TWILIO_PHONE_NUMBER)")
	}
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf(
		"refusing to start on Cloud Run without a real sender for: %s. "+
			"The logging fallback writes verification codes to the logs and "+
			"delivers nothing, which looks identical to working",
		strings.Join(missing, "; "))
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

// userDeletedProcess is the user-deleted outbox's delivery step: decode the
// row, then hand the payload to each consumer in turn.
//
// A named function rather than a closure at the wiring site because this is
// the SEAM between two modules that never call each other, and a seam that
// nothing can execute in a test is a seam that can break silently. The
// payload crosses it as JSON; if that round trip broke, UserID would arrive
// empty and every consumer would run happily against "no such user",
// deleting nothing and reporting success. See the pipeline test beside this
// file, which drives this exact function.
//
// Consumers are called DIRECTLY, not through bus.Publish. That is
// load-bearing: Publish always returns nil and only logs a failing handler,
// so routing through it would let the outbox mark a failed purge as
// delivered, with no retry ever coming. Returning the first error instead
// leaves the row for the poller to retry; every consumer is idempotent, so
// re-running all of them after a partial failure is safe.
func userDeletedProcess(
	consumers []func(context.Context, eventbus.UserDeletedPayload) error,
) func(context.Context, outbox.Row) error {
	return func(ctx context.Context, row outbox.Row) error {
		var payload eventbus.UserDeletedPayload
		if err := json.Unmarshal(row.Payload, &payload); err != nil {
			return fmt.Errorf("decode user-deleted payload: %w", err)
		}
		for _, consume := range consumers {
			if err := consume(ctx, payload); err != nil {
				return err
			}
		}
		return nil
	}
}
