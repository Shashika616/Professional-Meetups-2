package middleware

import (
	"log/slog"
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/platform/logging"
)

// RequestLogging logs each request's method, path, status, and duration.
// Must run after logging.HTTPMiddleware in the chain so a request ID is
// already in the context to attach to the log line.
func RequestLogging(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

			next.ServeHTTP(rec, r)

			logging.FromContext(r.Context(), logger).Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", time.Since(start).Milliseconds(),
			)
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}
