package logging

import (
	"context"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// requestIDMetadataKey is the gRPC metadata key used to propagate the
// request ID between the gateway and internal services — the gRPC analog of
// RequestIDHeader on the HTTP side.
const requestIDMetadataKey = "x-request-id"

// UnaryServerInterceptor generates or propagates a request/correlation ID
// for every unary gRPC call, mirroring HTTPMiddleware's behavior at the
// gRPC boundary: it reuses an incoming metadata value if present, otherwise
// generates one, stores it in the handler's context, and echoes it back in
// the response header metadata.
func UnaryServerInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		id := requestIDFromIncoming(ctx)
		if id == "" {
			id = NewRequestID()
		}

		// Best-effort echo: a real gRPC server context always has a
		// transport stream to attach headers to, but failing to echo the ID
		// back is not worth aborting the whole RPC over (and it's the only
		// way to unit test this interceptor without a live server).
		_ = grpc.SetHeader(ctx, metadata.Pairs(requestIDMetadataKey, id))

		return handler(WithRequestID(ctx, id), req)
	}
}

func requestIDFromIncoming(ctx context.Context) string {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return ""
	}
	values := md.Get(requestIDMetadataKey)
	if len(values) == 0 {
		return ""
	}
	return values[0]
}
