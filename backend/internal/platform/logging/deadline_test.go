package logging

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc"
)

// TestDeadlineUnaryServerInterceptor_BoundsAnUnboundedCall is the §B2 proof:
// a handler that would otherwise run forever gets a deadline it can observe
// and abort on, rather than holding a pooled connection indefinitely.
func TestDeadlineUnaryServerInterceptor_BoundsAnUnboundedCall(t *testing.T) {
	interceptor := DeadlineUnaryServerInterceptor(50 * time.Millisecond)

	// A handler that respects its context but would never return on its own.
	handler := func(ctx context.Context, _ any) (any, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}

	start := time.Now()
	_, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{}, handler)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("an unbounded handler returned without error — no deadline was applied")
	}
	if !isDeadlineExceeded(err) {
		t.Errorf("error = %v, want context.DeadlineExceeded", err)
	}
	if elapsed > time.Second {
		t.Errorf("handler ran for %v, want it bounded to roughly the 50ms timeout", elapsed)
	}
}

// TestDeadlineUnaryServerInterceptor_HandlerSeesTheDeadline pins the shape
// the bound actually takes: the handler's own context carries it, which is
// what lets pgx cancel an in-flight query rather than merely abandoning the
// caller.
func TestDeadlineUnaryServerInterceptor_HandlerSeesTheDeadline(t *testing.T) {
	interceptor := DeadlineUnaryServerInterceptor(2 * time.Second)

	var seen bool
	var remaining time.Duration
	handler := func(ctx context.Context, _ any) (any, error) {
		deadline, ok := ctx.Deadline()
		seen = ok
		remaining = time.Until(deadline)
		return "ok", nil
	}

	if _, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{}, handler); err != nil {
		t.Fatalf("interceptor error: %v", err)
	}
	if !seen {
		t.Fatal("the handler's context carried no deadline")
	}
	if remaining <= 0 || remaining > 2*time.Second {
		t.Errorf("remaining deadline = %v, want (0, 2s]", remaining)
	}
}

// TestDeadlineUnaryServerInterceptor_KeepsAStricterCallerDeadline covers the
// half that makes this correct rather than merely present: a caller asking
// for LESS time must get less, not be silently extended to the server's
// limit.
func TestDeadlineUnaryServerInterceptor_KeepsAStricterCallerDeadline(t *testing.T) {
	interceptor := DeadlineUnaryServerInterceptor(10 * time.Second)

	callerCtx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()

	handler := func(ctx context.Context, _ any) (any, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}

	start := time.Now()
	if _, err := interceptor(callerCtx, nil, &grpc.UnaryServerInfo{}, handler); !isDeadlineExceeded(err) {
		t.Fatalf("error = %v, want context.DeadlineExceeded", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("the caller's stricter 40ms deadline was overridden by the server's 10s limit (ran %v)", elapsed)
	}
}

// TestDeadlineUnaryServerInterceptor_CapsAGenerousCallerDeadline is the
// other direction, and the one that makes this a server-side guarantee: a
// caller must not be able to opt out of the limit by asking for more.
func TestDeadlineUnaryServerInterceptor_CapsAGenerousCallerDeadline(t *testing.T) {
	interceptor := DeadlineUnaryServerInterceptor(50 * time.Millisecond)

	callerCtx, cancel := context.WithTimeout(context.Background(), time.Hour)
	defer cancel()

	handler := func(ctx context.Context, _ any) (any, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}

	start := time.Now()
	if _, err := interceptor(callerCtx, nil, &grpc.UnaryServerInfo{}, handler); !isDeadlineExceeded(err) {
		t.Fatalf("error = %v, want context.DeadlineExceeded", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("a caller asking for an hour was granted it (ran %v) — the server's limit must win", elapsed)
	}
}

func isDeadlineExceeded(err error) bool {
	return err == context.DeadlineExceeded
}
