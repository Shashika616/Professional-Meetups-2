package apperror

import (
	"net/http"

	"google.golang.org/grpc/codes"
)

// HTTPStatusFromGRPC maps a gRPC status code (as returned by a service call
// through ToGRPCStatus) to the HTTP status code the gateway should return to
// REST clients. This is the one place that translation happens — gateway
// handlers should call this rather than switching on gRPC codes themselves.
func HTTPStatusFromGRPC(code codes.Code) int {
	switch code {
	case codes.OK:
		return http.StatusOK
	case codes.NotFound:
		return http.StatusNotFound
	case codes.InvalidArgument:
		return http.StatusBadRequest
	case codes.Unauthenticated:
		return http.StatusUnauthorized
	case codes.PermissionDenied:
		return http.StatusForbidden
	case codes.AlreadyExists:
		return http.StatusConflict
	case codes.ResourceExhausted:
		return http.StatusTooManyRequests
	case codes.DeadlineExceeded:
		return http.StatusGatewayTimeout
	case codes.Unavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusInternalServerError
	}
}
