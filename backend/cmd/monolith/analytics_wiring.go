package main

import (
	"context"
	"encoding/json"
	"time"

	"professional-meetups-monolith/backend/internal/modules/analytics"
	"professional-meetups-monolith/backend/internal/modules/analytics/report"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/billing"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// --- analytics (plan 29D): server domain events from the outboxes ---
//
// Every adapter here reads an outbox row another module already writes in
// the same transaction as the fact it records, so nothing is lost the way a
// bus event can be. None of them can fail or slow the delivery it sits on:
// analytics.Record has no error to return and only queues, and a row these
// adapters cannot read is skipped. Billing correctness never depends on
// analytics (plan 29 §1).
//
// The event id is derived from the outbox row (analytics.EventIDFor), so a
// redelivered row is stored once.

// analyticsRecorder is the slice of the analytics module these adapters use.
type analyticsRecorder interface {
	Record(ctx context.Context, e analytics.ServerEvent)
}

// creditsChanged is the credits.changed payload (billing/wallet).
type creditsChanged struct {
	UserID     string           `json:"user_id"`
	Changes    map[string]int64 `json:"changes"`
	OccurredAt time.Time        `json:"occurred_at"`
}

// creditEventFor maps one ledger reason and its balance change to an
// analytics event name, or "" for a change analytics does not report (a
// hold or a release moves held credits, not the balance).
func creditEventFor(reason string, delta int64) string {
	switch {
	case delta == 0:
		return ""
	case reason == "capture" && delta < 0:
		return "credits_spent"
	case reason == "refund" && delta > 0:
		return "credits_refunded"
	case (reason == "decay" || reason == "expire") && delta < 0:
		return "credits_expired"
	case (reason == "reversal" || reason == "admin_adjust") && delta < 0:
		return "credits_revoked"
	case (reason == "grant" || reason == "admin_adjust") && delta > 0:
		return "credits_granted"
	}
	return ""
}

// analyticsBillingConsumer records credits, purchase and subscription
// events from billing's outbox. It always returns nil.
func analyticsBillingConsumer(a analyticsRecorder) billing.OutboxConsumer {
	return func(ctx context.Context, e billing.OutboxEvent) error {
		switch e.Topic {
		case "credits.changed":
			var p creditsChanged
			if json.Unmarshal(e.Payload, &p) != nil {
				return nil
			}
			for reason, delta := range p.Changes {
				name := creditEventFor(reason, delta)
				if name == "" {
					continue
				}
				credits := delta
				if credits < 0 {
					credits = -credits
				}
				a.Record(ctx, analytics.ServerEvent{
					Source: "billing_outbox:" + e.ID + ":" + reason, Name: name, UserID: p.UserID,
					OccurredAt: p.OccurredAt, Attributes: map[string]any{"reason": reason, "credits": credits},
				})
			}
		case billing.TopicPurchaseVerified:
			var p struct {
				UserID    string `json:"user_id"`
				Platform  string `json:"platform"`
				Kind      string `json:"kind"`
				ProductID string `json:"product_id"`
			}
			if json.Unmarshal(e.Payload, &p) != nil {
				return nil
			}
			a.Record(ctx, analytics.ServerEvent{
				Source: "billing_outbox:" + e.ID, Name: "purchase_verified", UserID: p.UserID,
				Attributes: map[string]any{"platform": p.Platform, "kind": p.Kind, "product_id": p.ProductID},
			})
		case billing.TopicSubscriptionActivated, billing.TopicSubscriptionDeactivated:
			var p billing.SubscriptionEvent
			if json.Unmarshal(e.Payload, &p) != nil {
				return nil
			}
			a.Record(ctx, analytics.ServerEvent{
				Source: "billing_outbox:" + e.ID, Name: "subscription_changed", UserID: p.UserID, OccurredAt: p.OccurredAt,
				Attributes: map[string]any{"status": p.Status, "plan_code": p.PlanCode},
			})
		}
		return nil
	}
}

// withAnalytics runs tap on each row before the delivery itself, so the
// fact is recorded whether or not the delivery succeeds this time (a
// failing push does not mean the join request did not happen). tap cannot
// fail; the delivery's own error is returned unchanged.
func withAnalytics(process func(context.Context, outbox.Row) error, tap func(context.Context, outbox.Row)) func(context.Context, outbox.Row) error {
	return func(ctx context.Context, row outbox.Row) error {
		tap(ctx, row)
		return process(ctx, row)
	}
}

// meetupBillingAnalytics records meetup_created from the meetup billing
// outbox (a charged meetup's creation; the host is the user).
func meetupBillingAnalytics(a analyticsRecorder) func(context.Context, outbox.Row) {
	return func(ctx context.Context, row outbox.Row) {
		var e meetuprepo.BillingEvent
		if json.Unmarshal(row.Payload, &e) != nil || e.Topic != meetuprepo.BillingTopicCreated {
			return
		}
		a.Record(ctx, analytics.ServerEvent{Source: "meetup_billing_outbox:" + row.ID, Name: "meetup_created", UserID: e.HostUserID})
	}
}

// meetupsCompletedAnalytics records one meetup_completed per meetup in a
// meetups-completed row. The row names meetups, not people, so these are
// counted, not attributed.
func meetupsCompletedAnalytics(a analyticsRecorder) func(context.Context, outbox.Row) {
	return func(ctx context.Context, row outbox.Row) {
		var p meetuprepo.MeetupsCompletedPayload
		if json.Unmarshal(row.Payload, &p) != nil {
			return
		}
		for _, id := range p.MeetupIDs {
			a.Record(ctx, analytics.ServerEvent{Source: "meetups_completed:" + id, Name: "meetup_completed"})
		}
	}
}

// meetupActivityProcess is the meetup activity outbox's delivery step:
// join_requested and request_accepted, written by the meetup module in the
// same transaction as the request or the accept (migration 0031). The
// requester is the user for both: it is their join funnel. It always
// returns nil.
func meetupActivityProcess(a analyticsRecorder) func(context.Context, outbox.Row) error {
	return func(ctx context.Context, row outbox.Row) error {
		var e meetuprepo.ActivityEvent
		if json.Unmarshal(row.Payload, &e) != nil {
			return nil
		}
		var name string
		switch e.Topic {
		case meetuprepo.ActivityTopicRequestCreated:
			name = "join_requested"
		case meetuprepo.ActivityTopicRequestAccepted:
			name = "request_accepted"
		default:
			return nil
		}
		a.Record(ctx, analytics.ServerEvent{
			Source: "meetup_activity_outbox:" + row.ID, Name: name, UserID: e.RequesterID, OccurredAt: e.OccurredAt,
		})
		return nil
	}
}

// --- the daily report (plan 29F) ---

// reportMailer adapts the email sender to the analytics module's mailer
// port. Every configured sender (logging, Gmail, Resend) can attach.
type reportMailer struct{ sender email.AttachmentSender }

func (m reportMailer) SendReport(ctx context.Context, r analytics.ReportMail) error {
	return m.sender.SendWithAttachment(ctx, r.To, r.Subject, r.Body, email.Attachment{
		Filename: r.Filename, ContentType: r.ContentType, Data: r.Data,
	})
}

// newReportMailer is nil when the sender cannot attach (none today).
func newReportMailer(sender email.EmailSender) analytics.ReportMailer {
	if a, ok := sender.(email.AttachmentSender); ok {
		return reportMailer{sender: a}
	}
	return nil
}

// reconciliationSource gives the report billing's daily check, as counts.
type reconciliationSource struct{ billing *billing.Service }

func (r reconciliationSource) Reconciliation(ctx context.Context, day time.Time) (report.Reconciliation, bool, error) {
	checked, mismatches, found, err := r.billing.ReconciliationRun(ctx, day)
	return report.Reconciliation{Checked: checked, Mismatches: mismatches}, found, err
}
