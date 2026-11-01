package store

import (
	"context"
	"errors"
	"time"

	"professional-meetups-monolith/backend/internal/platform/breaker"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// The bounded retry and breaker around every store call, ported from the
// source's verifyWithResilience (ADR-031 §2 step 3): two attempts with a
// short fixed delay so the whole call fits inside the app's purchase wait,
// and a breaker per platform so an outage costs one fast failure rather than
// every caller's full timeout.
//
// One change from the source: only ErrUnavailable is retried. A rejected
// purchase is rejected again, so retrying it only delays the answer.
const (
	maxAttempts      = 2
	retryDelay       = 500 * time.Millisecond
	breakerThreshold = 5
	breakerReset     = 30 * time.Second
	// callTimeout bounds one whole verification, both attempts included.
	callTimeout = 15 * time.Second
)

// Resilient wraps v and f with a breaker, retry and timeout. A nil f is
// left nil.
type Resilient struct {
	v Verifier
	f Finisher
	b *breaker.Breaker
}

// NewResilient constructs the wrapper with its own breaker.
func NewResilient(v Verifier, f Finisher) *Resilient {
	return &Resilient{v: v, f: f, b: breaker.New(breakerThreshold, breakerReset)}
}

func (r *Resilient) Verify(ctx context.Context, req Request) (Transaction, error) {
	ctx, span := otel.Tracer("store").Start(ctx, "store verify", trace.WithAttributes(
		attribute.String("store.platform", string(req.Platform)),
		attribute.String("store.kind", string(req.Kind)),
	))
	defer span.End()
	var tx Transaction
	err := r.run(ctx, func(ctx context.Context) error {
		var err error
		tx, err = r.v.Verify(ctx, req)
		return err
	})
	return tx, err
}

func (r *Resilient) Finish(ctx context.Context, platform Platform, kind Kind, productID, token string) error {
	if r.f == nil {
		return ErrNotConfigured
	}
	ctx, span := otel.Tracer("store").Start(ctx, "store finish", trace.WithAttributes(
		attribute.String("store.platform", string(platform)),
		attribute.String("store.kind", string(kind)),
	))
	defer span.End()
	return r.run(ctx, func(ctx context.Context) error {
		return r.f.Finish(ctx, platform, kind, productID, token)
	})
}

func (r *Resilient) run(ctx context.Context, call func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	var last error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		var answer error
		err := r.b.Execute(func() error {
			answer = call(ctx)
			// Only a transient failure counts against the breaker: a store
			// that answers "rejected" is a healthy store, and a run of
			// fraudulent tokens must not open it for everyone else.
			if errors.Is(answer, ErrUnavailable) {
				return answer
			}
			return nil
		})
		if errors.Is(err, breaker.ErrOpen) {
			return ErrUnavailable
		}
		if !errors.Is(answer, ErrUnavailable) {
			return answer
		}
		last = answer
		if attempt < maxAttempts {
			select {
			case <-ctx.Done():
				return ErrUnavailable
			case <-time.After(retryDelay):
			}
		}
	}
	return last
}
