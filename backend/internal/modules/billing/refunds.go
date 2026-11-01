package billing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/pricing"
	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// MeetupEnded is a charged meetup's cancellation or close, as the meetup
// module's outbox reports it. Billing decides what it means for money.
type MeetupEnded struct {
	HoldID        string
	MeetupID      string
	Event         string // "cancelled" or "closed"
	AcceptedCount int
	WindowStart   time.Time
	EndedAt       time.Time
}

// Event names, as carried on the meetup outbox.
const (
	EventCancelled = "cancelled"
	EventClosed    = "closed"
)

// refundPercent is the refund policy (plan 3.6, D7), from the rules document.
func refundPercent(p pricing.RefundPolicy, e MeetupEnded) int {
	switch e.Event {
	case EventCancelled:
		cutoff := e.WindowStart.Add(-time.Duration(p.FullIfCancelledHoursBefore) * time.Hour)
		if !e.EndedAt.After(cutoff) {
			return 100
		}
		return 0
	case EventClosed:
		if e.AcceptedCount == 0 {
			return p.NoParticipantsPercent
		}
	}
	return 0
}

// HandleMeetupEnded applies the refund policy to a charged meetup that was
// cancelled or closed. Idempotent: billing.refund_log is unique per hold, so
// a redelivered event changes nothing.
//
// The meetup's created event may not have been captured yet (outbox rows are
// retried independently). A hold still held is settled here: a full refund
// just releases it, anything else captures it first and then refunds the
// share the policy allows.
func (s *Service) HandleMeetupEnded(ctx context.Context, e MeetupEnded) error {
	if e.Event != EventCancelled && e.Event != EventClosed {
		return fmt.Errorf("billing: unknown meetup event %q: %w", e.Event, apperror.ErrInvalidInput)
	}
	holdID, owner, err := s.holdOwner(ctx, e.HoldID)
	if errors.Is(err, apperror.ErrNotFound) {
		// Nothing to settle. Returning an error would retry this row until
		// it dead-letters, for a hold that will never appear.
		s.logger.Error("billing: meetup ended for an unknown hold", "hold_id", e.HoldID, "meetup_id", e.MeetupID)
		return nil
	}
	if err != nil {
		return err
	}
	rules, err := s.Rules(ctx)
	if err != nil {
		return err
	}
	percent := refundPercent(rules.Doc.Refunds, e)
	meetupID := pgtype.UUID{}
	if id, err := uuid.Parse(e.MeetupID); err == nil {
		meetupID = pgtype.UUID{Bytes: id, Valid: true}
	}

	return s.ledger.Do(ctx, owner, func(t *wallet.Tx) error {
		q := t.Queries()
		done, err := q.RefundLogExists(ctx, holdID)
		if err != nil {
			return fmt.Errorf("billing: read refund log: %w", err)
		}
		if done {
			return nil
		}
		logRefund := func(outcome string, pct int, amount int64) error {
			_, err := q.InsertRefundLog(ctx, sqlcgen.InsertRefundLogParams{
				UserID: t.UserID(), HoldID: holdID, MeetupID: meetupID, Event: e.Event,
				Outcome: outcome, Percent: int32(pct), Amount: amount,
			})
			return err
		}

		// The cap applies to every refund, including a cancellation that
		// lands before its capture and would otherwise just release.
		capped := false
		if percent > 0 {
			recent, err := q.CountRefundsSince(ctx, sqlcgen.CountRefundsSinceParams{
				UserID: t.UserID(), Since: ts(t.Now().Add(-30 * 24 * time.Hour)),
			})
			if err != nil {
				return fmt.Errorf("billing: count recent refunds: %w", err)
			}
			if int(recent) >= rules.Doc.Refunds.MaxPer30Days {
				capped = true
				s.logger.Info("billing: refund skipped, 30-day cap reached",
					"user_id", t.UserID(), "hold_id", holdID, "refunds_in_window", recent)
			}
		}

		h, err := t.HoldState(holdID)
		if err != nil {
			return err
		}
		if h.State != wallet.StateCaptured {
			if percent == 100 && !capped {
				// Never charged, and nothing would be kept: release and done.
				if _, err := t.Release(holdID, wallet.ReleaseSettled); err != nil {
					return err
				}
				return logRefund("released", 100, 0)
			}
			if _, err := t.Capture(holdID, e.MeetupID); err != nil {
				return err
			}
		}

		switch {
		case percent == 0:
			return logRefund("no_refund", 0, 0)
		case capped:
			return logRefund("skipped_cap", percent, 0)
		}
		amount, err := t.Refund(holdID, percent, "meetup_"+e.Event, e.MeetupID)
		if err != nil {
			return err
		}
		return logRefund("refunded", percent, amount)
	})
}
