package logging

import (
	"context"
	"fmt"
	"log/slog"
	"runtime/debug"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// RecoveryUnaryServerInterceptor converts a panic anywhere in a handler
// into a gRPC Internal error instead of crashing the whole process — the
// gRPC-server analog of the gateway's own middleware.Recover
// (services/gateway/internal/middleware/recover.go), which documents the
// same principle at the HTTP boundary ("panics in request-handling paths
// become 500s via a recovery middleware, not crashes"); that principle was
// never carried through to the gRPC servers themselves until a real panic
// (services/meetup's decodeCursor accepting a non-UUID cursor id, reaching
// repository.mustParseUUID's panic several layers downstream) showed the
// gap. Should sit closest to the actual handler in the interceptor chain
// (chained after UnaryServerInterceptor, so the request id it attaches to
// the context is already present when a panic here is logged).
func RecoveryUnaryServerInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
		defer func() {
			if rec := recover(); rec != nil {
				FromContext(ctx, logger).Error("panic recovered",
					"method", info.FullMethod,
					"panic", fmt.Sprint(rec),
					"stack", string(debug.Stack()),
				)
				err = status.Error(codes.Internal, "internal server error")
			}
		}()
		return handler(ctx, req)
	}
}
