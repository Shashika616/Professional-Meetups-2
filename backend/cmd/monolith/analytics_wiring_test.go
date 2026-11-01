package main

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/analytics"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/billing"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

type recorded struct{ events []analytics.ServerEvent }

func (r *recorded) Record(_ context.Context, e analytics.ServerEvent) { r.events = append(r.events, e) }

func (r *recorded) names() []string {
	var out []string
	for _, e := range r.events {
		out = append(out, e.Name)
	}
	sort.Strings(out)
	return out
}

func TestCreditsChangedBecomesOneEventPerReason(t *testing.T) {
	r := &recorded{}
	consume := analyticsBillingConsumer(r)
	payload, _ := json.Marshal(map[string]any{
		"user_id": "u1",
		"changes": map[string]int64{"capture": -14, "hold": 0, "grant": 60, "expire": -6, "reversal": -50, "refund": 7},
	})
	if err := consume(context.Background(), billing.OutboxEvent{ID: "row-1", Topic: "credits.changed", Payload: payload}); err != nil {
		t.Fatal(err)
	}
	want := []string{"credits_expired", "credits_granted", "credits_refunded", "credits_revoked", "credits_spent"}
	if got := r.names(); len(got) != len(want) {
		t.Fatalf("events %v, want %v", got, want)
	} else {
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("events %v, want %v", got, want)
			}
		}
	}
	for _, e := range r.events {
		if e.UserID != "u1" || e.Attributes["credits"].(int64) <= 0 {
			t.Errorf("event %+v", e)
		}
		if e.Name == "credits_spent" && (e.Attributes["credits"] != int64(14) || e.Source != "billing_outbox:row-1:capture") {
			t.Errorf("spend %+v", e)
		}
	}
}

func TestTheAnalyticsConsumerNeverFailsABillingRow(t *testing.T) {
	consume := analyticsBillingConsumer(&recorded{})
	for _, e := range []billing.OutboxEvent{
		{Topic: "credits.changed", Payload: json.RawMessage(`not json`)},
		{Topic: billing.TopicPurchaseVerified, Payload: json.RawMessage(`[]`)},
		{Topic: billing.TopicSubscriptionActivated, Payload: json.RawMessage(`{"user_id": 5}`)},
		{Topic: "store.finish", Payload: json.RawMessage(`{}`)},
		{Topic: "something.new"},
	} {
		if err := consume(context.Background(), e); err != nil {
			t.Errorf("%s: %v", e.Topic, err)
		}
	}
}

func TestPurchaseAndSubscriptionEvents(t *testing.T) {
	r := &recorded{}
	consume := analyticsBillingConsumer(r)
	_ = consume(context.Background(), billing.OutboxEvent{ID: "p", Topic: billing.TopicPurchaseVerified,
		Payload: json.RawMessage(`{"user_id":"u","platform":"ios","kind":"consumable","product_id":"credits_50"}`)})
	_ = consume(context.Background(), billing.OutboxEvent{ID: "s", Topic: billing.TopicSubscriptionDeactivated,
		Payload: json.RawMessage(`{"user_id":"u","plan_code":"plus","status":"expired"}`)})
	if got := r.names(); len(got) != 2 || got[0] != "purchase_verified" || got[1] != "subscription_changed" {
		t.Fatalf("events %v", got)
	}
	if r.events[0].Attributes["product_id"] != "credits_50" || r.events[1].Attributes["status"] != "expired" {
		t.Errorf("attributes %+v", r.events)
	}
}

func TestWithAnalyticsTapsFirstAndKeepsTheDeliveryError(t *testing.T) {
	var order []string
	boom := errors.New("fcm down")
	process := withAnalytics(
		func(context.Context, outbox.Row) error { order = append(order, "deliver"); return boom },
		func(context.Context, outbox.Row) { order = append(order, "tap") },
	)
	if err := process(context.Background(), outbox.Row{ID: "r"}); !errors.Is(err, boom) {
		t.Errorf("err = %v, want the delivery's", err)
	}
	if len(order) != 2 || order[0] != "tap" {
		t.Errorf("order %v", order)
	}
}

func TestMeetupOutboxTaps(t *testing.T) {
	r := &recorded{}
	created, _ := json.Marshal(meetuprepo.BillingEvent{Topic: meetuprepo.BillingTopicCreated, HostUserID: "host"})
	closed, _ := json.Marshal(meetuprepo.BillingEvent{Topic: meetuprepo.BillingTopicClosed, HostUserID: "host"})
	meetupBillingAnalytics(r)(context.Background(), outbox.Row{ID: "m1", Payload: created})
	meetupBillingAnalytics(r)(context.Background(), outbox.Row{ID: "m2", Payload: closed})
	completed, _ := json.Marshal(meetuprepo.MeetupsCompletedPayload{MeetupIDs: []string{"a", "b"}})
	meetupsCompletedAnalytics(r)(context.Background(), outbox.Row{ID: "c", Payload: completed})
	for _, topic := range []string{meetuprepo.ActivityTopicRequestCreated, meetuprepo.ActivityTopicRequestAccepted, "request.withdrawn"} {
		p, _ := json.Marshal(meetuprepo.ActivityEvent{Topic: topic, RequestID: "q", MeetupID: "m", RequesterID: "requester", HostUserID: "host"})
		if err := meetupActivityProcess(r)(context.Background(), outbox.Row{ID: "a-" + topic, Payload: p}); err != nil {
			t.Errorf("%s: %v", topic, err)
		}
	}
	if err := meetupActivityProcess(r)(context.Background(), outbox.Row{ID: "bad", Payload: []byte("not json")}); err != nil {
		t.Errorf("an unreadable row failed the delivery: %v", err)
	}
	want := []string{"join_requested", "meetup_completed", "meetup_completed", "meetup_created", "request_accepted"}
	got := r.names()
	if len(got) != len(want) {
		t.Fatalf("events %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("events %v, want %v", got, want)
		}
	}
	for _, e := range r.events {
		if e.Name == "meetup_created" && e.UserID != "host" {
			t.Errorf("meetup_created not attributed to the host: %+v", e)
		}
		if (e.Name == "join_requested" || e.Name == "request_accepted") && (e.UserID != "requester" || e.Attributes != nil) {
			t.Errorf("join events must be the requester's, with no attributes: %+v", e)
		}
	}
}

// Plan 29F: the report goes out through whatever sender is configured; in
// tests (and locally) that is the logging sender, which validates and logs
// instead of sending.
func TestTheReportMailsThroughTheLoggingSender(t *testing.T) {
	m := newReportMailer(email.NewLoggingEmailSender())
	if m == nil {
		t.Fatal("the logging sender cannot attach")
	}
	mail := analytics.ReportMail{
		To: []string{"ops@example.com"}, Subject: "TieHere daily report, Sat 31 Oct 2026", Body: "Attached.",
		Filename: "tiehere-report-2026-10-31.xlsx", ContentType: analytics.XLSXType, Data: []byte("PK\x03\x04 a workbook"),
	}
	if err := m.SendReport(context.Background(), mail); err != nil {
		t.Fatal(err)
	}
	mail.Subject = "x\r\nBcc: someone@example.com"
	if err := m.SendReport(context.Background(), mail); !errors.Is(err, email.ErrHeaderInjection) {
		t.Errorf("err = %v", err)
	}
	// Every configured sender can attach.
	for _, s := range []email.EmailSender{
		email.NewLoggingEmailSender(),
		email.NewGmailSMTPEmailSender("a@example.com", "p"),
		email.NewResendEmailSender("key", "a@example.com"),
	} {
		if newReportMailer(s) == nil {
			t.Errorf("%T cannot attach", s)
		}
	}
}
