// Package internalauth authenticates the gateway→monolith gRPC hop with a
// static shared secret carried in request metadata.
//
// WHY THIS EXISTS (ADR-001's 2026-09-04 correction): every method on the
// monolith's gRPC service trusts its caller's identity fields — `user_id`
// comes off the request, and the module acts on it. That is correct as long
// as the ONLY thing that can reach the port is the gateway, which verified a
// JWT before setting those fields. Until now, nothing in code enforced that:
// the guarantee rested entirely on Docker network isolation. Anything that
// could reach the monolith's port could act as any user, and a misconfigured
// network or a future second caller would break that silently.
//
// The source system has the same gap, protected by the same kind of
// topology assumption, so this is not a regression the port introduced — but
// it is not something to carry forward silently now that it has been named.
//
// SCOPE, deliberately: this is a shared secret, NOT mutual TLS. It closes
// "any caller that reaches the port can impersonate any user"; it does not
// protect against an attacker who can already read the monolith's or the
// gateway's environment (they'd have the secret), and it does not encrypt
// the hop. For a two-process, single-tenant system on a private network that
// is the right amount of mechanism: mTLS would add certificate issuance,
// rotation and expiry-monitoring for the same threat this closes. If the
// monolith ever becomes reachable from an untrusted network, or gains a
// second independent caller with different privileges, revisit this rather
// than assuming a static secret still suffices.
//
// Both halves live in this one package on purpose: the metadata key and the
// comparison have to agree exactly, and splitting them across the gateway
// and monolith trees is how they drift.
package internalauth

import (
	"context"
	"crypto/subtle"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// MetadataKey is the gRPC metadata key carrying the shared secret. Lowercase
// because gRPC normalizes metadata keys to lowercase — writing it lowercase
// here keeps lookups and writes symmetric.
const MetadataKey = "x-internal-auth"

// UnaryServerInterceptor rejects any call that doesn't present the expected
// secret, before the handler — and therefore before any business logic or
// database access — runs.
//
// Comparison is constant-time: a byte-at-a-time `==` on a secret an attacker
// can retry at will is exactly the shape that leaks it, and this codebase
// already applies the same discipline to OTP and nonce comparison.
//
// A missing key, an empty value, or a wrong value are all the same
// Unauthenticated rejection with the same message — distinguishing them
// would tell a prober how far along it is.
func UnaryServerInterceptor(secret string) grpc.UnaryServerInterceptor {
	expected := []byte(secret)

	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if !authorized(ctx, expected) {
			return nil, status.Error(codes.Unauthenticated, "internal authentication failed")
		}
		return handler(ctx, req)
	}
}

func authorized(ctx context.Context, expected []byte) bool {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return false
	}
	values := md.Get(MetadataKey)
	if len(values) != 1 {
		// Zero values is the missing case. More than one is a caller doing
		// something strange enough not to trust — accepting "any of these
		// matches" would let a caller brute-force several guesses per call.
		return false
	}
	return subtle.ConstantTimeCompare([]byte(values[0]), expected) == 1
}

// UnaryClientInterceptor attaches the shared secret to every outgoing call.
// Applied once at connection construction rather than per call site, so a
// method added later can't forget it.
func UnaryClientInterceptor(secret string) grpc.UnaryClientInterceptor {
	return func(
		ctx context.Context, method string, req, reply any,
		cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption,
	) error {
		ctx = metadata.AppendToOutgoingContext(ctx, MetadataKey, secret)
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}
