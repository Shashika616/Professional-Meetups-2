package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// MonolithHealthChecker is the narrow slice of the monolith client /readyz
// needs. An interface so a test can drive both the healthy and unreachable
// cases without standing up a real gRPC server.
type MonolithHealthChecker interface {
	CheckHealth(ctx context.Context) error
}

// readinessTimeout bounds the dependency check /readyz performs. Short on
// purpose: a readiness probe that hangs is worse than one that fails, because
// an orchestrator waiting on it learns nothing while the timeout it actually
// enforces runs down.
const readinessTimeout = 2 * time.Second

// RegisterObservability mounts /healthz, /readyz and /metrics (§D3).
//
// Deliberately OUTSIDE the versioned /v1 API surface and outside the
// authenticated route set: these are operator endpoints, and a probe that
// needs a bearer token is a probe that cannot run.
//
// # WHY /healthz AND /readyz ARE DIFFERENT ENDPOINTS
//
// They answer different questions and an orchestrator acts on them
// differently. /healthz is liveness: "is this process functioning, or should
// it be restarted?" It must NOT consult dependencies — a monolith outage
// answering /healthz with a failure would get every gateway replica killed
// and restarted, turning a recoverable downstream problem into a full
// outage. /readyz is readiness: "should traffic be routed here right now?"
// It does check the monolith, because a gateway that cannot reach it can
// serve nothing but errors and should be taken out of rotation until it can.
func RegisterObservability(mux *http.ServeMux, monolith MonolithHealthChecker) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeStatusJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), readinessTimeout)
		defer cancel()

		if err := monolith.CheckHealth(ctx); err != nil {
			// The reason is deliberately generic. This endpoint is
			// unauthenticated, and the underlying error can name internal
			// hostnames, ports and gRPC internals — detail that belongs in
			// the logs, not in a response anyone can curl.
			writeStatusJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "unavailable",
				"reason": "monolith is not reachable",
			})
			return
		}
		writeStatusJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.Handle("GET /metrics", metrics.Handler())
}

func writeStatusJSON(w http.ResponseWriter, status int, body map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// grpcHealthClient adapts the standard gRPC health service to
// MonolithHealthChecker.
type grpcHealthClient struct{ client healthpb.HealthClient }

// NewMonolithHealthChecker wraps a gRPC connection's health client.
func NewMonolithHealthChecker(client healthpb.HealthClient) MonolithHealthChecker {
	return &grpcHealthClient{client: client}
}

func (c *grpcHealthClient) CheckHealth(ctx context.Context) error {
	// Empty service name means "the server as a whole", which is what the
	// monolith registers under.
	resp, err := c.client.Check(ctx, &healthpb.HealthCheckRequest{Service: ""})
	if err != nil {
		return err
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		return errNotServing
	}
	return nil
}

var errNotServing = &notServingError{}

type notServingError struct{}

func (*notServingError) Error() string { return "monolith reports NOT_SERVING" }
