package handlers

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// ScheduledWorkRunner is the narrow slice of the monolith client this
// handler needs. An interface so a test can drive the success, partial
// failure and unreachable cases without a real gRPC server.
type ScheduledWorkRunner interface {
	RunScheduledWork(ctx context.Context) (monolithclient.ScheduledWorkReport, error)
}

// tickTimeout bounds one whole tick. The monolith already bounds each sweep
// at 30s; this is the outer limit for the eleven of them together, and it
// sits under Cloud Scheduler's 180s attempt deadline so the scheduler sees
// our 500 rather than its own timeout — the difference between a log line
// that names the sweep that hung and one that says nothing.
const tickTimeout = 150 * time.Second

// cronSecretHeader carries the shared secret. A header rather than a query
// parameter on purpose: query strings are logged in full by Cloud Run's
// request log and by anything in front of it, and a secret in a URL ends up
// in places nobody meant to put it.
const cronSecretHeader = "X-Cron-Secret" // #nosec G101 -- the header's name; the secret comes from CRON_SHARED_SECRET

// RegisterCron mounts POST /internal/cron/tick (§10 of the runbook).
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

	mux.HandleFunc("POST /internal/cron/tick", func(w http.ResponseWriter, r *http.Request) {
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

		ctx, cancel := context.WithTimeout(r.Context(), tickTimeout)
		defer cancel()

		started := time.Now()
		report, err := runner.RunScheduledWork(ctx)
		if err != nil {
			logger.Error("cron tick: could not run", "error", err)
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
				"failed", report.Failed, "duration", time.Since(started))
		} else {
			logger.Info("cron tick: done",
				"sweeps", len(report.Results), "duration", time.Since(started))
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(report)
	})

	return true
}
