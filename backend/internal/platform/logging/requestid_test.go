package logging

import (
	"context"
	"testing"
)

func TestRequestIDContextRoundTrip(t *testing.T) {
	ctx := WithRequestID(context.Background(), "req-123")
	if got := RequestIDFromContext(ctx); got != "req-123" {
		t.Errorf("RequestIDFromContext = %q, want %q", got, "req-123")
	}
}

func TestRequestIDFromContextEmpty(t *testing.T) {
	if got := RequestIDFromContext(context.Background()); got != "" {
		t.Errorf("RequestIDFromContext(background) = %q, want empty", got)
	}
}

func TestNewRequestIDUnique(t *testing.T) {
	a := NewRequestID()
	b := NewRequestID()
	if a == "" || b == "" {
		t.Fatal("NewRequestID returned an empty string")
	}
	if a == b {
		t.Errorf("NewRequestID produced the same ID twice: %q", a)
	}
}
