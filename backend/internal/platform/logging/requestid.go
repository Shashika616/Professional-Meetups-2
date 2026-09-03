package logging

import (
	"context"

	"github.com/google/uuid"
)

type contextKey int

const requestIDKey contextKey = iota

// WithRequestID returns a context carrying id as the request/correlation ID
// for this request, retrievable via RequestIDFromContext.
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey, id)
}

// RequestIDFromContext returns the request ID stored in ctx, or "" if none
// is present.
func RequestIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey).(string)
	return id
}

// NewRequestID generates a new random request/correlation ID.
func NewRequestID() string {
	return uuid.NewString()
}
