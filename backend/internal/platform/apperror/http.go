package apperror

import (
	"net/http"
	"strings"

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

// UserMessage turns the message carried on a gRPC status into something a
// person can read in an error toast. Two rules:
//
//   - Codes that mean "our problem" (Internal, Unknown, Unavailable,
//     DeadlineExceeded, and anything else not in the client-facing set)
//     get one fixed sentence. Their raw text is for logs, never for the
//     phone — ToGRPCStatus already redacts Internal, but a plain error the
//     gateway itself produced arrives as Unknown with its full text intact.
//   - Codes that mean "your request" keep their sentence, minus the
//     module prefixes ("meetup: ", "auth: "), the sentinel suffixes
//     (": invalid input") and the snake_case field names that service
//     errors carry for developers.
//
// The gateway calls this in the one place status messages become HTTP
// bodies, so no handler needs to think about it.
func UserMessage(code codes.Code, raw string) string {
	switch code {
	case codes.NotFound, codes.Unauthenticated, codes.ResourceExhausted:
		// Service messages for these name the thing that was missing or
		// the check that failed ("refresh token: not found") — useful in a
		// log, a bare noun once the sentinel is stripped. The per-code
		// sentence is always the better thing to show.
		return defaultUserMessage(code)
	case codes.InvalidArgument, codes.AlreadyExists, codes.PermissionDenied,
		codes.FailedPrecondition:
		// These carry a real sentence worth keeping: what was wrong with the
		// request, or which level unlocks the action.
		if m := tidyUserMessage(raw); m != "" {
			return m
		}
		return defaultUserMessage(code)
	default:
		return "Something went wrong on our side. Please try again in a moment."
	}
}

func defaultUserMessage(code codes.Code) string {
	switch code {
	case codes.NotFound:
		return "We couldn't find that."
	case codes.Unauthenticated:
		return "Please sign in again."
	case codes.PermissionDenied:
		return "You don't have access to that."
	case codes.ResourceExhausted:
		return "Too many attempts. Please wait a moment and try again."
	case codes.AlreadyExists:
		return "That already exists."
	default:
		return "That request couldn't be completed. Please check and try again."
	}
}

// Prefixes service layers put on their errors for log readers, in the
// order they should be stripped (a message may carry more than one).
var userMessagePrefixes = []string{
	"meetup: ", "auth: ", "notification: ", "billing: ", "monolithclient: ",
	"gateway: ", "verification: ", "identity: ", "repository: ",
}

// Sentinel suffixes appended by fmt.Errorf("...: %w", apperror.ErrX).
var userMessageSuffixes = []string{
	": invalid input", ": not found", ": unauthorized", ": conflict",
	": forbidden", ": rate limited", ": internal error",
}

// Developer field names that show up inside validation sentences.
var userMessageFieldNames = map[string]string{
	"window_start":     "start time",
	"window_end":       "end time",
	"location_label":   "location name",
	"location_lat":     "location",
	"location_lng":     "location",
	"within_days":      "date range",
	"page_size":        "page size",
	"viewer_lat":       "your location",
	"viewer_lng":       "your location",
	"hosted_cursor":    "page",
	"requested_cursor": "page",
	"cursor":           "page",
	"trust_level":      "trust level",
	"user_id":          "account",
	"meetup_id":        "meetup",
}

func tidyUserMessage(raw string) string {
	m := strings.TrimSpace(raw)
	for changed := true; changed; {
		changed = false
		for _, p := range userMessagePrefixes {
			if strings.HasPrefix(m, p) {
				m = strings.TrimPrefix(m, p)
				changed = true
			}
		}
		for _, sfx := range userMessageSuffixes {
			if strings.HasSuffix(m, sfx) {
				m = strings.TrimSuffix(m, sfx)
				changed = true
			}
		}
	}
	m = strings.TrimSpace(m)
	// A message that was nothing but a sentinel ("not found") says nothing
	// a person can act on — let the per-code default speak instead.
	for _, sfx := range userMessageSuffixes {
		if m == strings.TrimPrefix(sfx, ": ") {
			return ""
		}
	}
	for field, words := range userMessageFieldNames {
		m = strings.ReplaceAll(m, field, words)
	}
	if m == "" {
		return ""
	}
	// Sentence case and a full stop, unless it already ends with
	// punctuation (a question, or a message that carried its own).
	first, rest := m[:1], m[1:]
	m = strings.ToUpper(first) + rest
	if !strings.HasSuffix(m, ".") && !strings.HasSuffix(m, "!") && !strings.HasSuffix(m, "?") {
		m += "."
	}
	return m
}
