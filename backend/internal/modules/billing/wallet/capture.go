package wallet

import (
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
)

// CaptureResult says what a capture did.
type CaptureResult struct {
	AlreadyCaptured bool
	// Spent came out of lots; Debt is what they could not cover, which
	// only happens when the hold had already lapsed or decay ate into it.
	Spent, Debt int64
}

// Capture turns a hold into a spend, drawing on lots expiring first and
// recording which lots it used. Capturing twice is a no-op.
//
// A hold that has already been released (by its TTL, or by a failed
// create racing a successful retry) is captured anyway: the meetup exists
// and must be paid for. It spends whatever is available and records the
// rest as debt (plan 3.2), which blocks creation until it is paid.
func (t *Tx) Capture(holdID uuid.UUID, meetupID string) (CaptureResult, error) {
	h, err := t.lockHold(holdID)
	if err != nil {
		return CaptureResult{}, err
	}
	if h.State == StateCaptured {
		return CaptureResult{AlreadyCaptured: true}, nil
	}
	if h.State == StateReleased && h.ReleaseReason.String == ReleaseSettled {
		return CaptureResult{AlreadyCaptured: true}, nil
	}
	meetup := pgtype.UUID{}
	if id, err := uuid.Parse(meetupID); err == nil {
		meetup = pgtype.UUID{Bytes: id, Valid: true}
	}
	wasHeld := h.State == StateHeld
	res := CaptureResult{}

	switch h.Kind {
	case HoldPlanQuota:
		if err := t.adjustQuota(h.PeriodStart.Time, func(used, held int32) (int32, int32, error) {
			if wasHeld {
				held--
			}
			return used + 1, held, nil
		}); err != nil {
			return res, err
		}
		if err := t.write(entry{reason: "capture", holdID: h.ID, refType: "meetup", refID: meetupID,
			key: "capture:" + h.ID.String()}); err != nil {
			return res, err
		}
	case HoldCredits:
		if wasHeld {
			if err := t.write(entry{heldDelta: -h.Amount, reason: "capture", holdID: h.ID,
				refType: "meetup", refID: meetupID, key: "capture:" + h.ID.String() + ":hold"}); err != nil {
				return res, err
			}
		}
		uncovered, err := t.spendFrom(h.Amount, func(lotID uuid.UUID, n int64) error {
			if err := t.q.InsertAllocation(t.ctx, sqlcgen.InsertAllocationParams{HoldID: h.ID, LotID: lotID, Amount: n}); err != nil {
				return fmt.Errorf("wallet: record allocation: %w", err)
			}
			return t.write(entry{delta: -n, reason: "capture", lotID: lotID, holdID: h.ID,
				refType: "meetup", refID: meetupID,
				key: "capture:" + h.ID.String() + ":" + lotID.String()})
		})
		if err != nil {
			return res, err
		}
		res.Spent = h.Amount - uncovered
		if uncovered > 0 {
			res.Debt = uncovered
			if err := t.write(entry{debtDelta: uncovered, reason: "capture", holdID: h.ID,
				refType: "meetup", refID: meetupID, key: "capture:" + h.ID.String() + ":debt",
				note: "capture after the hold lapsed; balance did not cover it"}); err != nil {
				return res, err
			}
			t.logger.Error("billing: capture recorded debt", "user_id", t.userID, "hold_id", h.ID,
				"meetup_id", meetupID, "debt", uncovered, "was_held", wasHeld)
		}
	}
	if err := t.q.MarkHoldCaptured(t.ctx, sqlcgen.MarkHoldCapturedParams{ID: h.ID, At: ts(t.now), MeetupID: meetup}); err != nil {
		return res, fmt.Errorf("wallet: mark captured: %w", err)
	}
	return res, nil
}
