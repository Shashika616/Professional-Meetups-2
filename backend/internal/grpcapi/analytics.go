package grpcapi

import (
	"context"

	"professional-meetups-monolith/backend/internal/modules/analytics"
	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	analyticsv1 "professional-meetups-monolith/backend/internal/proto/analytics/v1"
)

// AnalyticsServer adapts the analytics module to analytics.v1 (plan 29D).
type AnalyticsServer struct {
	analyticsv1.UnimplementedAnalyticsServiceServer
	svc *analytics.Service
}

// NewAnalyticsServer constructs an AnalyticsServer over svc.
func NewAnalyticsServer(svc *analytics.Service) *AnalyticsServer {
	return &AnalyticsServer{svc: svc}
}

func (s *AnalyticsServer) Ingest(ctx context.Context, req *analyticsv1.IngestRequest) (*analyticsv1.IngestResponse, error) {
	events := make([]registry.Input, 0, len(req.GetEvents()))
	for _, e := range req.GetEvents() {
		events = append(events, registry.Input{
			EventID: e.GetEventId(), Name: e.GetEventName(), SchemaVersion: int(e.GetSchemaVersion()),
			OccurredAt: e.GetOccurredAt(), SessionID: e.GetSessionId(), Screen: e.GetScreen(),
			FlowID: e.GetFlowId(), FlowStep: e.GetFlowStep(), Attributes: e.GetAttributesJson(),
		})
	}
	res, err := s.svc.Ingest(ctx, analytics.Batch{
		UserID: req.GetUserId(),
		Context: analytics.Context{
			InstallID: req.GetInstallId(), AppVersion: req.GetAppVersion(), OSName: req.GetOsName(),
			OSVersion: req.GetOsVersion(), DeviceClass: req.GetDeviceClass(), Locale: req.GetLocale(),
		},
		Events: events,
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &analyticsv1.IngestResponse{Accepted: int32(res.Accepted), Dropped: int32(res.Dropped)}, nil
}

func (s *AnalyticsServer) SetConsent(ctx context.Context, req *analyticsv1.SetConsentRequest) (*analyticsv1.SetConsentResponse, error) {
	if err := s.svc.SetConsent(ctx, req.GetUserId(), req.GetOptedOut()); err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	return &analyticsv1.SetConsentResponse{}, nil
}
