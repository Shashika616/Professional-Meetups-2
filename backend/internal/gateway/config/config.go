// Package config loads the gateway's environment configuration, matching the
// variable names backend/docker-compose.yml's `gateway` service sets locally.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is loaded once at startup. Every field here is required and
// actually used — a missing value fails Load() outright rather than leaving
// a zero-value default that surfaces as a confusing failure on the first
// request that needs it.
//
// Two differences from the sibling repo's gateway config, both structural:
//
//   - MonolithAddr replaces AUTH_SERVICE_ADDR/MEETUP_SERVICE_ADDR/
//     BILLING_SERVICE_ADDR. One gRPC target instead of three (ADR-001 §1).
//     It is required, unlike the source's optional BILLING_SERVICE_ADDR:
//     there is no "half the backend is deployed" state to tolerate any more.
//   - There is no REDIS_ADDR at all. Rate limiting is in-memory (ADR-001 §5)
//     and needs no connection string.
//
// And one addition: JWTPrivateKeyPath. The gateway signs tokens now
// (ADR-001 §6), so it needs both halves of the keypair — the private key to
// issue, the public key to verify on every subsequent request.
type Config struct {
	Port              string
	MonolithAddr      string
	JWTPrivateKeyPath string
	JWTPublicKeyPath  string
	// JWTPreviousPublicKeyPaths are public keys from a signing key that has
	// been rotated out but whose tokens may still be in flight (§A3).
	// Optional and normally empty — it is set only for the deploy that
	// performs a rotation, and removed again once AccessTokenTTL has elapsed.
	// Comma-separated; see internal/platform/jwt's Verifier doc for the
	// procedure.
	JWTPreviousPublicKeyPaths []string
	// MonolithSharedSecret authenticates this process to the monolith on
	// every gRPC call (see internal/platform/internalauth). Required, and
	// deliberately not defaulted: a gateway that silently started without it
	// would fail every request at the monolith instead, which is a much
	// harder failure to read. It must equal the monolith's own
	// INTERNAL_GRPC_SHARED_SECRET — docker-compose.yml feeds both from the
	// same .env value so they cannot drift.
	MonolithSharedSecret string

	// CronSharedSecret authenticates Cloud Scheduler to
	// POST /internal/cron/tick. DELIBERATELY OPTIONAL: empty means the
	// route is not mounted at all, which is the right default for local
	// development and for the test stack, where the in-process tickers
	// already run and nothing needs to drive them from outside.
	//
	// On Cloud Run it is required in practice — the service scales to zero,
	// so without it no periodic work ever runs — but that is enforced by
	// the deployment (runbook §10), not here. A gateway that refused to
	// start without it would break every local `docker compose up`.
	CronSharedSecret string

	// TrustedProxyHops is how many proxies in front of the gateway append to
	// X-Forwarded-For, so the rate limiter can find the real client (#81).
	// 0 (unset) ignores the header — right locally, where nothing sits in
	// front. Cloud Run needs 1: see middleware.WithTrustedProxyHops.
	TrustedProxyHops int

	// MetricsToken, when set, is the bearer token GET /metrics requires.
	// Unset on Cloud Run means /metrics is not served at all (#93); unset
	// locally means it is open. See handlers.MetricsAccess.
	MetricsToken string

	// OnCloudRun is true when K_SERVICE is set, which Cloud Run always sets
	// and nothing else here does.
	OnCloudRun bool
}

// Load reads Config from the environment, failing fast if any required
// variable is missing or empty.
func Load() (Config, error) {
	cfg := Config{
		Port:              os.Getenv("PORT"),
		MonolithAddr:      os.Getenv("MONOLITH_ADDR"),
		JWTPrivateKeyPath: os.Getenv("JWT_PRIVATE_KEY_PATH"),
		JWTPublicKeyPath:  os.Getenv("JWT_PUBLIC_KEY_PATH"),

		JWTPreviousPublicKeyPaths: splitPaths(os.Getenv("JWT_PREVIOUS_PUBLIC_KEY_PATHS")),

		MonolithSharedSecret: os.Getenv("MONOLITH_SHARED_SECRET"),
		CronSharedSecret:     os.Getenv("CRON_SHARED_SECRET"),
		MetricsToken:         os.Getenv("METRICS_TOKEN"),
		OnCloudRun:           os.Getenv("K_SERVICE") != "",
	}

	if raw := os.Getenv("TRUSTED_PROXY_HOPS"); raw != "" {
		hops, err := strconv.Atoi(raw)
		if err != nil || hops < 0 || hops > 5 {
			return Config{}, fmt.Errorf("config: TRUSTED_PROXY_HOPS must be an integer from 0 to 5, got %q", raw)
		}
		cfg.TrustedProxyHops = hops
	}

	required := []struct {
		name  string
		value string
	}{
		{"PORT", cfg.Port},
		{"MONOLITH_ADDR", cfg.MonolithAddr},
		{"JWT_PRIVATE_KEY_PATH", cfg.JWTPrivateKeyPath},
		{"JWT_PUBLIC_KEY_PATH", cfg.JWTPublicKeyPath},
		{"MONOLITH_SHARED_SECRET", cfg.MonolithSharedSecret},
	}
	for _, req := range required {
		if req.value == "" {
			return Config{}, fmt.Errorf("config: required environment variable %s is not set", req.name)
		}
	}

	return cfg, nil
}

// splitPaths parses a comma-separated, optional path list. Empty elements
// are dropped rather than becoming an empty path that would fail to open
// with a confusing message — a trailing comma is a typo, not a request to
// load "".
func splitPaths(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
