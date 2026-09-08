package auth

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestGuestSignup_CreatesAReadOnlyGuestAccount covers the whole happy path in
// one place: a real session, a real persisted row, is_guest set, and trust
// level 0.
func TestGuestSignup_CreatesAReadOnlyGuestAccount(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	session, err := svc.GuestSignup(context.Background(), GuestSignupRequest{AgeConfirmedOver18: true})
	if err != nil {
		t.Fatalf("GuestSignup: %v", err)
	}

	// A REAL session, not a stub — the same shape every other signup path
	// returns, because a guest is a real account.
	if session.UserID == "" {
		t.Error("no user id in the session")
	}
	if session.RefreshToken == "" {
		t.Error("no refresh token issued — a guest gets a real, refreshable session")
	}
	if !session.IsNewUser {
		t.Error("IsNewUser = false; a guest signup always creates an account")
	}
	if session.TrustLevel != 0 {
		t.Errorf("session TrustLevel = %d, want 0", session.TrustLevel)
	}

	// A REAL persisted row — this is what makes the upgrade path work later.
	created, ok := deps.users.byID[session.UserID]
	if !ok {
		t.Fatal("no auth.users row was created")
	}
	if !created.IsGuest {
		t.Error("IsGuest = false on a guest account")
	}
	if created.TrustLevel != 0 {
		t.Errorf("stored TrustLevel = %d, want 0", created.TrustLevel)
	}
	if !created.AgeConfirmedOver18 {
		t.Error("AgeConfirmedOver18 = false — the attestation must be recorded, same as every other path")
	}

	// Nothing identifying was invented for the account.
	if created.PersonalEmail != "" || created.PhoneNumber != "" || created.LinkedInSub != "" || created.LegalName != "" {
		t.Errorf("a guest account was created with identity data: %+v", created)
	}
}

// TestGuestSignup_RejectsMissingAgeAttestation pins that guests are not
// special-cased. The check must run BEFORE anything is written, so a rejected
// attempt leaves no row behind — otherwise repeated rejected calls would be a
// way to fill the users table.
func TestGuestSignup_RejectsMissingAgeAttestation(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	_, err := svc.GuestSignup(context.Background(), GuestSignupRequest{AgeConfirmedOver18: false})
	if err == nil {
		t.Fatal("GuestSignup succeeded without the 18+ attestation")
	}
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want it to wrap apperror.ErrInvalidInput (same sentinel as every other signup path)", err)
	}
	if len(deps.users.createCalls) != 0 {
		t.Errorf("Create was called %d times for a rejected signup, want 0 — the age check must run before any write", len(deps.users.createCalls))
	}
}

// TestGuestSignup_GeneratesADistinctHandleEachTime is not a uniqueness test —
// collisions are explicitly acceptable — it just confirms the generator is
// not returning a constant, which would make every guest look like the same
// person on a meetup card.
func TestGuestSignup_GeneratesADistinctHandleEachTime(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	const runs = 20
	seen := map[string]int{}
	for i := 0; i < runs; i++ {
		session, err := svc.GuestSignup(context.Background(), GuestSignupRequest{AgeConfirmedOver18: true})
		if err != nil {
			t.Fatalf("GuestSignup #%d: %v", i+1, err)
		}
		seen[deps.users.byID[session.UserID].FullName]++
	}

	if len(seen) < 2 {
		t.Fatalf("all %d guest handles were identical (%v) — the generator is returning a constant", runs, seen)
	}
	// With ~9.8M combinations, 20 draws colliding more than a couple of times
	// would mean the entropy is not what it looks like.
	for handle, n := range seen {
		if n > 3 {
			t.Errorf("handle %q was generated %d times out of %d — far more collision than the keyspace implies", handle, n, runs)
		}
	}
}

// TestGenerateGuestHandle_Shape pins the format so it stays recognisable as a
// guest at a glance, and stays free of anything user-supplied.
func TestGenerateGuestHandle_Shape(t *testing.T) {
	shape := regexp.MustCompile(`^Guest-[A-Z][a-z]+[A-Z][a-z]+\d{4}$`)

	for i := 0; i < 50; i++ {
		handle, err := generateGuestHandle()
		if err != nil {
			t.Fatalf("generateGuestHandle: %v", err)
		}
		if !shape.MatchString(handle) {
			t.Fatalf("handle %q does not match Guest-<Adjective><Noun><4 digits>", handle)
		}
		if !strings.HasPrefix(handle, guestHandlePrefix) {
			t.Errorf("handle %q is not identifiable as a guest account", handle)
		}
	}
}

// TestGuestSignup_UpgradeViaLinkedInClearsTheFlag is the ADR-002 §3 promise
// that there is no separate upgrade RPC: an existing verification call, made
// against the guest's own row, is what turns it into a Level 1 account.
//
// Connecting LinkedIn is the path used here because it is the one a guest
// can actually take first — phone, personal email and personal details all
// sit behind requireLinkedIn (unchanged by ADR-002), so LinkedIn or an
// Apple/Google link are the only two doors open to a Level 0 account.
//
// The assertion that matters is that it is the SAME ROW: nothing is
// recreated, so a guest keeps their id, their session and anything attached
// to it.
func TestGuestSignup_UpgradeViaLinkedInClearsTheFlag(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	session, err := svc.GuestSignup(ctx, GuestSignupRequest{AgeConfirmedOver18: true})
	if err != nil {
		t.Fatalf("GuestSignup: %v", err)
	}
	guestID := session.UserID

	before := deps.users.byID[guestID]
	if !before.IsGuest || before.TrustLevel != 0 {
		t.Fatalf("precondition failed: %+v", before)
	}

	if err := svc.LinkIdentityToUser(ctx, guestID, FederatedProviderLinkedIn, "linkedin-sub-guest-upgrade"); err != nil {
		t.Fatalf("LinkIdentityToUser(linkedin): %v", err)
	}

	after, ok := deps.users.byID[guestID]
	if !ok {
		t.Fatal("the guest's row disappeared — the upgrade must happen in place")
	}
	if after.IsGuest {
		t.Error("IsGuest is still true after connecting LinkedIn — the guest is stranded at Level 0 with no way to notice why")
	}
	if after.TrustLevel != 1 {
		t.Errorf("stored TrustLevel = %d, want 1", after.TrustLevel)
	}
	if after.FullName != before.FullName {
		t.Error("the generated handle changed during the upgrade")
	}
}

// TestGuestSignup_UpgradeViaAppleClearsTheFlag covers the other door open to
// a guest, and the one that needed its own repository call: linking Apple or
// Google writes only user_identities, so it has no users UPDATE to clear the
// flag alongside.
//
// Before ADR-002 this path deliberately wrote nothing to auth.users at all
// ("linking Apple/Google never raises trust level"), which is exactly why it
// would have silently left a guest at Level 0.
func TestGuestSignup_UpgradeViaAppleClearsTheFlag(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	session, err := svc.GuestSignup(ctx, GuestSignupRequest{AgeConfirmedOver18: true})
	if err != nil {
		t.Fatalf("GuestSignup: %v", err)
	}
	guestID := session.UserID

	if err := svc.LinkIdentityToUser(ctx, guestID, FederatedProviderApple, "apple-sub-guest-upgrade"); err != nil {
		t.Fatalf("LinkIdentityToUser(apple): %v", err)
	}

	after := deps.users.byID[guestID]
	if after.IsGuest {
		t.Error("IsGuest is still true after linking Apple — Apple is one of the four real signup paths (ADR-033 §2)")
	}
	if after.TrustLevel != 1 {
		t.Errorf("stored TrustLevel = %d, want 1", after.TrustLevel)
	}
}

// TestLinkIdentity_NonGuestIsNotRewritten pins the skip: linking Apple to an
// account that was never a guest genuinely changes nothing, and writing
// anyway would publish a pointless user-profile-updated event to the meetup
// module's display cache on every link.
func TestLinkIdentity_NonGuestIsNotRewritten(t *testing.T) {
	svc, deps := newFederatedTestService(t)
	ctx := context.Background()

	user, err := deps.users.Create(ctx, fakeNewUser("linkedin-sub-real"))
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}
	before := deps.users.byID[user.ID]

	if err := svc.LinkIdentityToUser(ctx, user.ID, FederatedProviderApple, "apple-sub-real"); err != nil {
		t.Fatalf("LinkIdentityToUser: %v", err)
	}

	after := deps.users.byID[user.ID]
	if after.TrustLevel != before.TrustLevel || after.IsGuest != before.IsGuest {
		t.Errorf("a non-guest's row was rewritten by an Apple link: before=%+v after=%+v", before, after)
	}
}
