package logging

import (
	"context"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

func TestUnaryServerInterceptorGeneratesRequestID(t *testing.T) {
	var seenID string
	handler := func(ctx context.Context, req any) (any, error) {
		seenID = RequestIDFromContext(ctx)
		return nil, nil
	}

	interceptor := UnaryServerInterceptor()
	_, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{}, handler)
	if err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}

	if seenID == "" {
		t.Fatal("handler saw no request ID in context")
	}
}

func TestUnaryServerInterceptorPropagatesIncomingRequestID(t *testing.T) {
	var seenID string
	handler := func(ctx context.Context, req any) (any, error) {
		seenID = RequestIDFromContext(ctx)
		return nil, nil
	}

	md := metadata.Pairs(requestIDMetadataKey, "caller-supplied-id")
	ctx := metadata.NewIncomingContext(context.Background(), md)

	interceptor := UnaryServerInterceptor()
	if _, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{}, handler); err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}

	if seenID != "caller-supplied-id" {
		t.Errorf("seenID = %q, want %q", seenID, "caller-supplied-id")
	}
}
