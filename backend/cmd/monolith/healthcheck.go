package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/platform/internalauth"
)

// healthcheckTimeout bounds the probe. Comfortably under Compose's own
// healthcheck timeout so the probe reports a failure rather than being killed
// (a killed probe and a failing one look the same to Compose, but only one of
// them says why in the logs).
const healthcheckTimeout = 3 * time.Second

// runHealthcheck is the `monolith -healthcheck` mode: dial this process's own
// gRPC port and ask the health service whether it is serving. Exits 0 for
// SERVING, non-zero otherwise.
//
// # WHY A MODE OF THIS BINARY RATHER THAN grpc-health-probe
//
// The runtime image is distroless: no shell, no curl, no package manager.
// The usual answer is to COPY a grpc-health-probe binary in, which means
// another third-party artifact to source, pin, verify and keep patched — for
// functionality this binary already contains. A `-healthcheck` flag reuses
// the gRPC client, the health protobufs and the auth interceptor that are
// already linked in, adds no dependency, and cannot drift from the server it
// probes because it ships in the same binary.
//
// It authenticates like any other caller. The health service sits behind the
// same interceptor chain as every business RPC, deliberately — an exemption
// list is a place for mistakes, and the secret is already in this container's
// environment. During a rotation the FIRST configured secret is used, which
// is always one the server accepts (see internalauth's rotation procedure:
// the accepting side is only ever widened, never narrowed, ahead of the
// sending side).
func runHealthcheck() error {
	port := os.Getenv("MONOLITH_PORT")
	if port == "" {
		return fmt.Errorf("healthcheck: MONOLITH_PORT is not set")
	}
	secrets, err := internalauth.ParseSecrets(os.Getenv("INTERNAL_GRPC_SHARED_SECRET"))
	if err != nil {
		return fmt.Errorf("healthcheck: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), healthcheckTimeout)
	defer cancel()

	// 127.0.0.1, not localhost: in a container localhost can resolve to ::1
	// first, and a server bound to a TCP port on all interfaces may not be
	// listening on IPv6 — a probe that fails for that reason looks exactly
	// like a process that is genuinely down.
	conn, err := grpc.NewClient("127.0.0.1:"+port,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(internalauth.UnaryClientInterceptor(secrets[0])),
	)
	if err != nil {
		return fmt.Errorf("healthcheck: dial: %w", err)
	}
	defer func() { _ = conn.Close() }()

	resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{Service: ""})
	if err != nil {
		return fmt.Errorf("healthcheck: %w", err)
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		return fmt.Errorf("healthcheck: status is %s", resp.GetStatus())
	}
	return nil
}
