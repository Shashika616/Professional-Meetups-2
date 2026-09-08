package middleware

import (
	"net/http"
	"time"

	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// Metrics records per-route request counts and latencies (§D3).
//
// # THE LABEL IS THE ROUTE PATTERN, NEVER THE RAW PATH
//
// This is the one thing that has to be right in a metrics middleware.
// Labelling by r.URL.Path would create a distinct time series per meetup id,
// per user id, per cursor — an unbounded label set fed directly by request
// traffic, which is both the standard way to melt a Prometheus server and,
// here, a way to publish object identifiers into a metrics store. Go 1.22+
// ServeMux exposes the matched PATTERN (e.g. "GET /v1/meetups/{id}"), which
// is a small fixed set decided at compile time — that is what gets recorded.
//
// A request that matches no route has no pattern; those are bucketed under a
// single "unmatched" label rather than being labelled with whatever path the
// caller invented, for exactly the same reason.
func Metrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &metricsRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(recorder, r)

		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		metrics.Default.ObserveHTTP(route, r.Method, recorder.status, time.Since(start))
	})
}

// metricsRecorder captures the response status for the metric.
//
// Its own type rather than reusing the logging middleware's statusRecorder:
// the two are wrapped at different points in the chain, and sharing one
// would make the order they run in load-bearing for both. It also has to
// treat an implicit 200 correctly, which the logging one does by
// initialising its field.
type metricsRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *metricsRecorder) WriteHeader(status int) {
	if !r.wroteHeader {
		r.status = status
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(status)
}

func (r *metricsRecorder) Write(b []byte) (int, error) {
	// A handler that writes a body without ever calling WriteHeader has
	// implicitly sent a 200, and that still has to be counted as one.
	r.wroteHeader = true
	return r.ResponseWriter.Write(b)
}
