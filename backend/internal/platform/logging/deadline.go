package logging

import (
	"context"
	"time"

	"google.golang.org/grpc"
)

// DefaultRPCTimeout bounds how long any single gRPC handler may run (§B2).
//
// This is the PRIMARY control; db.StatementTimeout is the backstop beneath
// it. The two are complementary rather than redundant: statement_timeout
// bounds one SQL statement, while this bounds the whole handler — a method
// that runs six fast queries and an external HTTP call can exceed every
// per-statement limit while still hanging the request, and only a
// handler-level deadline catches that.
//
// 10 seconds matches the gateway's own ReadTimeout/WriteTimeout posture, so
// a request cannot be alive at the monolith after the gateway has already
// given up on it and returned to the client — work continuing on behalf of a
// caller that stopped listening is exactly how a pool gets drained during an
// incident.
const DefaultRPCTimeout = 10 * time.Second

// DeadlineUnaryServerInterceptor gives every incoming RPC a bounded context.
//
// A CALLER-SUPPLIED DEADLINE IS HONOURED WHEN IT IS SHORTER, never when it
// is longer. gRPC propagates the client's deadline into the handler context,
// and a well-behaved gateway sets a sensible one — but the server must not
// let a caller opt out of its limits, and a caller that sets no deadline at
// all (or a generous one) must not thereby get unbounded server-side
// execution. Taking the minimum is what makes this a server-side guarantee
// rather than a suggestion.
//
// Placed early in the chain, before the shared-secret check and recovery, so
// the bound covers authentication and every layer beneath it too.
func DeadlineUnaryServerInterceptor(timeout time.Duration) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= timeout {
			// The caller already asked for something at least as strict.
			// Wrapping it again would only add a redundant timer.
			return handler(ctx, req)
		}

		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		return handler(ctx, req)
	}
}
