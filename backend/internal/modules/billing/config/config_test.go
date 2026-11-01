package config

import (
	"errors"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

// 29B: the fake store believes any token, so it must be impossible to run
// it on Cloud Run.
func TestFakeStoreIsRefusedOnCloudRun(t *testing.T) {
	if _, err := LoadFrom(env(map[string]string{"BILLING_STORE": "fake", "K_SERVICE": "monolith"})); !errors.Is(err, ErrFakeStoreInProduction) {
		t.Fatalf("fake store on Cloud Run: err = %v, want ErrFakeStoreInProduction", err)
	}
	cfg, err := LoadFrom(env(map[string]string{"BILLING_STORE": "fake"}))
	if err != nil || cfg.Store != StoreFake || cfg.Production {
		t.Fatalf("fake store locally = %+v, %v", cfg, err)
	}
	if _, err := LoadFrom(env(map[string]string{"BILLING_STORE": "trusting"})); err == nil {
		t.Fatal("an unknown BILLING_STORE was accepted")
	}
}

func TestDefaultsAndValidation(t *testing.T) {
	cfg, err := LoadFrom(env(map[string]string{"K_SERVICE": "monolith"}))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Production || cfg.AppleConfigured() || cfg.GoogleConfigured() ||
		cfg.AppleBundleID != DefaultAppleBundleID || cfg.GooglePackageName != DefaultGooglePackageName {
		t.Fatalf("defaults = %+v", cfg)
	}
	if _, err := LoadFrom(env(map[string]string{"BILLING_TERMS_URL": "http://example.com/terms"})); err == nil {
		t.Fatal("a non-https terms URL was accepted")
	}
	cfg, err = LoadFrom(env(map[string]string{
		"APPLE_APP_STORE_ISSUER_ID": "i", "APPLE_APP_STORE_KEY_ID": "k", "APPLE_APP_STORE_PRIVATE_KEY": "p",
		"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": "{}",
	}))
	if err != nil || !cfg.AppleConfigured() || !cfg.GoogleConfigured() {
		t.Fatalf("configured = %+v, %v", cfg, err)
	}
}
