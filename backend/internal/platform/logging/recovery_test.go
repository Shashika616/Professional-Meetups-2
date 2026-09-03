package logging

import (
	"context"
	"log/slog"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TestRecoveryUnaryServerInterceptor_ConvertsPanicToInternalError guards
// the actual gap this interceptor closes: a panicking handler (e.g.
// services/meetup's mustParseUUID on a malformed cursor id) used to crash
// the whole gRPC server process, since nothing recovered it. Now it must
// come back as a normal Internal gRPC error instead.
func TestRecoveryUnaryServerInterceptor_ConvertsPanicToInternalError(t *testing.T) {
	interceptor := RecoveryUnaryServerInterceptor(slog.New(slog.DiscardHandler))

	handler := func(ctx context.Context, req any) (any, error) {
		panic("boom")
	}

	_, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{FullMethod: "/test/Method"}, handler)
	if err == nil {
		t.Fatal("interceptor returned nil error after a panic, want a converted error")
	}
	if got := status.Code(err); got != codes.Internal {
		t.Errorf("status code = %v, want %v", got, codes.Internal)
	}
}

func TestRecoveryUnaryServerInterceptor_PassesThroughOnNoPanic(t *testing.T) {
	interceptor := RecoveryUnaryServerInterceptor(slog.New(slog.DiscardHandler))

	handler := func(ctx context.Context, req any) (any, error) {
		return "ok", nil
	}

	resp, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{}, handler)
	if err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}
	if resp != "ok" {
		t.Errorf("resp = %v, want %q", resp, "ok")
	}
}
