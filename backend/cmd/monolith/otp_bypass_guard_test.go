package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRefuseGlobalOTPBypassOnCloudRun is tracker #92 (review finding
// N-A6): the global test-OTP bypass must be a startup failure on Cloud
// Run, not a log line somebody might read.
//
// The last two cases are the ones that matter for TESTING-NOTES.md: the
// SCOPED mechanisms are deliberately untouched by this guard and stay
// usable everywhere, because they are safe by construction
// (TEST_OTP_BYPASS_EMAILS is restricted to reserved test TLDs,
// TEST_OTP_BYPASS_PHONES is an exact-match allowlist). Only the global
// flag — every purpose, every account — is refused.
func TestRefuseGlobalOTPBypassOnCloudRun(t *testing.T) {
	env := func(pairs map[string]string) func(string) string {
		return func(k string) string { return pairs[k] }
	}

	t.Run("refuses the global bypass on Cloud Run", func(t *testing.T) {
		err := refuseGlobalOTPBypassOnCloudRun(env(map[string]string{
			"ALLOW_TEST_OTP_BYPASS": "true",
			"K_SERVICE":             "meetups-backend",
		}))
		if err == nil {
			t.Fatal("started with the global OTP bypass on Cloud Run")
		}
		// The message has to tell whoever sees the failed deploy what to
		// do instead, or it just gets switched off again.
		for _, want := range []string{"meetups-backend", "TEST_OTP_BYPASS_EMAILS", "TESTING-NOTES.md"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error %q does not mention %q", err, want)
			}
		}
	})

	t.Run("allows the global bypass off Cloud Run", func(t *testing.T) {
		if err := refuseGlobalOTPBypassOnCloudRun(env(map[string]string{
			"ALLOW_TEST_OTP_BYPASS": "true",
		})); err != nil {
			t.Errorf("local development refused: %v", err)
		}
	})

	t.Run("allows Cloud Run without the global bypass", func(t *testing.T) {
		if err := refuseGlobalOTPBypassOnCloudRun(env(map[string]string{
			"K_SERVICE": "meetups-backend",
		})); err != nil {
			t.Errorf("ordinary Cloud Run startup refused: %v", err)
		}
	})

	t.Run("leaves the scoped email allowlist alone on Cloud Run", func(t *testing.T) {
		if err := refuseGlobalOTPBypassOnCloudRun(env(map[string]string{
			"K_SERVICE":              "meetups-backend",
			"TEST_OTP_BYPASS_EMAILS": "l3.a@meetups.test,l3.b@meetups.test",
			"TEST_OTP_BYPASS_PHONES": "+94770000001",
		})); err != nil {
			t.Errorf("the scoped allowlists must keep working: %v", err)
		}
	})

	t.Run("a value other than true is not the flag", func(t *testing.T) {
		if err := refuseGlobalOTPBypassOnCloudRun(env(map[string]string{
			"ALLOW_TEST_OTP_BYPASS": "1",
			"K_SERVICE":             "meetups-backend",
		})); err != nil {
			t.Errorf("only the literal \"true\" enables the bypass: %v", err)
		}
	})
}

// TestRefuseGlobalOTPBypassOnCloudRun_AcceptsTheDeployedManifest is the
// other half of the "a guard must not break a correct deploy" pair (see
// sender_guard_test.go). The deployed manifest pins
// ALLOW_TEST_OTP_BYPASS to "false" and relies on the SCOPED allowlists,
// which this guard deliberately leaves alone.
func TestRefuseGlobalOTPBypassOnCloudRun_AcceptsTheDeployedManifest(t *testing.T) {
	manifest, err := os.ReadFile(filepath.Join("..", "..", "service.yaml"))
	if err != nil {
		t.Fatalf("read backend/service.yaml: %v", err)
	}
	text := string(manifest)

	// Read the value the manifest actually sets, rather than assuming it.
	value := ""
	if idx := strings.Index(text, "- name: ALLOW_TEST_OTP_BYPASS"); idx >= 0 {
		rest := text[idx:]
		if v := strings.Index(rest, "value: "); v >= 0 {
			value = strings.Trim(strings.SplitN(rest[v+len("value: "):], "\n", 2)[0], `" `)
		}
	}

	err = refuseGlobalOTPBypassOnCloudRun(func(name string) string {
		switch name {
		case "ALLOW_TEST_OTP_BYPASS":
			return value
		case "K_SERVICE":
			return "meetups-backend"
		}
		return ""
	})
	if err != nil {
		t.Fatalf("the deployed manifest would be refused at startup: %v\n"+
			"backend/service.yaml sets ALLOW_TEST_OTP_BYPASS=%q", err, value)
	}
}
