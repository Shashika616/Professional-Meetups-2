package monolithclient

import (
	"context"
	"encoding/json"

	analyticsv1 "professional-meetups-monolith/backend/internal/proto/analytics/v1"
)

// AnalyticsBatch is one POST /v1/analytics/events body (docs/api/analytics.md).
// The gateway only checks its size and shape; the monolith validates every
// field against the event registry.
type AnalyticsBatch struct {
	InstallID   string           `json:"install_id"`
	AppVersion  string           `json:"app_version"`
	OSName      string           `json:"os_name"`
	OSVersion   string           `json:"os_version"`
	DeviceClass string           `json:"device_class"`
	Locale      string           `json:"locale"`
	Events      []AnalyticsEvent `json:"events"`
}

// AnalyticsEvent is one event in a batch.
type AnalyticsEvent struct {
	EventID       string          `json:"event_id"`
	EventName     string          `json:"event_name"`
	SchemaVersion int32           `json:"schema_version"`
	OccurredAt    string          `json:"occurred_at"`
	SessionID     string          `json:"session_id"`
	Screen        string          `json:"screen"`
	FlowID        string          `json:"flow_id"`
	FlowStep      string          `json:"flow_step"`
	Attributes    json.RawMessage `json:"attributes"`
}

// AnalyticsResult is how many events were queued and how many dropped.
type AnalyticsResult struct {
	Accepted int32 `json:"accepted"`
	Dropped  int32 `json:"dropped"`
}

func (c *grpcClient) IngestAnalytics(ctx context.Context, userID string, b AnalyticsBatch) (AnalyticsResult, error) {
	req := &analyticsv1.IngestRequest{
		UserId: userID, InstallId: b.InstallID, AppVersion: b.AppVersion, OsName: b.OSName,
		OsVersion: b.OSVersion, DeviceClass: b.DeviceClass, Locale: b.Locale,
	}
	for _, e := range b.Events {
		req.Events = append(req.Events, &analyticsv1.Event{
			EventId: e.EventID, EventName: e.EventName, SchemaVersion: e.SchemaVersion, OccurredAt: e.OccurredAt,
			SessionId: e.SessionID, Screen: e.Screen, FlowId: e.FlowID, FlowStep: e.FlowStep,
			AttributesJson: e.Attributes,
		})
	}
	resp, err := c.analytics.Ingest(ctx, req)
	if err != nil {
		return AnalyticsResult{}, err
	}
	return AnalyticsResult{Accepted: resp.GetAccepted(), Dropped: resp.GetDropped()}, nil
}

func (c *grpcClient) SetAnalyticsConsent(ctx context.Context, userID string, optedOut bool) error {
	_, err := c.analytics.SetConsent(ctx, &analyticsv1.SetConsentRequest{UserId: userID, OptedOut: optedOut})
	return err
}
