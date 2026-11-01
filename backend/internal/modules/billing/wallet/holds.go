package wallet

import (
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Hold is a reservation as callers see it.
type Hold struct {
	ID       uuid.UUID
	UserID   uuid.UUID
	Kind     string
	Amount   int64
	State    string
	MeetupID string
}

func holdFromRow(h sqlcgen.BillingHold) Hold {
	out := Hold{ID: h.ID, UserID: h.UserID, Kind: h.Kind, Amount: h.Amount, State: h.State}
	if h.MeetupID.Valid {
		out.MeetupID = uuid.UUID(h.MeetupID.Bytes).String()
	}
	return out
}

// ReserveInput is one reservation.
type ReserveInput struct {
	Kind         string
	Amount       int64
	PriceVersion int
	TTL          time.Duration
	Key          string
	// Plan quota only.
	PeriodStart   time.Time
	QuotaIncluded int
}

// Reserve takes credits (or one unit of plan quota) out of availability
// without spending them. The same key returns the same hold: a retried
// request reserves once.
func (t *Tx) Reserve(in ReserveInput) (Hold, error) {
	existing, err := t.q.GetHoldByKey(t.ctx, sqlcgen.GetHoldByKeyParams{UserID: t.userID, IdempotencyKey: in.Key})
	switch {
	case err == nil:
		reused, err := t.reuseHold(existing, in)
		if err != nil || reused != nil {
			return derefHold(reused), err
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return Hold{}, fmt.Errorf("wallet: look up hold: %w", err)
	}
	if t.closed {
		return Hold{}, ErrWalletClosed
	}
	if t.debt > 0 {
		return Hold{}, &apperror.CodedError{
			Sentinel: apperror.ErrPaymentRequired, Code: apperror.CodeCreditsDebt,
			Message: "billing: an earlier charge is unpaid; add credits to host again",
			Fields:  map[string]int64{"debt": t.debt},
		}
	}

	params := sqlcgen.InsertHoldParams{
		UserID: t.userID, Kind: in.Kind, Amount: in.Amount, PriceVersion: int32(in.PriceVersion),
		ExpiresAt: ts(t.now.Add(in.TTL)), IdempotencyKey: in.Key,
	}
	switch in.Kind {
	case HoldCredits:
		if in.Amount <= 0 {
			return Hold{}, fmt.Errorf("wallet: reserve amount must be positive: %w", apperror.ErrInvalidInput)
		}
		if avail := t.Available(); avail < in.Amount {
			return Hold{}, &apperror.CodedError{
				Sentinel: apperror.ErrPaymentRequired, Code: apperror.CodeInsufficientCredits,
				Message: "billing: not enough credits to host this meetup",
				Fields:  map[string]int64{"cost": in.Amount, "available": avail, "shortfall": in.Amount - avail},
			}
		}
	case HoldPlanQuota:
		params.Amount = 1
		params.PeriodStart = ts(in.PeriodStart)
		if err := t.adjustQuota(in.PeriodStart, func(used, held int32) (int32, int32, error) {
			if int(used+held) >= in.QuotaIncluded {
				return 0, 0, ErrQuotaExhausted
			}
			return used, held + 1, nil
		}); err != nil {
			return Hold{}, err
		}
	default:
		return Hold{}, fmt.Errorf("wallet: unknown hold kind %q: %w", in.Kind, apperror.ErrInvalidInput)
	}

	row, err := t.q.InsertHold(t.ctx, params)
	if err != nil {
		return Hold{}, fmt.Errorf("wallet: insert hold: %w", err)
	}
	heldDelta := int64(0)
	if in.Kind == HoldCredits {
		heldDelta = in.Amount
	}
	if err := t.write(entry{
		heldDelta: heldDelta, reason: "hold", holdID: row.ID, refType: in.Kind,
		key: "hold:" + row.ID.String(),
	}); err != nil {
		return Hold{}, err
	}
	return holdFromRow(row), nil
}

// reuseHold decides what an existing hold under the same key means.
//
// A key is a promise that the request is the same one. So the hold is reused
// only when it is still held and was reserved for the same thing — same
// kind, same amount, same price version. A different request under a used
// key is refused (409 idempotency_key_reused) rather than served from the old
// hold: otherwise a key whose 10-credit create failed could carry a
// 48-credit meetup at the old price.
//
// The same request after its hold was released (the create failed) gets a
// fresh hold: the old one is moved aside and nil is returned so Reserve
// carries on. A captured hold for the same request is returned as is.
func (t *Tx) reuseHold(h sqlcgen.BillingHold, in ReserveInput) (*Hold, error) {
	wantAmount := in.Amount
	if in.Kind == HoldPlanQuota {
		wantAmount = 1
	}
	same := h.Kind == in.Kind && h.Amount == wantAmount && int(h.PriceVersion) == in.PriceVersion
	switch {
	case same && (h.State == StateHeld || h.State == StateCaptured):
		out := holdFromRow(h)
		return &out, nil
	case same && h.State == StateReleased && h.ReleaseReason.String != ReleaseSettled:
		if err := t.q.SupersedeHoldKey(t.ctx, h.ID); err != nil {
			return nil, fmt.Errorf("wallet: supersede released hold: %w", err)
		}
		return nil, nil
	default:
		return nil, &apperror.CodedError{
			Sentinel: apperror.ErrConflict, Code: apperror.CodeIdempotencyKeyReused,
			Message: "billing: this request was already made differently; start a new one",
		}
	}
}

func derefHold(h *Hold) Hold {
	if h == nil {
		return Hold{}
	}
	return *h
}

func (t *Tx) adjustQuota(periodStart time.Time, f func(used, held int32) (int32, int32, error)) error {
	if err := t.q.EnsurePlanUsage(t.ctx, sqlcgen.EnsurePlanUsageParams{UserID: t.userID, PeriodStart: ts(periodStart)}); err != nil {
		return fmt.Errorf("wallet: ensure plan usage: %w", err)
	}
	u, err := t.q.LockPlanUsage(t.ctx, sqlcgen.LockPlanUsageParams{UserID: t.userID, PeriodStart: ts(periodStart)})
	if err != nil {
		return fmt.Errorf("wallet: lock plan usage: %w", err)
	}
	used, held, err := f(u.Used, u.Held)
	if err != nil {
		return err
	}
	return t.q.SetPlanUsage(t.ctx, sqlcgen.SetPlanUsageParams{
		UserID: t.userID, PeriodStart: ts(periodStart), Used: max(used, 0), Held: max(held, 0),
	})
}

func (t *Tx) lockHold(holdID uuid.UUID) (sqlcgen.BillingHold, error) {
	h, err := t.q.LockHold(t.ctx, sqlcgen.LockHoldParams{ID: holdID, UserID: t.userID})
	if errors.Is(err, pgx.ErrNoRows) {
		return h, fmt.Errorf("wallet: hold %s: %w", holdID, apperror.ErrNotFound)
	}
	if err != nil {
		return h, fmt.Errorf("wallet: lock hold: %w", err)
	}
	return h, nil
}

// Release returns a hold's credits (or quota unit) to availability. A hold
// that is not held any more is left alone.
func (t *Tx) Release(holdID uuid.UUID, reason string) (released bool, err error) {
	h, err := t.lockHold(holdID)
	if err != nil {
		return false, err
	}
	if h.State != StateHeld {
		return false, nil
	}
	switch h.Kind {
	case HoldPlanQuota:
		if err := t.adjustQuota(h.PeriodStart.Time, func(used, held int32) (int32, int32, error) {
			return used, held - 1, nil
		}); err != nil {
			return false, err
		}
		err = t.write(entry{reason: "release", holdID: h.ID, refType: reason, key: "release:" + h.ID.String()})
	default:
		err = t.write(entry{heldDelta: -h.Amount, reason: "release", holdID: h.ID, refType: reason,
			key: "release:" + h.ID.String()})
	}
	if err != nil {
		return false, err
	}
	if err := t.q.MarkHoldReleased(t.ctx, sqlcgen.MarkHoldReleasedParams{ID: h.ID, At: ts(t.now), Reason: nullText(reason)}); err != nil {
		return false, fmt.Errorf("wallet: mark released: %w", err)
	}
	return true, nil
}

// HoldState reads a hold under the wallet lock.
func (t *Tx) HoldState(holdID uuid.UUID) (Hold, error) {
	h, err := t.lockHold(holdID)
	if err != nil {
		return Hold{}, err
	}
	return holdFromRow(h), nil
}
