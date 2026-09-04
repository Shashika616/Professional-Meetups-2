// Package config loads the gateway's environment configuration, matching the
// variable names backend/docker-compose.yml's `gateway` service sets locally.
package config

import (
	"fmt"
	"os"
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
	// MonolithSharedSecret authenticates this process to the monolith on
	// every gRPC call (see internal/platform/internalauth). Required, and
	// deliberately not defaulted: a gateway that silently started without it
	// would fail every request at the monolith instead, which is a much
	// harder failure to read. It must equal the monolith's own
	// INTERNAL_GRPC_SHARED_SECRET — docker-compose.yml feeds both from the
	// same .env value so they cannot drift.
	MonolithSharedSecret string
}

// Load reads Config from the environment, failing fast if any required
// variable is missing or empty.
func Load() (Config, error) {
	cfg := Config{
		Port:              os.Getenv("PORT"),
		MonolithAddr:      os.Getenv("MONOLITH_ADDR"),
		JWTPrivateKeyPath: os.Getenv("JWT_PRIVATE_KEY_PATH"),
		JWTPublicKeyPath:  os.Getenv("JWT_PUBLIC_KEY_PATH"),

		MonolithSharedSecret: os.Getenv("MONOLITH_SHARED_SECRET"),
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
