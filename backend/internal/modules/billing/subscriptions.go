package billing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
)

// Subscription statuses, as stored (0026).
const (
	statusActive      = "active"
	statusGracePeriod = "grace_period"
	statusPastDue     = "past_due"
	statusCanceled    = "canceled"
	statusExpired     = "expired"
	statusRevoked     = "revoked"
)

// SubscriptionView is GET /v1/billing/subscription.
type SubscriptionView struct {
	// Status is "none" without a subscription row.
	Status    string
	PlanCode  string
	Platform  string
	ProductID string
	PeriodEnd *time.Time
	AutoRenew bool
	// Entitled is whether the plan applies right now: the single answer to
	// "is this user on a plan", the same rule the entitlement checks use.
	Entitled bool
}

// Subscription is the caller's subscription, in whatever state.
func (s *Service) Subscription(ctx context.Context, caller Caller) (SubscriptionView, error) {
	uid, err := parseUser(caller.UserID)
	if err != nil {
		return SubscriptionView{}, err
	}
	row, err := s.q.GetSubscriptionView(ctx, uid)
	if errors.Is(err, pgx.ErrNoRows) {
		return SubscriptionView{Status: "none"}, nil
	}
	if err != nil {
		return SubscriptionView{}, fmt.Errorf("billing: read subscription: %w", err)
	}
	end := row.CurrentPeriodEnd.Time
	return SubscriptionView{
		Status: row.Status, PlanCode: row.PlanCode, Platform: row.Platform, ProductID: row.ProductID.String,
		PeriodEnd: &end, AutoRenew: row.AutoRenew,
		Entitled: entitledAt(row.Status, row.CurrentPeriodStart.Time, end, row.GracePeriodEnd, s.now()),
	}, nil
}

// entitledAt is GetActiveSubscription's rule in Go, for transitions.
func entitledAt(status string, start, end time.Time, grace pgtype.Timestamptz, now time.Time) bool {
	if start.After(now) {
		return false
	}
	switch status {
	case statusActive:
		return end.After(now)
	case statusGracePeriod:
		if grace.Valid && grace.Time.After(end) {
			end = grace.Time
		}
		return end.After(now)
	default:
		return false
	}
}

// subscriptionRow is a subscription's next state.
type subscriptionRow struct {
	PlanCode              string
	Status                string
	Platform              string
	OriginalTransactionID string
	ProductID             string
	PeriodStart           time.Time
	PeriodEnd             time.Time
	GracePeriodEnd        *time.Time
	AutoRenew             bool
}

func fromStored(r sqlcgen.BillingSubscription) subscriptionRow {
	out := subscriptionRow{
		PlanCode: r.PlanCode, Status: r.Status, Platform: r.Platform,
		OriginalTransactionID: r.OriginalTransactionID.String, ProductID: r.ProductID.String,
		PeriodStart: r.CurrentPeriodStart.Time, PeriodEnd: r.CurrentPeriodEnd.Time, AutoRenew: r.AutoRenew,
	}
	if r.GracePeriodEnd.Valid {
		g := r.GracePeriodEnd.Time
		out.GracePeriodEnd = &g
	}
	return out
}

func lockSubscription(ctx context.Context, q *sqlcgen.Queries, uid uuid.UUID) (sqlcgen.BillingSubscription, bool, error) {
	cur, err := q.LockSubscription(ctx, uid)
	if errors.Is(err, pgx.ErrNoRows) {
		return cur, false, nil
	}
	if err != nil {
		return cur, false, fmt.Errorf("billing: lock subscription: %w", err)
	}
	return cur, true, nil
}

// writeSubscription stores next and, when the user's entitlement changed,
// queues subscription.activated or subscription.deactivated in the same
// transaction (plan 3.7: through the outbox, not the lossy bus).
func (s *Service) writeSubscription(ctx context.Context, q *sqlcgen.Queries, uid uuid.UUID,
	cur sqlcgen.BillingSubscription, found bool, next subscriptionRow, now time.Time) error {
	if !next.PeriodEnd.After(next.PeriodStart) {
		next.PeriodStart = next.PeriodEnd.Add(-time.Second)
	}
	grace := pgtype.Timestamptz{}
	if next.GracePeriodEnd != nil {
		grace = ts(*next.GracePeriodEnd)
	}
	if err := q.UpsertStoreSubscription(ctx, sqlcgen.UpsertStoreSubscriptionParams{
		UserID: uid, PlanCode: next.PlanCode, Status: next.Status, Platform: next.Platform,
		OriginalTransactionID: nullText(next.OriginalTransactionID), ProductID: nullText(next.ProductID),
		PeriodStart: ts(next.PeriodStart), PeriodEnd: ts(next.PeriodEnd), GracePeriodEnd: grace, AutoRenew: next.AutoRenew,
	}); err != nil {
		return fmt.Errorf("billing: write subscription: %w", err)
	}
	was := found && entitledAt(cur.Status, cur.CurrentPeriodStart.Time, cur.CurrentPeriodEnd.Time, cur.GracePeriodEnd, now)
	is := entitledAt(next.Status, next.PeriodStart, next.PeriodEnd, grace, now)
	if was == is {
		return nil
	}
	topic := TopicSubscriptionActivated
	if !is {
		topic = TopicSubscriptionDeactivated
	}
	payload, err := json.Marshal(SubscriptionEvent{
		UserID: uid.String(), PlanCode: next.PlanCode, Status: next.Status, OccurredAt: now,
	})
	if err != nil {
		return err
	}
	if err := q.InsertBillingOutbox(ctx, sqlcgen.InsertBillingOutboxParams{Topic: topic, Payload: payload}); err != nil {
		return fmt.Errorf("billing: queue %s: %w", topic, err)
	}
	return nil
}

// SubscriptionEvent is the payload of subscription.activated and
// subscription.deactivated.
type SubscriptionEvent struct {
	UserID     string    `json:"user_id"`
	PlanCode   string    `json:"plan_code"`
	Status     string    `json:"status"`
	OccurredAt time.Time `json:"occurred_at"`
}
