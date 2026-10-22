package main

import (
	"context"

	"professional-meetups-monolith/backend/internal/grpcapi"
	"professional-meetups-monolith/backend/internal/modules/notification"
)

// The adapters that turn this binary's periodic workers into grpcapi.Sweep
// functions.
//
// They live here rather than in grpcapi so that package keeps no import on
// the meetup, auth or notification modules, and so each worker keeps the
// signature that suits it instead of being bent into a shared interface.

// countedInt adapts the common shape — `func(ctx) (int, error)` — to the
// int64 a Sweep reports. Every lifecycle and auth sweep already has it, and
// outbox.Poller.Drain does too.
func countedInt(f func(context.Context) (int, error)) func(context.Context) (int64, error) {
	return func(ctx context.Context) (int64, error) {
		n, err := f(ctx)
		return int64(n), err
	}
}

// retentionSweep adapts notification.Retention, whose Sweep reports two
// counts. They are summed rather than reported separately: the two halves
// delete from the same table for the same reason (keeping it bounded), and
// splitting them would mean two Sweep entries whose names differ only by a
// word. The per-half counts are still in the Retention logs.
func retentionSweep(r *notification.Retention) func(context.Context) (int64, error) {
	return func(ctx context.Context) (int64, error) {
		processed, deadLettered, err := r.Sweep(ctx)
		return int64(processed + deadLettered), err
	}
}

// Compile-time check that the adapters produce what Sweep wants.
var _ = grpcapi.Sweep{Run: countedInt(nil)}
