package middleware

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRequestLoggingRecordsStatusAndPath(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", nil)
	rec := httptest.NewRecorder()

	RequestLogging(logger)(handler).ServeHTTP(rec, req)

	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("unmarshal log line: %v (raw: %s)", err, buf.String())
	}
	if line["method"] != http.MethodPost {
		t.Errorf("method = %v, want %q", line["method"], http.MethodPost)
	}
	if line["path"] != "/v1/auth/refresh" {
		t.Errorf("path = %v, want %q", line["path"], "/v1/auth/refresh")
	}
	if line["status"] != float64(http.StatusCreated) {
		t.Errorf("status = %v, want %d", line["status"], http.StatusCreated)
	}
}

func TestRequestLoggingDefaultsStatusToOK(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil))

	// A handler that never calls WriteHeader explicitly still yields 200.
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	RequestLogging(logger)(handler).ServeHTTP(rec, req)

	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("unmarshal log line: %v", err)
	}
	if line["status"] != float64(http.StatusOK) {
		t.Errorf("status = %v, want %d", line["status"], http.StatusOK)
	}
}
