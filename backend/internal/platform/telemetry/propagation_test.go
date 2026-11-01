package telemetry_test

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/test/bufconn"
)

// Plan 29D: one trace across the gateway and the monolith. The gateway's
// HTTP server span (otelhttp), its gRPC client span and the monolith's gRPC
// server span (otelgrpc, from the W3C traceparent on the wire) must share a
// trace id. This is the same wiring as cmd/gateway and cmd/monolith, in one
// process, with a recording exporter.
func TestTraceContextPropagatesGatewayToMonolith(t *testing.T) {
	rec := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(rec))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() { _ = tp.Shutdown(context.Background()) })

	// The "monolith": a gRPC server with otelgrpc's server handler.
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.StatsHandler(otelgrpc.NewServerHandler()))
	healthpb.RegisterHealthServer(srv, health.NewServer())
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	// The "gateway": an HTTP handler behind otelhttp that calls it with
	// otelgrpc's client handler.
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	client := healthpb.NewHealthClient(conn)
	gateway := otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := client.Check(r.Context(), &healthpb.HealthCheckRequest{}); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusOK)
	}), "gateway")

	rr := httptest.NewRecorder()
	gateway.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/anything", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rr.Code, rr.Body.String())
	}
	_ = tp.ForceFlush(context.Background())

	kinds := map[trace.SpanKind]trace.TraceID{}
	for _, s := range rec.Ended() {
		kinds[s.SpanKind()] = s.SpanContext().TraceID()
	}
	httpServer, grpcClient, grpcServer := kinds[trace.SpanKindServer], kinds[trace.SpanKindClient], trace.TraceID{}
	// Two server spans exist (HTTP and gRPC); find the gRPC one by name.
	for _, s := range rec.Ended() {
		if s.SpanKind() == trace.SpanKindServer && s.Name() != "gateway" {
			grpcServer = s.SpanContext().TraceID()
		}
		if s.SpanKind() == trace.SpanKindServer && s.Name() == "gateway" {
			httpServer = s.SpanContext().TraceID()
		}
	}
	if !httpServer.IsValid() || !grpcServer.IsValid() || !grpcClient.IsValid() {
		t.Fatalf("missing spans: %d recorded", len(rec.Ended()))
	}
	if httpServer != grpcClient || grpcClient != grpcServer {
		t.Fatalf("trace ids differ: http %s, grpc client %s, grpc server %s", httpServer, grpcClient, grpcServer)
	}
}
