package middleware

import (
	"log/slog"
	"net/http"

	"professional-meetups-monolith/backend/internal/platform/logging"
)

// Recover converts a panic anywhere in the handler chain into a 500
// response instead of crashing the process (PLAN.md Step 7 self-review:
// "panics in request-handling paths become 500s via a recovery middleware,
// not crashes"). Should be the outermost middleware so it can catch panics
// from everything beneath it.
func Recover(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logging.FromContext(r.Context(), logger).Error("panic recovered", "panic", rec)
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = w.Write([]byte(`{"error":"internal server error"}`))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
