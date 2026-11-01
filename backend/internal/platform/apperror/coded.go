package apperror

import (
	"net/http"
	"strconv"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/status"
)

// The machine-readable codes a client branches on. They are part of the
// public contract (docs/api/billing.md): add, never rename.
const (
	CodeInsufficientCredits = "insufficient_credits"
	CodeCreditsDebt         = "credits_debt"
	CodePriceChanged        = "price_changed"
	CodeUpdateRequired      = "update_required"
	// CodeIdempotencyKeyReused is an Idempotency-Key sent again with a
	// different request, or after its reservation can no longer be reused.
	CodeIdempotencyKeyReused = "idempotency_key_reused"
)

// errorInfoDomain names this application in the ErrorInfo detail.
const errorInfoDomain = "tiehere.app"

// codeHTTPStatus is the HTTP status for each code. A code missing here gets
// its sentinel's ordinary status.
var codeHTTPStatus = map[string]int{
	CodeInsufficientCredits:  http.StatusPaymentRequired,
	CodeCreditsDebt:          http.StatusPaymentRequired,
	CodePriceChanged:         http.StatusConflict,
	CodeUpdateRequired:       http.StatusUpgradeRequired,
	CodeIdempotencyKeyReused: http.StatusConflict,
}

// CodedError is a sentinel error plus a stable code and a few numbers the
// client needs to act — {cost, available, shortfall} for a 402.
//
// It crosses gRPC as an ErrorInfo detail (reason = Code, metadata = Fields),
// which keeps this package free of any module's proto and lets the gateway
// build the HTTP body without knowing which module raised it.
type CodedError struct {
	Sentinel error
	Code     string
	Message  string
	Fields   map[string]int64
}

func (e *CodedError) Error() string { return e.Message + ": " + e.Sentinel.Error() }

// Unwrap lets errors.Is(err, ErrPaymentRequired) and the gRPC code mapping
// see the sentinel.
func (e *CodedError) Unwrap() error { return e.Sentinel }

// withErrorInfo attaches the coded error's detail to st. Attaching cannot
// fail for a well-formed ErrorInfo; if it somehow did, the plain status
// still carries the code and message.
func withErrorInfo(st *status.Status, coded *CodedError) *status.Status {
	md := make(map[string]string, len(coded.Fields))
	for k, v := range coded.Fields {
		md[k] = strconv.FormatInt(v, 10)
	}
	if detailed, err := st.WithDetails(&errdetails.ErrorInfo{
		Reason:   coded.Code,
		Domain:   errorInfoDomain,
		Metadata: md,
	}); err == nil {
		return detailed
	}
	return st
}

// CodedFromStatus reads a coded error's code and numbers back off a status.
func CodedFromStatus(st *status.Status) (code string, fields map[string]int64, ok bool) {
	for _, d := range st.Details() {
		info, isInfo := d.(*errdetails.ErrorInfo)
		if !isInfo || info.GetDomain() != errorInfoDomain || info.GetReason() == "" {
			continue
		}
		fields = make(map[string]int64, len(info.GetMetadata()))
		for k, v := range info.GetMetadata() {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				fields[k] = n
			}
		}
		return info.GetReason(), fields, true
	}
	return "", nil, false
}

// HTTPStatus is HTTPStatusFromGRPC, refined by a coded error's code where one
// is attached: a 402 and a 426 both travel as FAILED_PRECONDITION, and only
// the code tells them apart.
func HTTPStatus(st *status.Status) int {
	if code, _, ok := CodedFromStatus(st); ok {
		if s, known := codeHTTPStatus[code]; known {
			return s
		}
	}
	return HTTPStatusFromGRPC(st.Code())
}
