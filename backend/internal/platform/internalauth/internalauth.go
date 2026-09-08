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
//
// # ROTATION (§A2)
//
// The server side accepts a SET of secrets, not one. With a single static
// secret on both sides, rotating it meant restarting the gateway and the
// monolith with the new value at effectively the same instant — every call
// in between failing closed. Accepting several lets a rotation be three
// ordinary deploys with no coordinated restart and no failure window:
//
//  1. Deploy the monolith accepting BOTH old and new
//     (INTERNAL_GRPC_SHARED_SECRET="<old>,<new>"). The gateway still sends
//     the old one; nothing changes for it.
//  2. Deploy the gateway sending only the new one
//     (MONOLITH_SHARED_SECRET="<new>"). The monolith already accepts it.
//  3. Deploy the monolith accepting only the new one
//     (INTERNAL_GRPC_SHARED_SECRET="<new>"). The old secret is now dead.
//
// Each step is independently safe to roll back, and at no point is there an
// instant where a valid caller is rejected. The CLIENT side stays
// single-valued deliberately — a client with two secrets would have to guess
// which one a given server accepts, and the whole point of the overlap is
// that it lives on the accepting side.
//
// The list is comma-separated. Secrets are expected to be base64 (that is
// what backend/secrets/README.md's generation command produces), whose
// alphabet contains no comma, so this is unambiguous for the values this
// system actually uses — ParseSecrets rejects anything that would make it
// ambiguous rather than silently splitting a secret in half.
package internalauth

import (
	"context"
	"crypto/subtle"
	"fmt"
	"strings"

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
// accepted is the list of secrets the server will honour, in the order
// given. Callers build it with ParseSecrets.
func UnaryServerInterceptor(accepted []string) grpc.UnaryServerInterceptor {
	expected := make([][]byte, 0, len(accepted))
	for _, s := range accepted {
		expected = append(expected, []byte(s))
	}

	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if !authorized(ctx, expected) {
			return nil, status.Error(codes.Unauthenticated, "internal authentication failed")
		}
		return handler(ctx, req)
	}
}

// ParseSecrets splits a comma-separated environment value into the set of
// secrets a server accepts, rejecting anything malformed rather than
// silently accepting a degraded configuration.
//
// The failure modes it refuses are the ones that would quietly weaken this
// check: an empty value (no secret at all), an empty element from a stray
// or trailing comma (which would otherwise make the empty string a VALID
// secret, i.e. accept any caller that sends an empty header), and duplicate
// entries (harmless but always a config mistake worth surfacing). Surrounding
// whitespace is trimmed per element, because a multi-line .env or a
// copy-paste in a compose file routinely introduces it and a secret that
// differs only by a space fails in a way that is genuinely hard to see.
func ParseSecrets(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, fmt.Errorf("internalauth: no shared secret configured")
	}

	seen := make(map[string]struct{})
	var out []string
	for i, part := range strings.Split(raw, ",") {
		secret := strings.TrimSpace(part)
		if secret == "" {
			return nil, fmt.Errorf("internalauth: shared secret list entry %d is empty (stray or trailing comma?) — an empty accepted secret would authenticate any caller", i+1)
		}
		if _, dup := seen[secret]; dup {
			return nil, fmt.Errorf("internalauth: shared secret list entry %d is a duplicate", i+1)
		}
		seen[secret] = struct{}{}
		out = append(out, secret)
	}
	return out, nil
}

// authorized reports whether the call presented any accepted secret.
//
// Every candidate is compared, and the comparison is constant-time and NOT
// short-circuited: the loop deliberately does not `return` on the first
// match, so the work done is a function of how many secrets are configured
// and never of which one matched or how far through the list it was. A
// plain `for ... { if match { return true } }` would leak the position of
// the matching secret through timing — a small leak, but this is the file
// where that discipline is the whole point.
func authorized(ctx context.Context, expected [][]byte) bool {
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

	presented := []byte(values[0])
	match := 0
	for _, candidate := range expected {
		match |= subtle.ConstantTimeCompare(presented, candidate)
	}
	return match == 1
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
