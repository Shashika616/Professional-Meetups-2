package auth

import (
	"context"
	"strings"
	"testing"
)

func TestCompleteProfileSetup_FullNameOnly(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	profile, err := svc.CompleteProfileSetup(context.Background(), CompleteProfileSetupRequest{
		UserID: "user-1", FullName: "Ada Lovelace",
	})
	if err != nil {
		t.Fatalf("CompleteProfileSetup() error: %v", err)
	}
	if profile.FullName != "Ada Lovelace" {
		t.Errorf("FullName = %q, want %q", profile.FullName, "Ada Lovelace")
	}
	if users.byID["user-1"].FullName != "Ada Lovelace" {
		t.Error("full name was not persisted")
	}
}

func TestCompleteProfileSetup_RejectsEmptyFullName(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	_, err := svc.CompleteProfileSetup(context.Background(), CompleteProfileSetupRequest{
		UserID: "user-1", FullName: "   ",
	})
	if err == nil {
		t.Fatal("CompleteProfileSetup() with a blank full name returned nil error, want error")
	}
}

// TestCompleteProfileSetup_RejectsOverLongFullName guards the server-side
// length bound added because nothing else did: users.full_name is a plain
// TEXT column with no length constraint, and the gateway decodes the
// request body with no size cap of its own (MaxBytes covers the whole
// body, not a per-field bound) — without this, a caller could persist an
// arbitrarily large full_name.
func TestCompleteProfileSetup_RejectsOverLongFullName(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	_, err := svc.CompleteProfileSetup(context.Background(), CompleteProfileSetupRequest{
		UserID: "user-1", FullName: strings.Repeat("a", maxFullNameLength+1),
	})
	if err == nil {
		t.Fatal("CompleteProfileSetup() with an over-long full name returned nil error, want error")
	}
}

func TestCompleteProfileSetup_RejectsOverLongCompanyName(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedUser(t, users, "user-1")

	_, err := svc.CompleteProfileSetup(context.Background(), CompleteProfileSetupRequest{
		UserID:       "user-1",
		FullName:     "Ada Lovelace",
		CompanyName:  strings.Repeat("a", maxCompanyNameLength+1),
		CompanyEmail: "ada@acmecorp.com",
	})
	if err == nil {
		t.Fatal("CompleteProfileSetup() with an over-long company name returned nil error, want error")
	}
}
