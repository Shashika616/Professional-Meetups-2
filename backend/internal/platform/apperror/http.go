package apperror

import (
	"net/http"
	"regexp"
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
	"gateway: ", "verification: ", "identity: ", "repository: ", "service: ",
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

// uuidPattern matches an id interpolated into a message for the log
// ("meetup 3f2a...-... is full"), with the quotes %q puts around it.
var uuidPattern = regexp.MustCompile(`\s*"?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"?`)

// trustGatePattern rewrites the trust gates' own phrasing (auth's
// requireSafetyFeatureTrustLevel, meetup's checkTrustLevel) into the
// vocabulary the app already uses for levels ("Level 2 trust").
//
// This one is a rewrite rather than a drop because the number IS the
// message: these arrive as a locked toast the person is meant to act on,
// and "you don't have access" would not tell them that verifying one more
// thing is what opens the door. The developer word this removes is
// "caller".
var trustGatePattern = regexp.MustCompile(`requires trust level (\d+), caller has (\d+)`)

// userMessageRewrites replaces sentences written for a log reader with
// ones written for the person. Matched, in order, as a lowercase substring
// of the message once prefixes, suffixes and ids are gone; the first match
// wins and replaces the whole message.
var userMessageRewrites = []struct{ contains, say string }{
	// Location validation (platform/geo) reaches SOS and meetup creation.
	{"latitude", "We couldn't read your location. Please try again."},
	{"longitude", "We couldn't read your location. Please try again."},

	{"caller does not host meetup", "Only the host can do that."},
	{"only the host can", "Only the host can do that."},
	{"caller is not a participant of meetup", "You're not part of this meetup."},
	{"caller did not make request", "That request isn't yours."},
	{"not owned by caller", "That request is no longer pending."},
	{"not a pending request of this user", "That request is no longer pending."},
	{"neither pending nor accepted", "That request is no longer active."},
	{"is not pending", "That request has already been answered."},

	// Plan 26 (V-10). The repository names the state it found, which is what
	// an operator wants in a log and not what a host wants in a toast:
	// unrewritten these came out as "Meetup is completed and can no longer
	// be cancelled." Two entries rather than one loose match, so each state
	// gets the sentence that is actually true of it.
	{"is completed and can no longer be cancelled", "That meetup has already finished, so it can't be cancelled."},
	{"is cancelled and can no longer be cancelled", "That meetup is already cancelled."},

	// Plan 26 (V-1). "No pending verification code" is accurate and mildly
	// technical; the person just needs to know to ask for another.
	{"no pending verification code", "We don't have a code waiting for you. Please request a new one."},
	{"caller does not own trusted contact", "That contact isn't in your list."},
	{"none of those contacts belong to you", "Those contacts aren't in your list."},
	{"is full", "This meetup is full."},
	{"is not open", "This meetup is no longer open."},
	{"already closed or cancelled", "This meetup has already ended or been cancelled."},
	{"already requested to join", "You've already asked to join this meetup."},
	{"cannot request to join your own meetup", "You can't join your own meetup."},

	{"already rated", "You've already rated them for this meetup."},
	{"is already reviewed", "You've already reviewed this meetup."},
	{"appears twice in the review", "Rate each person only once."},
	{"every participant must be rated", "Rate everyone who came before you submit."},
	{"not a ratable participant", "You can't rate that person for this meetup."},
	{"rated user is not a participant", "You can't rate that person for this meetup."},
	{"not yet eligible to rate", "You can rate them once the meetup is over."},
	{"has not started yet", "This meetup hasn't started yet."},
	{"is not over yet", "You can review this meetup once it's over."},
	{"duplicate trait", "Pick each trait only once."},
	{"unknown trait", "That trait isn't available. Please update the app."},
	{"traits per participant", "You've picked too many traits for one person."},
	{"score for", "Scores must be between 1 and 5."},

	{"linkedin account already linked", "That LinkedIn account is already linked to another TieHere account."},
	// Scoped to the repository's "already exists": the phrase `linkedin_sub`
	// alone also appears in an internal invariant error about a missing
	// user_identities row, which means the opposite of this sentence.
	{"linkedin_sub already exists", "That LinkedIn account already has a TieHere account."},
	{"identity already linked", "That sign-in is already linked to another TieHere account."},
	{"personal email already verified", "That email is already verified on another account."},
	{"phone number already verified", "That phone number is already verified on another account."},
	{"work email hash already claimed", "That work email is already verified on another account."},
	{"invalid code", "That code isn't right. Check it and try again."},

	{"cursor", "We couldn't load more. Please refresh and try again."},
	// The app sent a meetup type this server does not know: an old server
	// or a newer app. Either way the person cannot fix it by retyping.
	{"intent", "That kind of meetup isn't available right now. Please update the app."},
}

// userMessageDeveloperMarkers identify a sentence that no rewrite covered
// and that was plainly written for a developer. Such a message is dropped
// for the per-code default: vague beats unreadable.
var userMessageDeveloperMarkers = []string{
	"purpose mismatch", "caller", "repository", "batch size", "unsupported",
	"target ", " id ", " row ", "hash", "_", "%!", "token", "recipient",
	"invalid rating", "invalid overall score", "pgx", "sql", "rpc",
	// Concurrency and persistence vocabulary (added with Plan 26). The
	// locking work added messages like "request ... changed meetup under the
	// lock" — a can't-happen guard whose text, once the "repository: "
	// prefix and the uuid were stripped, came out of this filter as
	// "Request changed meetup under the lock." and went to a user.
	//
	// Checked before adding: every backend message containing any of these
	// is an internal or repository-level error that is never meant to be
	// read by a person, so dropping them for the per-code default loses
	// nothing a user could have acted on.
	"lock", "transaction", "constraint", "rollback", "deadlock",
}

func tidyUserMessage(raw string) string {
	m := strings.TrimSpace(raw)
	m = uuidPattern.ReplaceAllString(m, "")
	m = trustGatePattern.ReplaceAllString(m, "requires Level $1 trust. You are Level $2")
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
	lower := strings.ToLower(m)
	for _, r := range userMessageRewrites {
		if strings.Contains(lower, r.contains) {
			return r.say
		}
	}
	for field, words := range userMessageFieldNames {
		m = strings.ReplaceAll(m, field, words)
	}
	// Padded so a marker like " id " also catches the id that ends a
	// sentence, without catching "identity".
	lower = " " + strings.ToLower(strings.TrimRight(m, ".")) + " "
	for _, marker := range userMessageDeveloperMarkers {
		if strings.Contains(lower, marker) {
			return ""
		}
	}
	// No dashes in anything a person reads (house style).
	m = strings.ReplaceAll(m, " — ", ", ")
	m = strings.ReplaceAll(m, "—", ", ")
	m = strings.ReplaceAll(m, "linkedin", "LinkedIn")
	m = strings.ReplaceAll(m, "Linkedin", "LinkedIn")
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
