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

// UserMessage is the last thing between a service error and an error toast
// on a phone. Developer prefixes, sentinel suffixes and snake_case names
// must not survive it, and server-side failures must never carry their
// raw text.
func TestUserMessage(t *testing.T) {
	cases := []struct {
		code codes.Code
		raw  string
		want string
	}{
		{codes.InvalidArgument, "meetup: window_start can't be in the past: invalid input",
			"Start time can't be in the past."},
		{codes.InvalidArgument, "meetup: window_end must be after window_start: invalid input",
			"End time must be after start time."},
		{codes.InvalidArgument, "meetup: capacity must be between 1 and 20: invalid input",
			"Capacity must be between 1 and 20."},
		{codes.InvalidArgument, `unknown intent "events"`,
			"That kind of meetup isn't available right now. Please update the app."},
		{codes.PermissionDenied, "meetup: hosting a coffee meetup requires trust level 3 (you are 2): forbidden",
			"Hosting a coffee meetup requires trust level 3 (you are 2)."},
		{codes.NotFound, "meetup: not found", "We couldn't find that."},
		{codes.NotFound, "auth: refresh token: not found", "We couldn't find that."},
		{codes.Unauthenticated, "auth: unauthorized", "Please sign in again."},
		{codes.Unauthenticated, "auth: access token expired: unauthorized", "Please sign in again."},
		{codes.ResourceExhausted, "auth: too many otp requests: rate limited",
			"Too many attempts. Please wait a moment and try again."},
		{codes.AlreadyExists, "meetup: already requested to join: conflict", "You've already asked to join this meetup."},
		// Ids interpolated for the log never reach the person, and neither
		// does a sentence written for a developer.
		{codes.FailedPrecondition, "repository: meetup 3f2a9c1e-1b2c-4d5e-8f90-a1b2c3d4e5f6 is full: conflict",
			"This meetup is full."},
		{codes.PermissionDenied, "meetup: caller does not host meetup 3f2a9c1e-1b2c-4d5e-8f90-a1b2c3d4e5f6: forbidden",
			"Only the host can do that."},
		{codes.InvalidArgument, "purpose mismatch for VerifyPhoneCode: invalid input",
			"That request couldn't be completed. Please check and try again."},
		{codes.InvalidArgument, `repository: invalid user id "nope": invalid input`,
			"That request couldn't be completed. Please check and try again."},
		{codes.InvalidArgument, "auth: latitude/longitude of exactly (0, 0) is not a real location — this usually means a location fix was never acquired: invalid input",
			"We couldn't read your location. Please try again."},
		{codes.InvalidArgument, "linkedin sign-in failed, please try again: invalid input",
			"LinkedIn sign-in failed, please try again."},
		{codes.InvalidArgument, "connect LinkedIn before verifying phone, email, or personal details: invalid input",
			"Connect LinkedIn before verifying phone, email, or personal details."},
		{codes.AlreadyExists, "You are hosting a meetup that has not happened yet. Attend it, or cancel it, then delete your account: conflict",
			"You are hosting a meetup that has not happened yet. Attend it, or cancel it, then delete your account."},
		{codes.InvalidArgument, "auth: note — too long: invalid input", "Note, too long."},
		// The trust gates' real wording. The number is the message here (it
		// arrives as a locked toast), so it must survive, minus "caller".
		{codes.PermissionDenied, `meetup: hosting a "coffee" meetup requires trust level 3, caller has 2: forbidden`,
			`Hosting a "coffee" meetup requires Level 3 trust. You are Level 2.`},
		{codes.PermissionDenied, "auth: triggering SOS requires trust level 2, caller has 1: forbidden",
			"Triggering SOS requires Level 2 trust. You are Level 1."},
		// Two messages that both mention linkedin_sub and mean opposite
		// things: only the repository's duplicate-account one is a
		// sentence about an existing account.
		{codes.InvalidArgument, `repository: user with linkedin_sub "3f2a9c1e-1b2c-4d5e-8f90-a1b2c3d4e5f6" already exists: invalid input`,
			"That LinkedIn account already has a TieHere account."},
		{codes.InvalidArgument, `service: "apple" has no user_identities row — LinkedIn identity lives on users.linkedin_sub: invalid input`,
			"That request couldn't be completed. Please check and try again."},
		{codes.InvalidArgument, `repository: invalid notification recipient "3f2a9c1e-1b2c-4d5e-8f90-a1b2c3d4e5f6": invalid input`,
			"That request couldn't be completed. Please check and try again."},
		// Server-side classes never expose their text.
		{codes.Unknown, `monolithclient: unknown intent "events"`,
			"Something went wrong on our side. Please try again in a moment."},
		{codes.Internal, "pq: connection refused to 10.0.0.5:5432",
			"Something went wrong on our side. Please try again in a moment."},
		{codes.Unavailable, "transport is closing",
			"Something went wrong on our side. Please try again in a moment."},
	}
	for _, c := range cases {
		if got := UserMessage(c.code, c.raw); got != c.want {
			t.Errorf("UserMessage(%v, %q)\n got  %q\n want %q", c.code, c.raw, got, c.want)
		}
	}
}

// Every message Plan 26 and ADR-009 added that can reach a person, checked
// against the filter that is supposed to make it presentable.
//
// # WHY A CORPUS TEST AND NOT ONE ASSERTION PER STRING
//
// The failure this guards against is not a wrong sentence, it is a message
// nobody thought about reaching a user at all. "request ... changed meetup
// under the lock" was a can't-happen guard written for whoever reads the
// logs; with the "repository: " prefix and the uuid stripped it came out of
// this filter as "Request changed meetup under the lock." and went to a
// phone. So the rule is checked mechanically for the whole set, and a new
// message added to the list below is checked the moment it is listed.
func TestUserMessage_NoDeveloperLanguageReachesTheUser(t *testing.T) {
	// Raw service and repository messages, exactly as the layers below
	// produce them: sentinel suffix, prefixes and interpolated ids included.
	raws := []struct {
		code codes.Code
		raw  string
	}{
		{codes.AlreadyExists, "repository: an account already uses this email address: conflict"},
		{codes.AlreadyExists, "repository: meetup 5cb774a6-8283-4f4e-9075-6cd06b64b86e is completed and can no longer be cancelled: conflict"},
		{codes.AlreadyExists, "repository: meetup 5cb774a6-8283-4f4e-9075-6cd06b64b86e is cancelled and can no longer be cancelled: conflict"},
		{codes.AlreadyExists, "repository: request 5cb774a6-8283-4f4e-9075-6cd06b64b86e is not pending: conflict"},
		{codes.AlreadyExists, "repository: request 5cb774a6-8283-4f4e-9075-6cd06b64b86e changed meetup under the lock: conflict"},
		{codes.AlreadyExists, "an account already exists for this email address"},
		{codes.InvalidArgument, "this request has expired, please sign in again: invalid input"},
		{codes.InvalidArgument, "that account is no longer available, please sign in again: invalid input"},
		{codes.InvalidArgument, "too many attempts, please request a new code: invalid input"},
		{codes.InvalidArgument, "no pending verification code, please request a new one: invalid input"},
		{codes.InvalidArgument, "code expired, please request a new one: invalid input"},
		{codes.InvalidArgument, "invalid code: invalid input"},
	}

	// Vocabulary that is always a sign the sentence was written for a
	// developer. Separate from userMessageDeveloperMarkers on purpose: this
	// is the assertion, that list is the implementation, and a test that
	// read the same list could not catch a word missing from it.
	forbidden := []string{
		"lock", "transaction", "rollback", "constraint", "deadlock", "index",
		"repository:", "service:", "sql", "pgx", "rpc", "goroutine", "nil",
		"panic", "uuid", "_", "%!", "conflict:", "invalid input",
	}

	for _, c := range raws {
		got := UserMessage(c.code, c.raw)
		if got == "" {
			t.Errorf("UserMessage(%v, %q) returned empty; every code has a default", c.code, c.raw)
			continue
		}
		lower := strings.ToLower(got)
		for _, word := range forbidden {
			if strings.Contains(lower, word) {
				t.Errorf("UserMessage(%v, %q)\n  = %q\n  contains developer language %q", c.code, c.raw, got, word)
			}
		}
		// A sentence a person reads: starts capitalised, ends in a stop.
		if r := []rune(got)[0]; r != []rune(strings.ToUpper(string(r)))[0] {
			t.Errorf("UserMessage(%v, %q) = %q does not start with a capital", c.code, c.raw, got)
		}
		if !strings.HasSuffix(got, ".") && !strings.HasSuffix(got, "?") {
			t.Errorf("UserMessage(%v, %q) = %q does not end in a full stop", c.code, c.raw, got)
		}
		// No uuid survived the strip, and no doubled space was left behind
		// by removing one.
		if strings.Contains(got, "  ") {
			t.Errorf("UserMessage(%v, %q) = %q has a doubled space where something was stripped", c.code, c.raw, got)
		}
	}
}

// The two sentences V-10 produces are worth pinning by value, because their
// whole point is telling a host which of the two happened.
func TestUserMessage_CancelGuardSentences(t *testing.T) {
	cases := map[string]string{
		"repository: meetup 5cb774a6-8283-4f4e-9075-6cd06b64b86e is completed and can no longer be cancelled: conflict": "That meetup has already finished, so it can't be cancelled.",
		"repository: meetup 5cb774a6-8283-4f4e-9075-6cd06b64b86e is cancelled and can no longer be cancelled: conflict": "That meetup is already cancelled.",
	}
	for raw, want := range cases {
		if got := UserMessage(codes.AlreadyExists, raw); got != want {
			t.Errorf("UserMessage(%q)\n  = %q\n want %q", raw, got, want)
		}
	}
}
