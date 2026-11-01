// Package config loads the analytics module's environment settings (plan 29
// §4.3, ADR-011).
package config

import (
	"errors"
	"fmt"
	"net/mail"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// DefaultRawRetentionDays is how long raw events stay in Postgres before
// they are archived and their partition dropped (Supabase's free storage).
const DefaultRawRetentionDays = 14

// MinSecretLength is the shortest user-key secret accepted: an HMAC-SHA256
// key shorter than 32 bytes is weaker than the hash.
const MinSecretLength = 32

// localSecret keys user_key off Cloud Run when no secret is set, so a local
// run works out of the box and its keys are stable across restarts. It is in
// a public repository and protects nothing; production never uses it.
const localSecret = "local-development-analytics-user-key-not-a-secret"

// bucketName is a Cloud Storage bucket name (lowercase, digits, dot,
// underscore, dash; 3 to 63 characters). Checked so the archive URL is
// never built from something unexpected.
var bucketName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$`)

// Config is the analytics module's settings.
type Config struct {
	// UserKeySecret keys user_key = HMAC-SHA256(user id). From Secret
	// Manager (ANALYTICS_USER_KEY_SECRET) in production.
	UserKeySecret []byte `json:"-"`
	// Disabled is true in production when the secret is missing or too
	// short: nothing is collected rather than collected under a weak key.
	Disabled bool
	// DisabledReason says why, for the start-up log line.
	DisabledReason string
	// ArchiveBucket is where raw partitions are written before they are
	// dropped (ANALYTICS_ARCHIVE_BUCKET). Empty skips the archive.
	ArchiveBucket string
	// RawRetentionDays is ANALYTICS_RAW_RETENTION_DAYS (1 to 90, default 14).
	RawRetentionDays int
	// Production is true on Cloud Run (K_SERVICE is set).
	Production bool
	// ReportRecipients get the daily report by email
	// (ANALYTICS_REPORT_RECIPIENTS, comma-separated). Empty: not emailed.
	ReportRecipients []string `json:"-"`
}

// MaxReportRecipients bounds the list: the report is for the team.
const MaxReportRecipients = 20

// Load reads the settings from the environment.
func Load() (Config, error) { return LoadFrom(os.Getenv) }

// LoadFrom reads the settings through getenv.
func LoadFrom(getenv func(string) string) (Config, error) {
	cfg := Config{
		Production:       getenv("K_SERVICE") != "",
		ArchiveBucket:    getenv("ANALYTICS_ARCHIVE_BUCKET"),
		RawRetentionDays: DefaultRawRetentionDays,
	}
	if raw := getenv("ANALYTICS_RAW_RETENTION_DAYS"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 90 {
			return Config{}, fmt.Errorf("config: ANALYTICS_RAW_RETENTION_DAYS %q is not a number of days from 1 to 90", raw)
		}
		cfg.RawRetentionDays = n
	}
	if cfg.ArchiveBucket != "" && !bucketName.MatchString(cfg.ArchiveBucket) {
		return Config{}, errors.New("config: ANALYTICS_ARCHIVE_BUCKET is not a valid bucket name")
	}

	if raw := strings.TrimSpace(getenv("ANALYTICS_REPORT_RECIPIENTS")); raw != "" {
		for _, addr := range strings.Split(raw, ",") {
			addr = strings.TrimSpace(addr)
			if addr == "" {
				continue
			}
			if _, err := mail.ParseAddress(addr); err != nil || strings.ContainsAny(addr, "<> \r\n") {
				return Config{}, errors.New("config: ANALYTICS_REPORT_RECIPIENTS holds something that is not a plain email address")
			}
			cfg.ReportRecipients = append(cfg.ReportRecipients, addr)
		}
		if len(cfg.ReportRecipients) > MaxReportRecipients {
			return Config{}, fmt.Errorf("config: ANALYTICS_REPORT_RECIPIENTS lists more than %d addresses", MaxReportRecipients)
		}
	}

	secret := getenv("ANALYTICS_USER_KEY_SECRET")
	switch {
	case len(secret) >= MinSecretLength:
		cfg.UserKeySecret = []byte(secret)
	case cfg.Production && secret == "":
		cfg.Disabled, cfg.DisabledReason = true, "ANALYTICS_USER_KEY_SECRET is not set"
	case cfg.Production:
		cfg.Disabled, cfg.DisabledReason = true, fmt.Sprintf("ANALYTICS_USER_KEY_SECRET is shorter than %d bytes", MinSecretLength)
	default:
		cfg.UserKeySecret = []byte(localSecret)
	}
	return cfg, nil
}
