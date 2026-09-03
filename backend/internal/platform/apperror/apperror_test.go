package apperror

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestToGRPCStatus(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want codes.Code
	}{
		{"not found", fmt.Errorf("user 123: %w", ErrNotFound), codes.NotFound},
		{"invalid input", fmt.Errorf("bad email: %w", ErrInvalidInput), codes.InvalidArgument},
		{"unauthorized", fmt.Errorf("bad token: %w", ErrUnauthorized), codes.Unauthenticated},
		{"forbidden", fmt.Errorf("trust level too low: %w", ErrForbidden), codes.PermissionDenied},
		{"conflict", fmt.Errorf("duplicate: %w", ErrConflict), codes.AlreadyExists},
		{"internal", fmt.Errorf("db down: %w", ErrInternal), codes.Internal},
		{"unrecognized error falls back to internal", errors.New("boom"), codes.Internal},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := status.Code(ToGRPCStatus(tt.err))
			if got != tt.want {
				t.Errorf("ToGRPCStatus(%v) code = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

func TestToGRPCStatusNil(t *testing.T) {
	if err := ToGRPCStatus(nil); err != nil {
		t.Errorf("ToGRPCStatus(nil) = %v, want nil", err)
	}
}

// TestToGRPCStatus_InternalErrorsAreRedacted guards against the
// information-disclosure finding from the security review: a codes.Internal
// mapping (the catch-all for raw repository/driver errors) must never hand
// its real error text to the caller, since that text routinely embeds
// implementation detail like SQL driver messages or connection strings.
func TestToGRPCStatus_InternalErrorsAreRedacted(t *testing.T) {
	sensitive := "pgx: dial tcp 10.20.30.40:5432: connection refused (user=app db=professional_connections)"
	raw := fmt.Errorf("repository: get user by id: %w", errors.New(sensitive))

	got := ToGRPCStatus(raw)

	if code := status.Code(got); code != codes.Internal {
		t.Fatalf("status code = %v, want %v", code, codes.Internal)
	}
	msg := status.Convert(got).Message()
	if msg != genericInternalMessage {
		t.Errorf("client-facing message = %q, want the fixed generic message %q", msg, genericInternalMessage)
	}
	if strings.Contains(msg, sensitive) || strings.Contains(msg, "10.20.30.40") {
		t.Errorf("client-facing message leaked internal detail: %q", msg)
	}
}

// TestToGRPCStatus_InternalErrorsAreLoggedServerSide asserts the real error
// still reaches the server-side logs with full detail — redaction must not
// mean the detail is lost entirely, just kept off the client-facing
// response.
func TestToGRPCStatus_InternalErrorsAreLoggedServerSide(t *testing.T) {
	sensitive := "pgx: dial tcp 10.20.30.40:5432: connection refused"
	raw := fmt.Errorf("repository: get user by id: %w", errors.New(sensitive))

	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	_ = ToGRPCStatus(raw) // only the logging side effect matters here

	if logged := buf.String(); !strings.Contains(logged, sensitive) {
		t.Errorf("server-side log = %q, want it to contain the real error detail %q", logged, sensitive)
	}
}

// TestToGRPCStatus_NonInternalErrorsKeepTheirMessage guards the other side
// of the fix: classified sentinel errors (NotFound, InvalidInput, ...) are
// intentionally client-facing and must not be swept into the same
// redaction as the Internal catch-all.
func TestToGRPCStatus_NonInternalErrorsKeepTheirMessage(t *testing.T) {
	raw := fmt.Errorf("user 123: %w", ErrNotFound)

	got := ToGRPCStatus(raw)

	if msg := status.Convert(got).Message(); msg != raw.Error() {
		t.Errorf("client-facing message = %q, want %q", msg, raw.Error())
	}
}

func TestHTTPStatusFromGRPC(t *testing.T) {
	tests := []struct {
		code codes.Code
		want int
	}{
		{codes.OK, http.StatusOK},
		{codes.NotFound, http.StatusNotFound},
		{codes.InvalidArgument, http.StatusBadRequest},
		{codes.Unauthenticated, http.StatusUnauthorized},
		{codes.PermissionDenied, http.StatusForbidden},
		{codes.AlreadyExists, http.StatusConflict},
		{codes.ResourceExhausted, http.StatusTooManyRequests},
		{codes.DeadlineExceeded, http.StatusGatewayTimeout},
		{codes.Unavailable, http.StatusServiceUnavailable},
		{codes.Internal, http.StatusInternalServerError},
		{codes.Unknown, http.StatusInternalServerError},
	}

	for _, tt := range tests {
		t.Run(tt.code.String(), func(t *testing.T) {
			if got := HTTPStatusFromGRPC(tt.code); got != tt.want {
				t.Errorf("HTTPStatusFromGRPC(%v) = %d, want %d", tt.code, got, tt.want)
			}
		})
	}
}
