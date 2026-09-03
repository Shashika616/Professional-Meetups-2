package logging

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"testing"
)

func newTestLogger(buf *bytes.Buffer) *slog.Logger {
	handler := slog.NewJSONHandler(buf, &slog.HandlerOptions{ReplaceAttr: replaceAttr})
	return slog.New(handler)
}

func TestLoggerUsesCloudLoggingKeys(t *testing.T) {
	var buf bytes.Buffer
	logger := newTestLogger(&buf)

	logger.Info("hello", "foo", "bar")

	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("unmarshal log line: %v (raw: %s)", err, buf.String())
	}

	if _, ok := line["level"]; ok {
		t.Error("log line still has slog's default \"level\" key")
	}
	if _, ok := line["msg"]; ok {
		t.Error("log line still has slog's default \"msg\" key")
	}
	if line["severity"] != "INFO" {
		t.Errorf(`severity = %v, want "INFO"`, line["severity"])
	}
	if line["message"] != "hello" {
		t.Errorf(`message = %v, want "hello"`, line["message"])
	}
	if line["foo"] != "bar" {
		t.Errorf(`foo = %v, want "bar"`, line["foo"])
	}
}

func TestFromContextAttachesRequestID(t *testing.T) {
	var buf bytes.Buffer
	base := newTestLogger(&buf)

	ctx := WithRequestID(context.Background(), "req-abc")
	logger := FromContext(ctx, base)
	logger.Info("with id")

	var withID map[string]any
	if err := json.Unmarshal(buf.Bytes(), &withID); err != nil {
		t.Fatalf("unmarshal log line: %v", err)
	}
	if withID["request_id"] != "req-abc" {
		t.Errorf("request_id = %v, want %q", withID["request_id"], "req-abc")
	}

	buf.Reset()
	FromContext(context.Background(), base).Info("without id")

	var withoutID map[string]any
	if err := json.Unmarshal(buf.Bytes(), &withoutID); err != nil {
		t.Fatalf("unmarshal log line: %v", err)
	}
	if _, ok := withoutID["request_id"]; ok {
		t.Errorf("expected no request_id key, got %v", withoutID["request_id"])
	}
}
