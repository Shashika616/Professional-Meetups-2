// Package config loads the auth module's environment configuration,
// matching the variable names backend/docker-compose.yml's `monolith`
// service sets locally.
//
// Ported from ../Professional-Meetups/backend/services/auth/internal/config
// with three variables removed, each for a structural reason rather than a
// preference:
//
//   - JWT_PRIVATE_KEY_PATH — the gateway holds the signing key now
//     (ADR-001 §6); this process never signs anything.
//   - GRPC_PORT — the monolith has one port for every module, read by
//     cmd/monolith itself (MONOLITH_PORT), not per-module config.
//   - GCP_PROJECT_ID — it existed only to address Pub/Sub, which ADR-001 §4
//     removes entirely.
//
// DATABASE_URL likewise moves up to cmd/monolith: there is one pool for the
// whole process now (ADR-001 §3), not one per module.
package config

import (
	"fmt"
	"os"
)

// Config is loaded once at startup. The required/optional split is carried
// over exactly from the source — in particular, credentials that don't exist
// yet are deliberately NOT required, because their absence has a defined,
// safe behavior rather than being a misconfiguration.
type Config struct {
	LinkedInClientID     string
	LinkedInClientSecret string
	LinkedInRedirectURI  string
	// WorkEmailHMACKeyPath keys the work_email_hash reuse-abuse check.
	// Required: a process that can't compute this hash can't safely run the
	// corporate-email verification flow at all, so it should fail fast at
	// startup rather than on the first request that needs it.
	WorkEmailHMACKeyPath string

	// AppleServicesID/GoogleClientID are the expected `aud` claim on each
	// provider's id_token — deliberately NOT required, same non-blocking
	// treatment as Twilio/Resend: neither credential exists yet, and the
	// identity providers fail CLOSED (reject every token) rather than fail to
	// start when their audience is unconfigured.
	AppleServicesID string
	GoogleClientID  string

	// Twilio/Gmail/Resend credentials are deliberately NOT required — the
	// module falls back to LoggingSmsSender/LoggingEmailSender when they're
	// empty, so local dev and tests keep working before real credentials
	// exist. Which sender is constructed depends on whether each purpose's
	// full credential set is non-empty (see cmd/monolith).
	TwilioAccountSID  string
	TwilioAuthToken   string
	TwilioPhoneNumber string

	// GmailAddress/GmailAppPassword send real verification email via a
	// personal Gmail account's SMTP relay — preferred over Resend when set,
	// since a Gmail account can send to any recipient immediately, unlike a
	// Resend sandbox account (limited to the account owner's own inbox until
	// a domain is verified there). GmailAppPassword must be a Google App
	// Password, never the account's real login password.
	GmailAddress     string
	GmailAppPassword string
	ResendAPIKey     string
	ResendFromEmail  string
}

// Load reads Config from the environment, failing fast if any required
// variable is missing or empty.
func Load() (Config, error) {
	cfg := Config{
		LinkedInClientID:     os.Getenv("LINKEDIN_CLIENT_ID"),
		LinkedInClientSecret: os.Getenv("LINKEDIN_CLIENT_SECRET"),
		LinkedInRedirectURI:  os.Getenv("LINKEDIN_REDIRECT_URI"),
		WorkEmailHMACKeyPath: os.Getenv("WORK_EMAIL_HMAC_KEY_PATH"),

		AppleServicesID: os.Getenv("APPLE_SERVICES_ID"),
		GoogleClientID:  os.Getenv("GOOGLE_CLIENT_ID"),

		TwilioAccountSID:  os.Getenv("TWILIO_ACCOUNT_SID"),
		TwilioAuthToken:   os.Getenv("TWILIO_AUTH_TOKEN"),
		TwilioPhoneNumber: os.Getenv("TWILIO_PHONE_NUMBER"),

		GmailAddress:     os.Getenv("GMAIL_ADDRESS"),
		GmailAppPassword: os.Getenv("GMAIL_APP_PASSWORD"),
		ResendAPIKey:     os.Getenv("RESEND_API_KEY"),
		ResendFromEmail:  os.Getenv("RESEND_FROM_EMAIL"),
	}

	required := []struct {
		name  string
		value string
	}{
		{"LINKEDIN_CLIENT_ID", cfg.LinkedInClientID},
		{"LINKEDIN_CLIENT_SECRET", cfg.LinkedInClientSecret},
		{"LINKEDIN_REDIRECT_URI", cfg.LinkedInRedirectURI},
		{"WORK_EMAIL_HMAC_KEY_PATH", cfg.WorkEmailHMACKeyPath},
	}
	for _, req := range required {
		if req.value == "" {
			return Config{}, fmt.Errorf("config: required environment variable %s is not set", req.name)
		}
	}

	return cfg, nil
}
