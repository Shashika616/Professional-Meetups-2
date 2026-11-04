package handlers

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// ScheduledWorkRunner is the narrow slice of the monolith client this
// handler needs. An interface so a test can drive the success, partial
// failure and unreachable cases without a real gRPC server.
type ScheduledWorkRunner interface {
	RunScheduledWork(ctx context.Context, group string) (monolithclient.ScheduledWorkReport, error)
}

// Each tick's total (tracker #102). The monolith bounds each sweep by its
// own budget and stops starting sweeps when the total runs out, answering
// with a report that names what was skipped. Each total sits under its
// Cloud Scheduler job's attempt deadline (runbook §10: 300s core, 540s
// analytics), so the scheduler sees our status rather than its own
// timeout, and under Cloud Run's 600s request timeout (service.yaml). Vars
// so a test can shrink them.
var (
	coreTickTimeout      = 240 * time.Second
	analyticsTickTimeout = 480 * time.Second
)

// writeGrace is how long after the tick's total the response may still be
// written. The server's WriteTimeout (30s, cmd/gateway) is for ordinary
// requests and would cut a tick's reply off long before it is ready.
const writeGrace = 15 * time.Second

// cronSecretHeader carries the shared secret. A header rather than a query
// parameter on purpose: query strings are logged in full by Cloud Run's
// request log and by anything in front of it, and a secret in a URL ends up
// in places nobody meant to put it.
const cronSecretHeader = "X-Cron-Secret" // #nosec G101 -- the header's name; the secret comes from CRON_SHARED_SECRET

// RegisterCron mounts POST /internal/cron/tick (the core sweeps) and
// POST /internal/cron/tick/analytics (the heavy analytics sweeps), one
// Cloud Scheduler job each (§10 of the runbook).
//
// # WHY THIS ROUTE EXISTS
//
// The monolith's periodic work — the lifecycle sweeps, the outbox pollers,
// the retention passes, the auth sweeps — used to run on in-process tickers,
// which need an instance that is alive and has CPU. On Cloud Run that means
// a reserved, continuously billed instance (minScale "1" with cpu-throttling
// "false", roughly US$120-130/mo for this container pair). This project
// stays inside the free tier, so the service scales to zero and Cloud
// Scheduler calls this route instead. The tickers remain as a safety net for
// whenever an instance happens to be alive.
//
// # WHY IT HAS ITS OWN SECRET
//
// Everything else under /internal is unreachable from outside the container
// pair. This route is NOT: Cloud Scheduler reaches it over the public URL,
// so it is as exposed as /v1 is. It cannot use the normal bearer-token
// middleware, because the caller is a scheduler, not a user with a session.
//
// A shared secret in a header, compared in constant time, is the same shape
// as the gateway-to-monolith check (internal/platform/internalauth) and is
// proportionate to what the route does: it starts work that is idempotent,
// claim-based, and returns no user data. The worst an attacker with the
// secret achieves is making sweeps run more often than scheduled, which is
// what the sweeps are built to tolerate.
//
// If secret is empty the route is NOT MOUNTED. An unauthenticated endpoint
// that runs database writes is worse than no endpoint, and failing closed at
// startup makes a missing configuration obvious the first time the scheduler
// gets a 404 — rather than silently serving to anyone who finds the path.
func RegisterCron(mux *http.ServeMux, runner ScheduledWorkRunner, secret string, logger *slog.Logger) bool {
	if secret == "" {
		return false
	}
	if logger == nil {
		logger = slog.Default()
	}

	mux.HandleFunc("POST /internal/cron/tick", cronTick(runner, secret, "", coreTickTimeout, logger))
	mux.HandleFunc("POST /internal/cron/tick/analytics", cronTick(runner, secret, "analytics", analyticsTickTimeout, logger))

	return true
}

// cronTick serves one tick route: the secret check, then the group's sweeps
// within total.
func cronTick(runner ScheduledWorkRunner, secret, group string, total time.Duration, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		presented := r.Header.Get(cronSecretHeader)
		// ConstantTimeCompare returns 0 for unequal lengths without looking
		// at the contents, so check the length separately to keep the
		// comparison itself constant-time over equal-length inputs.
		if len(presented) != len(secret) ||
			subtle.ConstantTimeCompare([]byte(presented), []byte(secret)) != 1 {
			// 404, not 401: this route's existence is not something an
			// unauthenticated caller needs confirmed.
			http.NotFound(w, r)
			return
		}

		// This route's own write deadline, past the server's WriteTimeout.
		// A writer that cannot take one (only test recorders) is fine: it
		// has no deadline to outlive.
		if err := http.NewResponseController(w).SetWriteDeadline(time.Now().Add(total + writeGrace)); err != nil &&
			!errors.Is(err, http.ErrNotSupported) {
			logger.Warn("cron tick: could not extend the write deadline", "error", err)
		}

		ctx, cancel := context.WithTimeout(r.Context(), total)
		defer cancel()

		started := time.Now()
		report, err := runner.RunScheduledWork(ctx, group)
		if err != nil {
			logger.Error("cron tick: could not run", "group", group, "error", err)
			// 503 so Cloud Scheduler retries: the tick did not happen at
			// all, which is different from a tick where one sweep failed.
			writeStatusJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "unavailable",
				"reason": "monolith is not reachable",
			})
			return
		}

		status := http.StatusOK
		if report.Failed > 0 {
			// Non-2xx so the scheduler records the failure and retries. The
			// retry is cheap and correct: every sweep is a claim, so the
			// ones that succeeded this time find nothing to do next time.
			status = http.StatusInternalServerError
			logger.Error("cron tick: sweeps failed",
				"group", group, "failed", report.Failed, "duration", time.Since(started))
		} else {
			logger.Info("cron tick: done",
				"group", group, "sweeps", len(report.Results), "duration", time.Since(started))
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(report)
	}
}
