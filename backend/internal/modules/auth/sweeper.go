package auth

import (
	"context"
	"log/slog"
	"time"
)

// Retention/sweep parameters for auth.refresh_tokens (§B3).
//
// The problem: every login and every refresh INSERTs a row, and until now
// nothing ever deleted one. auth.verification_codes is safe by design (a
// unique-per-purpose upsert plus delete-on-consume, so it is self-limiting),
// but refresh tokens accumulated forever — the table only ever grew, and its
// growth rate is proportional to active usage. Trimming continuously from
// day one is nearly free; backfill-deleting millions of rows from a live
// production table later is a maintenance window.
const (
	// RefreshTokenRetention is how long a row survives past the point where
	// it can no longer authenticate anything. Revoked rows are eligible
	// immediately (they are already dead); expired rows get this grace
	// window so a recent expiry is still inspectable while someone is
	// debugging a "why was I signed out" report.
	RefreshTokenRetention = 7 * 24 * time.Hour

	// refreshTokenSweepInterval is deliberately coarse. Nothing depends on a
	// dead row disappearing promptly — this is disk hygiene, not
	// correctness — and an hourly sweep keeps the table trimmed while adding
	// no meaningful load.
	refreshTokenSweepInterval = time.Hour

	// refreshTokenSweepBatchSize bounds one DELETE. The sweep loops until a
	// batch comes back short, so the total deleted per tick is unbounded
	// while any single statement (and therefore any single lock) stays
	// small. This matters most on the very first run after this ships, when
	// the eligible backlog is every dead row ever created.
	refreshTokenSweepBatchSize = 1000

	// refreshTokenSweepMaxBatches caps one tick's work so a huge backlog is
	// drained over several ticks rather than in one long-running pass that
	// competes with live traffic. Anything left is picked up an hour later.
	refreshTokenSweepMaxBatches = 50
)

// RefreshTokenSweeper deletes refresh-token rows that can never authenticate
// anything again, and then the guest accounts those rows were the last way
// into (plan 14 Part B).
//
// Two jobs in one sweeper rather than two sweepers: they run on the same
// schedule, share a retention window, and the second is only correct AFTER
// the first has run (an account is eligible once it has no token rows at
// all). Separate tickers could drift apart and make that ordering
// accidental.
//
// Same shape as the meetup module's lifecycle Poller and the notification
// outbox's retention job — started with `go sweeper.Run(ctx)` from
// cmd/monolith and stopping cleanly when that context is cancelled — so
// there is one recognisable pattern for "periodic background work in this
// process" rather than three different ones.
type RefreshTokenSweeper struct {
	svc    refreshTokenSweeperService
	logger *slog.Logger
}

// refreshTokenSweeperService is the narrow slice of Service the sweeper
// needs, so a test can drive it without constructing the whole module.
type refreshTokenSweeperService interface {
	SweepExpiredRefreshTokens(ctx context.Context) (int, error)
	SweepAbandonedGuests(ctx context.Context) (int, error)
}

// NewRefreshTokenSweeper constructs a sweeper over svc.
func NewRefreshTokenSweeper(svc refreshTokenSweeperService, logger *slog.Logger) *RefreshTokenSweeper {
	if logger == nil {
		logger = slog.Default()
	}
	return &RefreshTokenSweeper{svc: svc, logger: logger}
}

// Run sweeps on a fixed interval until ctx is cancelled.
//
// The first sweep waits for the first tick rather than running immediately
// at startup: a process restarting repeatedly (a crash loop, a rolling
// deploy) should not run a delete-heavy pass on every start, and an hour's
// delay costs nothing for work this insensitive to latency.
func (s *RefreshTokenSweeper) Run(ctx context.Context) {
	ticker := time.NewTicker(refreshTokenSweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.Tick(ctx)
		}
	}
}

// Tick runs one sweep. Exported so a test can drive a single iteration
// deterministically instead of waiting on the ticker.
func (s *RefreshTokenSweeper) Tick(ctx context.Context) {
	deleted, err := s.svc.SweepExpiredRefreshTokens(ctx)
	if err != nil {
		s.logger.Error("refresh token sweep", "error", err)
		// Deliberately not a return: guest cleanup does not depend on the
		// token sweep succeeding. It only becomes less effective this tick,
		// since an account is eligible only once its last token row is
		// gone — a failed sweep defers work, it does not corrupt anything.
	} else if deleted > 0 {
		s.logger.Info("refresh token sweep", "deleted", deleted)
	}

	// Second, and in this order on purpose: the sweep above is what removes
	// the last dead refresh-token row, and DeleteAbandonedGuests requires
	// NO row at all. Running guest cleanup first would just miss every
	// account whose final token died this tick.
	guests, err := s.svc.SweepAbandonedGuests(ctx)
	if err != nil {
		s.logger.Error("guest account cleanup", "error", err)
		return
	}
	if guests > 0 {
		s.logger.Info("guest account cleanup", "deleted", guests)
	}
}

// SweepAbandonedGuests deletes every eligible abandoned guest account,
// batched, and reports the total removed.
//
// Same loop, ceiling and cancellation behaviour as
// SweepExpiredRefreshTokens — see that method for the reasoning; the two
// share their retention window and batch parameters deliberately, so there
// is one set of numbers to reason about rather than two that can drift.
func (s *service) SweepAbandonedGuests(ctx context.Context) (int, error) {
	total := 0
	for batch := 0; batch < refreshTokenSweepMaxBatches; batch++ {
		if err := ctx.Err(); err != nil {
			return total, nil
		}

		deleted, err := s.users.DeleteAbandonedGuests(ctx, RefreshTokenRetention, refreshTokenSweepBatchSize)
		if err != nil {
			return total, err
		}
		total += deleted

		if deleted < refreshTokenSweepBatchSize {
			return total, nil
		}
	}
	return total, nil
}

// SweepExpiredRefreshTokens deletes every eligible refresh-token row,
// batched, and reports the total removed.
//
// Loops until a batch comes back short of the batch size (the table is
// trimmed) or the per-tick batch ceiling is hit (a backlog, continued next
// tick). Returns early on a cancelled context so shutdown isn't held up by
// a sweep mid-backlog.
func (s *service) SweepExpiredRefreshTokens(ctx context.Context) (int, error) {
	total := 0
	for batch := 0; batch < refreshTokenSweepMaxBatches; batch++ {
		if err := ctx.Err(); err != nil {
			return total, nil
		}

		deleted, err := s.refreshTokens.DeleteExpired(ctx, RefreshTokenRetention, refreshTokenSweepBatchSize)
		if err != nil {
			return total, err
		}
		total += deleted

		if deleted < refreshTokenSweepBatchSize {
			return total, nil
		}
	}
	return total, nil
}
