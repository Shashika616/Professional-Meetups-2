package config

import (
	"encoding/json"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestDefaults(t *testing.T) {
	cfg, err := LoadFrom(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Disabled || cfg.RawRetentionDays != 14 || cfg.ArchiveBucket != "" || len(cfg.UserKeySecret) == 0 {
		t.Errorf("cfg = %+v", cfg)
	}
}

func TestProductionWithoutASecretIsDisabled(t *testing.T) {
	cfg, err := LoadFrom(env(map[string]string{"K_SERVICE": "monolith"}))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Disabled || cfg.UserKeySecret != nil || !strings.Contains(cfg.DisabledReason, "not set") {
		t.Errorf("cfg = %+v", cfg)
	}
	cfg, _ = LoadFrom(env(map[string]string{"K_SERVICE": "monolith", "ANALYTICS_USER_KEY_SECRET": "short"}))
	if !cfg.Disabled {
		t.Error("a short secret was accepted in production")
	}
	cfg, _ = LoadFrom(env(map[string]string{"K_SERVICE": "monolith", "ANALYTICS_USER_KEY_SECRET": strings.Repeat("k", 32)}))
	if cfg.Disabled || string(cfg.UserKeySecret) != strings.Repeat("k", 32) {
		t.Errorf("cfg = %+v", cfg)
	}
}

func TestBadValuesAreRefused(t *testing.T) {
	for _, m := range []map[string]string{
		{"ANALYTICS_RAW_RETENTION_DAYS": "0"},
		{"ANALYTICS_RAW_RETENTION_DAYS": "91"},
		{"ANALYTICS_RAW_RETENTION_DAYS": "two weeks"},
		{"ANALYTICS_ARCHIVE_BUCKET": "Bad Bucket/../x"},
		{"ANALYTICS_REPORT_RECIPIENTS": "ops@example.com, not an address"},
		{"ANALYTICS_REPORT_RECIPIENTS": "Ops <ops@example.com>"},
		{"ANALYTICS_REPORT_RECIPIENTS": "a@b.co\r\nBcc: x@evil.test"},
	} {
		if _, err := LoadFrom(env(m)); err == nil {
			t.Errorf("%v accepted", m)
		}
	}
}

func TestTheSecretIsNeverMarshalled(t *testing.T) {
	cfg, _ := LoadFrom(env(map[string]string{"ANALYTICS_USER_KEY_SECRET": strings.Repeat("s", 40)}))
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "sss") {
		t.Errorf("the secret is in %s", raw)
	}
}

func TestReportRecipients(t *testing.T) {
	cfg, err := LoadFrom(env(map[string]string{"ANALYTICS_REPORT_RECIPIENTS": " ops@example.com, ,founder@example.com "}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cfg.ReportRecipients, "|") != "ops@example.com|founder@example.com" {
		t.Errorf("recipients = %v", cfg.ReportRecipients)
	}
	raw, _ := json.Marshal(cfg)
	if strings.Contains(string(raw), "founder@") {
		t.Errorf("recipients are marshalled: %s", raw)
	}
}
