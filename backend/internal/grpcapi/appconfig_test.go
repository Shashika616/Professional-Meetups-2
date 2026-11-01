package grpcapi

import (
	"context"
	"encoding/json"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/flags"
	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
)

type recordingFlags struct{ got flags.Subject }

func (r *recordingFlags) EvaluateAll(_ context.Context, s flags.Subject) (map[string]flags.Evaluated, error) {
	r.got = s
	return map[string]flags.Evaluated{
		flags.BillingPlansVisible: {Enabled: false},
		flags.AnalyticsSampleRate: {Enabled: true, Value: json.RawMessage(`100`)},
	}, nil
}

func TestGetAppConfig(t *testing.T) {
	src := &recordingFlags{}
	srv := NewOpsServer(nil).WithAppConfig(AppConfig{Flags: src, MinSupportedAppVersion: "1.0.0", BillingCatalogVersion: 7})
	ctx := clientinfo.With(context.Background(), clientinfo.Info{AppVersion: "1.2.0"})

	resp, err := srv.GetAppConfig(ctx, &opsv1.GetAppConfigRequest{UserId: "alice"})
	if err != nil {
		t.Fatal(err)
	}
	if src.got.UserID != "alice" || src.got.AppVersion != "1.2.0" {
		t.Fatalf("evaluated for %+v; want the request's user and the call's app version", src.got)
	}
	if resp.GetMinSupportedAppVersion() != "1.0.0" || resp.GetBillingCatalogVersion() != 7 {
		t.Fatalf("response = %+v", resp)
	}
	if f := resp.GetFlags()[flags.AnalyticsSampleRate]; !f.GetEnabled() || f.GetValueJson() != "100" {
		t.Fatalf("sample rate = %+v", f)
	}
	if f, ok := resp.GetFlags()[flags.BillingPlansVisible]; !ok || f.GetEnabled() {
		t.Fatalf("billing.plans.visible = %+v, %v", f, ok)
	}
}

func TestGetAppConfigUnconfiguredIsUnimplemented(t *testing.T) {
	_, err := NewOpsServer(nil).GetAppConfig(context.Background(), &opsv1.GetAppConfigRequest{})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("err = %v, want Unimplemented", err)
	}
}
