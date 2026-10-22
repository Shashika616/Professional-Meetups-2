package handlers

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

// WHO IS ALLOWED TO DELETE AN ACCOUNT: only the person who owns it.
//
// The guarantee is structural rather than a check somewhere in the handler.
// `DELETE /v1/users/me` takes NO user identifier of any kind — not a path
// segment, not a query parameter, not a body field. The id it acts on comes
// from `middleware.UserIDFromContext`, which is populated only by
// `middleware.Auth` after `verifier.Verify` has validated the token's
// signature. There is no other deletion route, no admin path, and no header
// that influences identity.
//
// These tests pin that shape, because the way it would be lost is not
// somebody removing the auth middleware — it is somebody adding a
// convenience `user_id` field to the request and wiring it up.
type deleteFake struct {
	monolithclient.Client

	checkedID string
	deletedID string
	checkErr  error
	deleteErr error
}

func (f *deleteFake) CheckAccountDeletable(_ context.Context, userID string) error {
	f.checkedID = userID
	return f.checkErr
}

func (f *deleteFake) DeleteAccount(_ context.Context, userID string) error {
	f.deletedID = userID
	return f.deleteErr
}

// doAuthed builds a request carrying both a body and a bearer token, which
// the shared do() helper's signature cannot express on a DELETE.
func (s *claimServer) doAuthed(method, path, body, bearer string) *http.Request {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	return r
}

func TestDeleteAccount_OnlyTheAccountHolder(t *testing.T) {
	t.Run("no token deletes nothing", func(t *testing.T) {
		fake := &deleteFake{}
		s := newTestServerWithMonolith(t, fake)

		rec := s.do(http.MethodDelete, "/v1/users/me", "", "")
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want 401", rec.Code)
		}
		if fake.deletedID != "" || fake.checkedID != "" {
			t.Errorf("an unauthenticated request reached the service: checked=%q deleted=%q", fake.checkedID, fake.deletedID)
		}
	})

	t.Run("a token this gateway did not sign deletes nothing", func(t *testing.T) {
		fake := &deleteFake{}
		s := newTestServerWithMonolith(t, fake)

		// A structurally plausible JWT signed by somebody else.
		forged := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9." +
			"eyJ1c2VyX2lkIjoidmljdGltLTEiLCJ0cnVzdF9sZXZlbCI6Mn0.not-a-real-signature"
		rec := s.doRequest(s.doAuthed(http.MethodDelete, "/v1/users/me", "", forged))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("status = %d, want 401", rec.Code)
		}
		if fake.deletedID != "" {
			t.Errorf("a forged token deleted %q", fake.deletedID)
		}
	})

	t.Run("a valid token deletes exactly its own subject", func(t *testing.T) {
		fake := &deleteFake{}
		s := newTestServerWithMonolith(t, fake)

		rec := s.doRequest(s.doAuthed(http.MethodDelete, "/v1/users/me", "", s.tokenFor(t, "user-1", 2)))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204 (body: %s)", rec.Code, rec.Body.String())
		}
		if fake.deletedID != "user-1" || fake.checkedID != "user-1" {
			t.Errorf("checked=%q deleted=%q, want both user-1", fake.checkedID, fake.deletedID)
		}
	})

	// THE ONE THAT GUARDS THE FUTURE. If anyone ever teaches this route to
	// read an id from the request, this fails.
	t.Run("a body naming someone else is ignored", func(t *testing.T) {
		fake := &deleteFake{}
		s := newTestServerWithMonolith(t, fake)

		rec := s.doRequest(s.doAuthed(
			http.MethodDelete, "/v1/users/me?user_id=victim-1",
			`{"user_id":"victim-1","id":"victim-1"}`,
			s.tokenFor(t, "attacker-1", 2),
		))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204 (body: %s)", rec.Code, rec.Body.String())
		}
		if fake.deletedID != "attacker-1" {
			t.Fatalf("deleted %q — the route took an identifier from the request instead of the token", fake.deletedID)
		}
	})

	// And the blocked case still blocks, so the ownership check is not the
	// only thing standing between a user and a deletion.
	t.Run("a live commitment still blocks the caller's own deletion", func(t *testing.T) {
		s := newTestServerWithMonolith(t, &deleteFake{
			checkErr: status.Error(codes.AlreadyExists, "You are hosting a meetup that has not happened yet."),
		})

		rec := s.doRequest(s.doAuthed(http.MethodDelete, "/v1/users/me", "", s.tokenFor(t, "user-1", 2)))
		if rec.Code != http.StatusConflict {
			t.Errorf("status = %d, want 409 (body: %s)", rec.Code, rec.Body.String())
		}
	})
}
