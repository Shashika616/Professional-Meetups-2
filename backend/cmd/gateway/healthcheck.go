package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

// runHealthcheck is the `gateway -healthcheck` mode: hit this process's own
// /healthz and exit 0 if it is up.
//
// Same reasoning as the monolith's equivalent (cmd/monolith/healthcheck.go) —
// the runtime image is distroless, so there is no shell and no curl for a
// CMD-SHELL healthcheck, and a mode of this binary needs no extra artifact.
//
// It probes /healthz (liveness), NOT /readyz. A container healthcheck drives
// restarts, and restarting the gateway because the monolith is briefly
// unreachable would turn one component's problem into two. Readiness — "should
// traffic be routed here" — is a different question with a different endpoint
// and a different consumer.
func runHealthcheck() error {
	port := os.Getenv("PORT")
	if port == "" {
		return fmt.Errorf("healthcheck: PORT is not set")
	}

	client := &http.Client{Timeout: 3 * time.Second}
	// 127.0.0.1 rather than localhost: in a container localhost can resolve
	// to ::1 first, and a server listening only on IPv4 would then fail a
	// probe in a way indistinguishable from being down.
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return fmt.Errorf("healthcheck: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthcheck: /healthz returned %d", resp.StatusCode)
	}
	return nil
}
