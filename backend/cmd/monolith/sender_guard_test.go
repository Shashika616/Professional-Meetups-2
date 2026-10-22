package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	authconfig "professional-meetups-monolith/backend/internal/modules/auth/config"
)

// TestRequireRealSendersInProduction is tracker #92 (review finding
// N-A9). The logging senders are right for a laptop and a silent outage
// on Cloud Run: every OTP "send" succeeds, nobody receives anything, and
// the codes themselves go to the logs. Nothing in the running service
// can tell that apart from working.
func TestRequireRealSendersInProduction(t *testing.T) {
	cloudRun := func(string) string { return "meetups-backend" }
	laptop := func(string) string { return "" }

	full := authconfig.Config{
		GmailAddress:      "ops@example.com",
		GmailAppPassword:  "secret",
		TwilioAccountSID:  "AC123",
		TwilioAuthToken:   "token",
		TwilioPhoneNumber: "+15550000000",
	}

	t.Run("fully configured starts", func(t *testing.T) {
		if err := requireRealSendersInProduction(cloudRun, full); err != nil {
			t.Errorf("a fully configured service was refused: %v", err)
		}
	})

	t.Run("Resend counts as a real email sender", func(t *testing.T) {
		cfg := full
		cfg.GmailAddress, cfg.GmailAppPassword = "", ""
		cfg.ResendAPIKey, cfg.ResendFromEmail = "re_123", "ops@example.com"
		if err := requireRealSendersInProduction(cloudRun, cfg); err != nil {
			t.Errorf("Resend-only configuration was refused: %v", err)
		}
	})

	t.Run("no email sender refuses, and says which", func(t *testing.T) {
		cfg := full
		cfg.GmailAddress, cfg.GmailAppPassword = "", ""
		err := requireRealSendersInProduction(cloudRun, cfg)
		if err == nil {
			t.Fatal("started on Cloud Run with no real email sender")
		}
		if !strings.Contains(err.Error(), "GMAIL_ADDRESS") ||
			!strings.Contains(err.Error(), "RESEND_API_KEY") {
			t.Errorf("error %q does not name the variables to set", err)
		}
	})

	t.Run("half a Twilio configuration is no Twilio", func(t *testing.T) {
		cfg := full
		cfg.TwilioAuthToken = ""
		if err := requireRealSendersInProduction(cloudRun, cfg); err == nil {
			t.Error("started on Cloud Run with an incomplete Twilio configuration")
		}
	})

	// Local development keeps working with no senders at all — that is
	// what the logging fallback is for.
	t.Run("off Cloud Run nothing is required", func(t *testing.T) {
		if err := requireRealSendersInProduction(laptop, authconfig.Config{}); err != nil {
			t.Errorf("local development was refused: %v", err)
		}
	})
}

// TestRequireRealSendersInProduction_AcceptsTheDeployedManifest runs the
// guard against exactly the environment `backend/service.yaml` declares,
// so a check meant to catch a misconfigured deploy can never become the
// reason a correctly configured one will not start.
//
// The deployed service uses Gmail SMTP and Twilio and does NOT set
// RESEND_*. That is a supported combination — the email half of the
// guard is an OR, not an AND — and this test is what keeps it supported:
// if someone tightens the guard to require Resend, or drops
// GMAIL_APP_PASSWORD from the manifest, this fails here rather than on
// the next deploy.
//
// It reads the manifest as text and asks only which env vars are
// DECLARED. Their values come from secretKeyRef at runtime and are not
// in the repository, which is correct; whether a secret resolves to a
// non-empty string is Cloud Run's business, and a revision whose secret
// is missing fails to start on its own.
func TestRequireRealSendersInProduction_AcceptsTheDeployedManifest(t *testing.T) {
	manifest, err := os.ReadFile(filepath.Join("..", "..", "service.yaml"))
	if err != nil {
		t.Fatalf("read backend/service.yaml: %v", err)
	}
	declared := func(name string) bool {
		return strings.Contains(string(manifest), "- name: "+name)
	}

	// Mirror the manifest into a config: a declared var is a set var.
	set := func(name, value string) string {
		if declared(name) {
			return value
		}
		return ""
	}
	cfg := authconfig.Config{
		GmailAddress:      set("GMAIL_ADDRESS", "ops@example.com"),
		GmailAppPassword:  set("GMAIL_APP_PASSWORD", "secret"),
		ResendAPIKey:      set("RESEND_API_KEY", "re_123"),
		ResendFromEmail:   set("RESEND_FROM_EMAIL", "ops@example.com"),
		TwilioAccountSID:  set("TWILIO_ACCOUNT_SID", "AC123"),
		TwilioAuthToken:   set("TWILIO_AUTH_TOKEN", "token"),
		TwilioPhoneNumber: set("TWILIO_PHONE_NUMBER", "+15550000000"),
	}

	if err := requireRealSendersInProduction(
		func(string) string { return "meetups-backend" }, cfg,
	); err != nil {
		t.Fatalf("the deployed manifest would be refused at startup: %v\n"+
			"backend/service.yaml declares: gmail=%v/%v resend=%v/%v twilio=%v/%v/%v",
			err,
			declared("GMAIL_ADDRESS"), declared("GMAIL_APP_PASSWORD"),
			declared("RESEND_API_KEY"), declared("RESEND_FROM_EMAIL"),
			declared("TWILIO_ACCOUNT_SID"), declared("TWILIO_AUTH_TOKEN"),
			declared("TWILIO_PHONE_NUMBER"))
	}

	// State the current shape outright, so a change to it is a decision
	// somebody makes rather than something this test quietly absorbs.
	if declared("RESEND_API_KEY") {
		t.Log("note: the manifest now declares RESEND_* as well as Gmail")
	}
}
