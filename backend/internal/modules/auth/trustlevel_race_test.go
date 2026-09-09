package auth

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

// Gap-tracker #17: trust_level must be computed from the row as it stands
// when the write happens, not from a snapshot the service read beforehand.
//
// # THE SCENARIO
//
// A user works through the Level 2 checklist. Two steps are in flight for
// the same user; one commits while the other is between its read and its
// write. Under the old design the second caller had already computed
// trust_level from a row that did not include the first caller's field, so
// its write stamped a level that ignored it — and nothing ever recomputes
// trust_level afterwards, so the user completes every Level 2 field and is
// silently stranded at Level 1.
//
// These tests reproduce the shape of that interleaving against the fake:
// the row already carries the OTHER caller's field by the time the callback
// runs, and the resulting trust level must account for both.
//
// # WHAT THIS CANNOT PROVE
//
// A fake repository has no transactions and no concurrency, so it cannot
// show that `SELECT ... FOR UPDATE` actually serialises two real
// connections. What it proves is the half that lives in this package: the
// value is derived from current state at write time rather than from a
// stale caller-supplied snapshot. Proving the lock itself would need a real
// Postgres integration test.

// Level 2 needs LinkedIn + phone + personal email + legal name
// (computeTrustLevel). Each test below leaves exactly one of those to the
// call under test and pre-sets the rest — standing in for concurrent steps
// that committed first.
func seedLevel2Except(t *testing.T, users *fakeUserRepository, id string, missing string) {
	t.Helper()
	u := repository.User{
		ID:            id,
		LinkedInSub:   "sub-" + id,
		FullName:      "Test User",
		TrustLevel:    1,
		AccountStatus: repository.AccountStatusActive,
		PhoneNumber:   "+94771234567",
		PersonalEmail: "ada@example.com",
		LegalName:     "Ada Lovelace",
	}
	switch missing {
	case "phone":
		u.PhoneNumber = ""
	case "email":
		u.PersonalEmail = ""
	case "details":
		u.LegalName = ""
	default:
		t.Fatalf("unknown field %q", missing)
	}
	users.byID[id] = u
}

func TestVerifyPhoneCode_RecomputesFromCurrentRow_NotAStaleSnapshot(t *testing.T) {
	svc, users, _, _, smsSender := newTestService(t)
	// Personal email and legal name are already committed — as they would be
	// if those two steps landed while this one was in flight.
	seedLevel2Except(t, users, "user-1", "phone")

	if _, err := svc.StartPhoneVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePhone, Target: "+94771234567",
	}); err != nil {
		t.Fatalf("StartPhoneVerification() error: %v", err)
	}

	session, err := svc.VerifyPhoneCode(context.Background(), VerifyCodeRequest{
		UserID:  "user-1",
		Purpose: VerificationPurposePhone,
		Target:  "+94771234567",
		Code:    smsSender.lastCode(),
	})
	if err != nil {
		t.Fatalf("VerifyPhoneCode() error: %v", err)
	}

	// Phone completes the Level 2 bundle. The old code computed this from a
	// snapshot carrying only the phone number and stamped 1.
	if got := users.byID["user-1"].TrustLevel; got != 2 {
		t.Errorf("stored trust_level = %d, want 2 — the recompute ignored the fields already on the row", got)
	}
	if session.TrustLevel != 2 {
		t.Errorf("session trust_level = %d, want 2 — this is the value signed into the new access token", session.TrustLevel)
	}
}

func TestVerifyPersonalEmailCode_RecomputesFromCurrentRow_NotAStaleSnapshot(t *testing.T) {
	svc, users, _, emailSender, _ := newTestService(t)
	seedLevel2Except(t, users, "user-1", "email")

	if _, err := svc.StartPersonalEmailVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposePersonalEmail, Target: "ada@example.com",
	}); err != nil {
		t.Fatalf("StartPersonalEmailVerification() error: %v", err)
	}

	session, err := svc.VerifyPersonalEmailCode(context.Background(), VerifyCodeRequest{
		UserID:  "user-1",
		Purpose: VerificationPurposePersonalEmail,
		Target:  "ada@example.com",
		Code:    emailSender.lastCode(),
	})
	if err != nil {
		t.Fatalf("VerifyPersonalEmailCode() error: %v", err)
	}

	if got := users.byID["user-1"].TrustLevel; got != 2 {
		t.Errorf("stored trust_level = %d, want 2", got)
	}
	if session.TrustLevel != 2 {
		t.Errorf("session trust_level = %d, want 2", session.TrustLevel)
	}
}

func TestSubmitPersonalDetails_RecomputesFromCurrentRow_NotAStaleSnapshot(t *testing.T) {
	svc, users, _, _, _ := newTestService(t)
	seedLevel2Except(t, users, "user-1", "details")

	session, err := svc.SubmitPersonalDetails(context.Background(), SubmitPersonalDetailsRequest{
		UserID:    "user-1",
		LegalName: "Ada Lovelace",
		Address:   "1 Example Street",
	})
	if err != nil {
		t.Fatalf("SubmitPersonalDetails() error: %v", err)
	}

	if got := users.byID["user-1"].TrustLevel; got != 2 {
		t.Errorf("stored trust_level = %d, want 2", got)
	}
	if session.TrustLevel != 2 {
		t.Errorf("session trust_level = %d, want 2", session.TrustLevel)
	}
}

// Level 3 = the Level 2 bundle + a verified work email + a company name. The
// same interleaving one level up: everything else is already on the row, and
// the corporate step has to notice.
func TestVerifyCorporateEmailCode_RecomputesFromCurrentRow_NotAStaleSnapshot(t *testing.T) {
	svc, users, _, emailSender, _, companies, _ := newTestServiceWithCompanies(t)
	users.byID["user-1"] = repository.User{
		ID:            "user-1",
		LinkedInSub:   "sub-user-1",
		FullName:      "Test User",
		TrustLevel:    2,
		AccountStatus: repository.AccountStatusActive,
		PhoneNumber:   "+94771234567",
		PersonalEmail: "ada@example.com",
		LegalName:     "Ada Lovelace",
	}
	companies.byNameNormalized["acme"] = repository.KnownCompany{
		NameNormalized: "acme",
		Domains:        []string{"acme.com"},
	}

	if _, err := svc.StartCorporateEmailVerification(context.Background(), StartVerificationRequest{
		UserID: "user-1", Purpose: VerificationPurposeCorporateEmail, Target: "ada@acme.com",
	}); err != nil {
		t.Fatalf("StartCorporateEmailVerification() error: %v", err)
	}

	session, err := svc.VerifyCorporateEmailCode(context.Background(), VerifyCodeRequest{
		UserID:      "user-1",
		Purpose:     VerificationPurposeCorporateEmail,
		Target:      "ada@acme.com",
		Code:        emailSender.lastCode(),
		CompanyName: "Acme",
	})
	if err != nil {
		t.Fatalf("VerifyCorporateEmailCode() error: %v", err)
	}

	if got := users.byID["user-1"].TrustLevel; got != 3 {
		t.Errorf("stored trust_level = %d, want 3", got)
	}
	if session.TrustLevel != 3 {
		t.Errorf("session trust_level = %d, want 3", session.TrustLevel)
	}
}
