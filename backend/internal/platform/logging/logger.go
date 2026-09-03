// Package logging is a thin wrapper around log/slog: JSON output matching
// Cloud Logging's expected field names, plus HTTP middleware and a gRPC
// interceptor that generate or propagate a request/correlation ID and
// attach it to every log line for that request. Full observability design
// (tracing, metrics, sampling) is explicitly out of scope for this slice —
// this only seeds the hooks so request correlation isn't bolted on later.
package logging

import (
	"context"
	"log/slog"
	"os"
)

// New returns a slog.Logger that writes JSON lines using Cloud Logging's
// expected keys ("severity", "message") instead of slog's defaults
// ("level", "msg"), so Cloud Run/Cloud Logging parses severity correctly
// instead of treating every line as default severity.
func New() *slog.Logger {
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: replaceAttr,
	})
	return slog.New(handler)
}

func replaceAttr(_ []string, a slog.Attr) slog.Attr {
	switch a.Key {
	case slog.LevelKey:
		a.Key = "severity"
	case slog.MessageKey:
		a.Key = "message"
	}
	return a
}

// FromContext returns logger with the request ID from ctx (if any) attached
// as a "request_id" attribute, so every subsequent log call on the returned
// logger carries it automatically. Returns logger unchanged if ctx carries
// no request ID.
func FromContext(ctx context.Context, logger *slog.Logger) *slog.Logger {
	id := RequestIDFromContext(ctx)
	if id == "" {
		return logger
	}
	return logger.With("request_id", id)
}
