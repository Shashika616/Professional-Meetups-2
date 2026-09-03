package logging

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHTTPMiddlewareGeneratesRequestID(t *testing.T) {
	var seenID string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenID = RequestIDFromContext(r.Context())
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	HTTPMiddleware(next).ServeHTTP(rec, req)

	if seenID == "" {
		t.Fatal("handler saw no request ID in context")
	}
	if got := rec.Header().Get(RequestIDHeader); got != seenID {
		t.Errorf("response %s = %q, want %q (context value)", RequestIDHeader, got, seenID)
	}
}

func TestHTTPMiddlewarePropagatesIncomingRequestID(t *testing.T) {
	var seenID string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenID = RequestIDFromContext(r.Context())
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set(RequestIDHeader, "client-supplied-id")
	rec := httptest.NewRecorder()

	HTTPMiddleware(next).ServeHTTP(rec, req)

	if seenID != "client-supplied-id" {
		t.Errorf("seenID = %q, want %q", seenID, "client-supplied-id")
	}
	if got := rec.Header().Get(RequestIDHeader); got != "client-supplied-id" {
		t.Errorf("response %s = %q, want %q", RequestIDHeader, got, "client-supplied-id")
	}
}
