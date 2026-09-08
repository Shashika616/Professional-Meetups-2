package logging

import (
	"context"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// MetricsUnaryServerInterceptor records per-method call counts and latencies
// (§D3).
//
// Labelled by full method name, which is a bounded set fixed at compile time
// — no cardinality risk, unlike labelling by anything caller-supplied. The
// gRPC status code is likewise a small enum.
//
// Placed OUTSIDE the deadline and recovery interceptors so a call that times
// out or panics is still counted; a metric that only sees successes is worse
// than none, because it looks healthy exactly when things are not.
func MetricsUnaryServerInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		metrics.Default.ObserveGRPC(info.FullMethod, status.Code(err).String(), time.Since(start))
		return resp, err
	}
}
