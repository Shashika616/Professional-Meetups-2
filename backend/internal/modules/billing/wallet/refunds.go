package wallet

import (
	"fmt"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Refund returns percent of a captured hold to the lots it came from, and
// returns how many credits went back. Credits returned to a lot that has
// since expired, or that decay has capped below them, are removed again at
// once by the same rules that apply to everything else in that lot: a
// refund restores the original credits, original expiry included.
//
// A plan-quota hold refunds its quota unit on a full refund and nothing on
// a partial one (half a meetup is not a unit).
func (t *Tx) Refund(holdID uuid.UUID, percent int, refType, refID string) (int64, error) {
	if percent <= 0 {
		return 0, nil
	}
	h, err := t.lockHold(holdID)
	if err != nil {
		return 0, err
	}
	if h.State != StateCaptured {
		return 0, fmt.Errorf("wallet: refund of a hold in state %q: %w", h.State, apperror.ErrConflict)
	}
	if h.Kind == HoldPlanQuota {
		if percent < 100 {
			return 0, nil
		}
		if err := t.adjustQuota(h.PeriodStart.Time, func(used, held int32) (int32, int32, error) {
			return used - 1, held, nil
		}); err != nil {
			return 0, err
		}
		return 0, t.write(entry{reason: "refund", holdID: h.ID, refType: refType, refID: refID,
			key: "refund:" + h.ID.String()})
	}

	// A full refund also undoes the debt this hold's own capture recorded
	// (a capture that arrived after its hold lapsed). Without this the
	// refunded credits would go straight to paying that debt, and the host
	// would end up charged for a meetup they were fully refunded for.
	if percent == 100 {
		owed, err := t.q.LedgerDebtForKey(t.ctx, sqlcgen.LedgerDebtForKeyParams{
			UserID: t.userID, IdempotencyKey: "capture:" + h.ID.String() + ":debt",
		})
		if err != nil {
			return 0, fmt.Errorf("wallet: read capture debt: %w", err)
		}
		if writeOff := min(owed, t.debt); writeOff > 0 {
			if err := t.write(entry{debtDelta: -writeOff, reason: "refund", holdID: h.ID,
				refType: refType, refID: refID, key: "refund:" + h.ID.String() + ":debt",
				note: "debt from this hold's capture written off by a full refund"}); err != nil {
				return 0, err
			}
		}
	}

	allocs, err := t.q.LockAllocations(t.ctx, h.ID)
	if err != nil {
		return 0, fmt.Errorf("wallet: lock allocations: %w", err)
	}
	var spent int64
	for _, a := range allocs {
		spent += a.Amount - a.Refunded
	}
	left := spent * int64(percent) / 100
	total := left
	ids := make([]uuid.UUID, 0, len(allocs))
	for _, a := range allocs {
		ids = append(ids, a.LotID)
	}
	lots, err := t.q.LockLotsByID(t.ctx, sqlcgen.LockLotsByIDParams{Ids: ids, UserID: t.userID})
	if err != nil {
		return 0, fmt.Errorf("wallet: lock refund lots: %w", err)
	}
	remaining := make(map[uuid.UUID]int64, len(lots))
	for _, l := range lots {
		remaining[l.ID] = l.Remaining
	}
	for _, a := range allocs {
		if left == 0 {
			break
		}
		give := min(a.Amount-a.Refunded, left)
		if give <= 0 {
			continue
		}
		if err := t.q.SetLotRemaining(t.ctx, sqlcgen.SetLotRemainingParams{ID: a.LotID, Remaining: remaining[a.LotID] + give}); err != nil {
			return 0, fmt.Errorf("wallet: return to lot: %w", err)
		}
		remaining[a.LotID] += give
		if err := t.q.AddAllocationRefund(t.ctx, sqlcgen.AddAllocationRefundParams{HoldID: h.ID, LotID: a.LotID, Amount: give}); err != nil {
			return 0, fmt.Errorf("wallet: record refund: %w", err)
		}
		if err := t.write(entry{delta: give, reason: "refund", lotID: a.LotID, holdID: h.ID,
			refType: refType, refID: refID, key: "refund:" + h.ID.String() + ":" + a.LotID.String()}); err != nil {
			return 0, err
		}
		left -= give
	}
	// Re-apply the lots' own rules: a lot that expired while the credits
	// were spent takes them with it now.
	if err := t.reapplyLots(ids); err != nil {
		return 0, err
	}
	return total, t.settleDebt()
}

// reapplyLots trims lots back to what their expiry and decay allow, for
// credits just returned to them.
func (t *Tx) reapplyLots(ids []uuid.UUID) error {
	lots, err := t.q.LockLotsByID(t.ctx, sqlcgen.LockLotsByIDParams{Ids: ids, UserID: t.userID})
	if err != nil {
		return fmt.Errorf("wallet: relock lots: %w", err)
	}
	for _, lot := range lots {
		allowed := lot.Remaining
		if lot.DecayPercent.Valid {
			allowed = min(allowed, AllowedAfter(lot.Initial, int(lot.DecayPercent.Int32), int(lot.DecayPeriodsApplied)))
		}
		if lot.ExpiresAt.Valid && !lot.ExpiresAt.Time.After(t.now) {
			allowed = 0
		}
		cut := lot.Remaining - allowed
		if cut <= 0 {
			continue
		}
		reason := "decay"
		if allowed == 0 && lot.ExpiresAt.Valid && !lot.ExpiresAt.Time.After(t.now) {
			reason = "expire"
		}
		if err := t.q.SetLotRemaining(t.ctx, sqlcgen.SetLotRemainingParams{ID: lot.ID, Remaining: allowed}); err != nil {
			return fmt.Errorf("wallet: trim lot: %w", err)
		}
		if err := t.write(entry{delta: -cut, reason: reason, lotID: lot.ID, refType: "refund_trim",
			key: reason + ":refund:" + uuid.NewString()}); err != nil {
			return err
		}
	}
	return nil
}

// RevokeLot takes back a purchase the store refunded or charged back (plan
// 3.6): what is left in the lot is removed, and what was already spent
// becomes debt, which the next grants pay off first and which blocks
// creation until they do. The lot is expired as well, so credits that a
// meetup refund later returns to it do not revive the refunded purchase.
//
// key makes it idempotent; a replay is ErrAlreadyApplied.
func (t *Tx) RevokeLot(lotID uuid.UUID, key, refType, refID string) (removed, debt int64, err error) {
	lot, err := t.q.GetLot(t.ctx, lotID)
	if err != nil {
		return 0, 0, fmt.Errorf("wallet: lock lot to revoke: %w", err)
	}
	if lot.UserID != t.userID {
		return 0, 0, fmt.Errorf("wallet: lot %s is not this wallet's: %w", lotID, apperror.ErrInternal)
	}
	removed, debt = lot.Remaining, lot.Initial-lot.Remaining
	if removed > 0 {
		if err := t.q.SetLotRemaining(t.ctx, sqlcgen.SetLotRemainingParams{ID: lotID, Remaining: 0}); err != nil {
			return 0, 0, fmt.Errorf("wallet: empty revoked lot: %w", err)
		}
		if err := t.write(entry{delta: -removed, reason: "reversal", lotID: lotID,
			refType: refType, refID: refID, key: key + ":remaining"}); err != nil {
			return 0, 0, err
		}
	}
	if debt > 0 {
		if err := t.write(entry{debtDelta: debt, reason: "reversal", lotID: lotID,
			refType: refType, refID: refID, key: key + ":debt"}); err != nil {
			return 0, 0, err
		}
	}
	if err := t.q.ExpireLotNow(t.ctx, sqlcgen.ExpireLotNowParams{ID: lotID, Now: ts(t.now)}); err != nil {
		return 0, 0, fmt.Errorf("wallet: expire revoked lot: %w", err)
	}
	return removed, debt, nil
}
