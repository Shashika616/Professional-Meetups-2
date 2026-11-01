package grpcapi

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/clientinfo"
	"professional-meetups-monolith/backend/internal/platform/flags"
	"professional-meetups-monolith/backend/internal/platform/metrics"
	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
)

// sweepTimeout bounds ONE sweep, not the whole tick. The sweeps run in
// sequence, so without a per-sweep bound a single wedged query would eat the
// caller's deadline and every sweep after it would be skipped — including
// the account-deletion purge, which has a legal deadline. Thirty seconds is
// far longer than any of these batched, indexed claims needs and still
// leaves room for the rest of the list inside Cloud Scheduler's 180s
// attempt deadline.
const sweepTimeout = 30 * time.Second

// Sweep is one unit of periodic work: a name for the logs and a function
// that does the work once and reports how many rows it touched.
//
// The adapters live in cmd/monolith, where the concrete workers are already
// constructed, rather than here. That keeps this package free of imports on
// the meetup, auth and notification modules, and it means each worker keeps
// the signature that suits it (Poller.DrainOnce, Retention.Sweep,
// RefreshTokenSweeper.Tick) instead of being bent into a shared interface.
type Sweep struct {
	Name string
	Run  func(context.Context) (int64, error)
}

// OpsServer implements OpsService over a fixed list of sweeps.
type OpsServer struct {
	opsv1.UnimplementedOpsServiceServer

	sweeps []Sweep
	logger *slog.Logger

	appConfig AppConfig
}

// FlagSource evaluates every flag for one caller (internal/platform/flags).
type FlagSource interface {
	EvaluateAll(ctx context.Context, subject flags.Subject) (map[string]flags.Evaluated, error)
}

// AppConfig is what GET /v1/app-config serves besides the flags.
type AppConfig struct {
	Flags                  FlagSource
	MinSupportedAppVersion string
	BillingCatalogVersion  int32
}

// WithAppConfig enables GetAppConfig. Without it the RPC is unimplemented.
func (s *OpsServer) WithAppConfig(c AppConfig) *OpsServer {
	s.appConfig = c
	return s
}

// GetAppConfig evaluates every flag for the caller (plan 29 §2). A caller
// with no user id is evaluated anonymously: allowlists do not match, and
// flags fall back to their defaults.
func (s *OpsServer) GetAppConfig(ctx context.Context, req *opsv1.GetAppConfigRequest) (*opsv1.GetAppConfigResponse, error) {
	if s.appConfig.Flags == nil {
		return s.UnimplementedOpsServiceServer.GetAppConfig(ctx, req)
	}
	evaluated, err := s.appConfig.Flags.EvaluateAll(ctx, flags.Subject{
		UserID:     req.GetUserId(),
		AppVersion: clientinfo.From(ctx).AppVersion,
	})
	if err != nil {
		return nil, apperror.ToGRPCStatus(err)
	}
	resp := &opsv1.GetAppConfigResponse{
		Flags:                  make(map[string]*opsv1.FlagValue, len(evaluated)),
		MinSupportedAppVersion: s.appConfig.MinSupportedAppVersion,
		BillingCatalogVersion:  s.appConfig.BillingCatalogVersion,
	}
	for key, e := range evaluated {
		resp.Flags[key] = &opsv1.FlagValue{Enabled: e.Enabled, ValueJson: string(e.Value)}
	}
	return resp, nil
}

// NewOpsServer constructs an OpsServer over sweeps, run in the order given.
func NewOpsServer(logger *slog.Logger, sweeps ...Sweep) *OpsServer {
	if logger == nil {
		logger = slog.Default()
	}
	return &OpsServer{sweeps: sweeps, logger: logger}
}

// RunScheduledWork runs every sweep once.
//
// It returns nil error even when sweeps fail, and reports the failures in
// the response instead. The distinction is deliberate: a gRPC error means
// "this request could not be served", and the gateway turns that into a 500
// that tells Cloud Scheduler to retry the WHOLE tick. A single failing sweep
// does not warrant re-running the others — the next tick picks it up, and
// every sweep is a claim, so nothing is lost by waiting one interval.
//
// One sweep's failure never stops the next. That is the whole reason this
// loop does not return early: the sweeps are unrelated to each other, and an
// outbox that cannot reach FCM must not hold up the retention passes.
func (s *OpsServer) RunScheduledWork(
	ctx context.Context,
	_ *opsv1.RunScheduledWorkRequest,
) (*opsv1.RunScheduledWorkResponse, error) {
	resp := &opsv1.RunScheduledWorkResponse{
		Results: make([]*opsv1.SweepResult, 0, len(s.sweeps)),
	}

	for _, sweep := range s.sweeps {
		// Stop if the caller has gone away. Carrying on would do work whose
		// result nobody will read, while holding database connections that
		// the next tick needs.
		if ctx.Err() != nil {
			s.logger.Warn("scheduled work: caller went away, stopping",
				"after", sweep.Name, "error", ctx.Err())
			break
		}

		sweepCtx, cancel := context.WithTimeout(ctx, sweepTimeout)
		affected, err := sweep.Run(sweepCtx)
		cancel()

		result := &opsv1.SweepResult{Name: sweep.Name, Affected: affected}
		if err != nil {
			result.Error = err.Error()
			resp.Failed++
			s.logger.Error("scheduled work: sweep failed",
				"sweep", sweep.Name, "error", err)
		} else if affected > 0 {
			s.logger.Info("scheduled work: sweep done",
				"sweep", sweep.Name, "affected", affected)
		}
		resp.Results = append(resp.Results, result)
	}

	return resp, nil
}

// ScrapeMetrics hands the gateway this process's Prometheus registry
// (plan 29D). Only the gateway can call it: the internal shared secret
// guards every RPC on this port.
func (s *OpsServer) ScrapeMetrics(context.Context, *opsv1.ScrapeMetricsRequest) (*opsv1.ScrapeMetricsResponse, error) {
	text, err := metrics.Text()
	if err != nil {
		return nil, apperror.ToGRPCStatus(fmt.Errorf("ops: gather metrics: %w: %w", apperror.ErrInternal, err))
	}
	return &opsv1.ScrapeMetricsResponse{Text: text}, nil
}
