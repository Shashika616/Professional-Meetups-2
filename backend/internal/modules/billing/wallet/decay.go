package wallet

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// AllowedAfter is how much of a decaying lot may remain after k periods:
// initial - floor(initial * percent * k / 100), never below zero.
//
// Cumulative rather than "take percent of what is left each time" so the
// rounding never drifts: period 3 of a 60-credit lot at 10% is 42 whatever
// happened at periods 1 and 2, and the lot reaches exactly 0 at period 10.
func AllowedAfter(initial int64, percent, k int) int64 {
	if k <= 0 {
		return initial
	}
	cut := initial * int64(percent) * int64(k) / 100
	if cut >= initial {
		return 0
	}
	return initial - cut
}

// MaxPeriods is the period at which a lot decaying percent per period is
// gone: ceil(100 / percent).
func MaxPeriods(percent int) int {
	return (100 + percent - 1) / percent
}

// applyDue materialises every decay period and expiry that has come due for
// this user. It runs at the start of every Do, so spends see the decayed
// balance between sweeps, and it is what the sweep calls too. Rerunning it
// changes nothing: each period is recorded on the lot and keyed in the
// ledger.
func (t *Tx) applyDue() error {
	lots, err := t.q.LockDueLots(t.ctx, sqlcgen.LockDueLotsParams{UserID: t.userID, Now: ts(t.now)})
	if err != nil {
		return fmt.Errorf("wallet: lock due lots: %w", err)
	}
	for _, lot := range lots {
		remaining := lot.Remaining
		if lot.DecayPercent.Valid && lot.NextDecayAt.Valid && !lot.NextDecayAt.Time.After(t.now) {
			every := intervalDuration(lot.DecayEvery)
			if every <= 0 {
				return fmt.Errorf("wallet: lot %s has no decay interval: %w", lot.ID, apperror.ErrInternal)
			}
			percent := int(lot.DecayPercent.Int32)
			maxP := MaxPeriods(percent)
			k := int(t.now.Sub(lot.GrantedAt.Time) / every)
			if k > maxP {
				k = maxP
			}
			for j := int(lot.DecayPeriodsApplied) + 1; j <= k; j++ {
				allowed := AllowedAfter(lot.Initial, percent, j)
				if remaining <= allowed {
					continue
				}
				cut := remaining - allowed
				if err := t.write(entry{
					delta: -cut, reason: "decay", lotID: lot.ID,
					key: fmt.Sprintf("decay:%s:%d", lot.ID, j),
				}); err != nil {
					return err
				}
				remaining = allowed
			}
			next := pgtype.Timestamptz{}
			if k < maxP {
				next = ts(lot.GrantedAt.Time.Add(time.Duration(k+1) * every))
			}
			if err := t.q.SetLotDecay(t.ctx, sqlcgen.SetLotDecayParams{
				ID: lot.ID, Remaining: remaining, DecayPeriodsApplied: int32(k), NextDecayAt: next,
			}); err != nil {
				return fmt.Errorf("wallet: record decay: %w", err)
			}
		}
		if lot.ExpiresAt.Valid && !lot.ExpiresAt.Time.After(t.now) && remaining > 0 {
			if err := t.write(entry{
				delta: -remaining, reason: "expire", lotID: lot.ID,
				key: "expire:" + lot.ID.String(),
			}); err != nil {
				return err
			}
			if err := t.q.SetLotRemaining(t.ctx, sqlcgen.SetLotRemainingParams{ID: lot.ID, Remaining: 0}); err != nil {
				return fmt.Errorf("wallet: record expiry: %w", err)
			}
		}
	}
	return nil
}

// ApplyDue materialises decay and expiry for one user, for the sweep. A
// wallet that a request holds right now is skipped: that request applies the
// same due decay itself, and the sweep comes back next tick.
func (l *Ledger) ApplyDue(ctx context.Context, userID uuid.UUID) error {
	return l.do(ctx, userID, true, nil)
}
