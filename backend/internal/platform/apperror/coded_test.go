package apperror

import (
	"errors"
	"fmt"
	"net/http"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// A coded error crosses gRPC with its reason and numbers intact, so the
// gateway can answer 402/409/426 with a body the app can act on (plan 29
// §3.5, §2).
func TestCodedErrorRoundTripsThroughGRPC(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		wantGRPC codes.Code
		wantHTTP int
		wantCode string
	}{
		{
			"insufficient credits is 402",
			&CodedError{Sentinel: ErrPaymentRequired, Code: CodeInsufficientCredits,
				Message: "billing: not enough credits", Fields: map[string]int64{"cost": 10, "available": 5, "shortfall": 5}},
			codes.FailedPrecondition, http.StatusPaymentRequired, CodeInsufficientCredits,
		},
		{
			"debt is 402",
			&CodedError{Sentinel: ErrPaymentRequired, Code: CodeCreditsDebt, Message: "billing: debt", Fields: map[string]int64{"debt": 7}},
			codes.FailedPrecondition, http.StatusPaymentRequired, CodeCreditsDebt,
		},
		{
			"price changed is 409",
			&CodedError{Sentinel: ErrConflict, Code: CodePriceChanged, Message: "billing: the price changed", Fields: map[string]int64{"cost": 13, "price_version": 2}},
			codes.AlreadyExists, http.StatusConflict, CodePriceChanged,
		},
		{
			"idempotency key reused is 409",
			&CodedError{Sentinel: ErrConflict, Code: CodeIdempotencyKeyReused, Message: "billing: this request was already made differently"},
			codes.AlreadyExists, http.StatusConflict, CodeIdempotencyKeyReused,
		},
		{
			"update required is 426",
			&CodedError{Sentinel: ErrUpgradeRequired, Code: CodeUpdateRequired, Message: "Update TieHere to host a meetup."},
			codes.FailedPrecondition, http.StatusUpgradeRequired, CodeUpdateRequired,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			wrapped := fmt.Errorf("meetup: create: %w", tt.err)
			st := status.Convert(ToGRPCStatus(wrapped))
			if st.Code() != tt.wantGRPC {
				t.Fatalf("gRPC code = %v, want %v", st.Code(), tt.wantGRPC)
			}
			if got := HTTPStatus(st); got != tt.wantHTTP {
				t.Fatalf("HTTP status = %d, want %d", got, tt.wantHTTP)
			}
			code, fields, ok := CodedFromStatus(st)
			if !ok || code != tt.wantCode {
				t.Fatalf("CodedFromStatus = %q, %v", code, ok)
			}
			var original *CodedError
			errors.As(tt.err, &original)
			for k, v := range original.Fields {
				if fields[k] != v {
					t.Errorf("field %s = %d, want %d", k, fields[k], v)
				}
			}
		})
	}
}

func TestSentinelsWithoutACodeStillMap(t *testing.T) {
	st := status.Convert(ToGRPCStatus(fmt.Errorf("x: %w", ErrPaymentRequired)))
	if st.Code() != codes.FailedPrecondition {
		t.Fatalf("code = %v", st.Code())
	}
	// No reason attached: a generic 400, never a 500.
	if got := HTTPStatus(st); got != http.StatusBadRequest {
		t.Fatalf("HTTP = %d, want 400", got)
	}
	if _, _, ok := CodedFromStatus(st); ok {
		t.Fatal("a plain sentinel must not invent a code")
	}
}

func TestHTTPStatusIgnoresAnUnknownReason(t *testing.T) {
	st := status.Convert(ToGRPCStatus(&CodedError{Sentinel: ErrConflict, Code: "something_else", Message: "x"}))
	if got := HTTPStatus(st); got != http.StatusConflict {
		t.Fatalf("HTTP = %d, want the code's own 409", got)
	}
}
