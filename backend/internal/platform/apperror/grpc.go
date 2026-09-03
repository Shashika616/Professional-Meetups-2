package apperror

import (
	"errors"
	"log/slog"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// genericInternalMessage is what a codes.Internal status carries back to the
// client — the real err is logged server-side instead. codes.Internal is
// the catch-all for raw repository/driver errors and any other unclassified
// failure (see grpcCode's default branch below), which routinely embed
// implementation detail — SQL driver text, connection strings — that must
// never cross the trust boundary into an untrusted client response.
const genericInternalMessage = "internal error"

// ToGRPCStatus maps err to a gRPC status error by matching it against the
// sentinel errors in this package via errors.Is, so a service-layer error
// wrapped as fmt.Errorf("...: %w", ErrNotFound) arrives at the caller as a
// codes.NotFound status. Anything that doesn't match a known sentinel maps
// to codes.Internal — services should wrap ErrInternal explicitly rather
// than relying on this fallback, so the mapping stays intentional.
//
// codes.Internal is the one mapping where err.Error() is never handed to
// the caller: the full error is logged server-side via slog.Default() and
// genericInternalMessage is returned instead, so an unclassified failure
// can't leak implementation detail to an untrusted client.
func ToGRPCStatus(err error) error {
	if err == nil {
		return nil
	}
	code := grpcCode(err)
	if code == codes.Internal {
		slog.Default().Error("internal error", "error", err)
		return status.Error(code, genericInternalMessage)
	}
	return status.Error(code, err.Error())
}

func grpcCode(err error) codes.Code {
	switch {
	case errors.Is(err, ErrNotFound):
		return codes.NotFound
	case errors.Is(err, ErrInvalidInput):
		return codes.InvalidArgument
	case errors.Is(err, ErrUnauthorized):
		return codes.Unauthenticated
	case errors.Is(err, ErrForbidden):
		return codes.PermissionDenied
	case errors.Is(err, ErrConflict):
		return codes.AlreadyExists
	case errors.Is(err, ErrRateLimited):
		return codes.ResourceExhausted
	default:
		return codes.Internal
	}
}
