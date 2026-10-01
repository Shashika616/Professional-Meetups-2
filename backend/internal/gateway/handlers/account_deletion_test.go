package handlers

import (
	"errors"
	"net/http"
	"slices"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// DELETE /v1/users/me asks the meetup service first and the auth service
// second. These tests pin that order, the user id both are given, and what
// the app is shown when either says no.

func TestDeleteAccount_ChecksThenDeletesTheTokenUser(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodDelete, "/v1/users/me", `{"user_id":"victim"}`, s.tokenFor(t, "user-1", 1))

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204; body %s", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Errorf("204 body = %q, want empty", rec.Body.String())
	}
	want := []string{"check:user-1", "delete:user-1"}
	if !slices.Equal(s.monolith.deleteCalls, want) {
		t.Errorf("calls = %v, want %v (the body's user_id must be ignored)", s.monolith.deleteCalls, want)
	}
}

func TestDeleteAccount_ActiveMeetupsStopTheDeleteWithAHumanMessage(t *testing.T) {
	s := newTestServer(t)
	// Exactly what the meetup service sends: its sentence plus the
	// sentinel suffix, which the person must never see.
	s.monolith.deletableErr = status.Error(codes.AlreadyExists,
		"You are hosting a meetup that has not happened yet. Attend it, or cancel it, then delete your account: conflict")

	rec := s.do(http.MethodDelete, "/v1/users/me", "", s.tokenFor(t, "user-1", 1))

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409; body %s", rec.Code, rec.Body.String())
	}
	got := decodeBody(t, rec)["error"]
	want := "You are hosting a meetup that has not happened yet. Attend it, or cancel it, then delete your account."
	if got != want {
		t.Errorf("error = %q, want %q", got, want)
	}
	if slices.Contains(s.monolith.deleteCalls, "delete:user-1") {
		t.Error("the account was deleted even though the check refused")
	}
}

func TestDeleteAccount_FailuresNeverLeakInternals(t *testing.T) {
	for _, tc := range []struct {
		name                string
		checkErr, deleteErr error
	}{
		{"check fails", status.Error(codes.Internal, "meetup: count active commitments: pq: connection reset"), nil},
		{"delete fails", nil, status.Error(codes.Internal, "auth: delete user: deadlock detected")},
		{"not a status error", nil, errors.New("rpc error: transport is closing")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(t)
			s.monolith.deletableErr = tc.checkErr
			s.monolith.deleteErr = tc.deleteErr

			rec := s.do(http.MethodDelete, "/v1/users/me", "", s.tokenFor(t, "user-1", 1))

			if rec.Code < 500 {
				t.Fatalf("status = %d, want 5xx", rec.Code)
			}
			if got := decodeBody(t, rec)["error"]; got != "Something went wrong on our side. Please try again in a moment." {
				t.Errorf("error = %q, leaks internals", got)
			}
		})
	}
}

func TestDeleteAccount_RequiresSignIn(t *testing.T) {
	s := newTestServer(t)
	rec := s.do(http.MethodDelete, "/v1/users/me", "", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if len(s.monolith.deleteCalls) != 0 {
		t.Errorf("calls = %v, want none", s.monolith.deleteCalls)
	}
}
