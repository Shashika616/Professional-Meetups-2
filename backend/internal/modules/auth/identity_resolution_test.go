package auth

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// TestResolveOrCreateIdentity is the required test matrix from
// backend/level0-federated-identity-PLAN.md Step 3: resolve-existing vs.
// create-new, for both the Apple/Google (user_identities-backed) branch and
// the LinkedIn (users.linkedin_sub-backed) branch — ResolveOrCreateIdentity
// is the one function every federated login calls regardless of provider,
// so both branches need to be proven, not just one.
func TestResolveOrCreateIdentity(t *testing.T) {
	t.Run("apple: creates a new Level 0 user when subject is unknown", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		user, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada Lovelace", "", true)
		if err != nil {
			t.Fatalf("ResolveOrCreateIdentity() error: %v", err)
		}
		if !isNewUser {
			t.Error("isNewUser = false, want true")
		}
		// CHANGED (ADR-002 §2): was 0, "Apple alone never grants trust".
		// Apple/Google/email/LinkedIn now all grant Level 1 equally and
		// immediately — is_guest is the only thing that yields 0.
		if user.TrustLevel != 1 {
			t.Errorf("TrustLevel = %d, want 1 (any real signup path grants Level 1 immediately, ADR-002 §2)", user.TrustLevel)
		}
		if user.IsGuest {
			t.Error("IsGuest = true for an Apple signup — only GuestSignup creates guests")
		}
		if user.FullName != "Ada Lovelace" {
			t.Errorf("FullName = %q, want %q", user.FullName, "Ada Lovelace")
		}
	})

	t.Run("apple: resolves the existing user on a second call with the same subject", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		first, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada Lovelace", "", true)
		if err != nil || !isNewUser {
			t.Fatalf("seed call: user=%+v isNewUser=%v err=%v", first, isNewUser, err)
		}

		second, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada Lovelace", "", true)
		if err != nil {
			t.Fatalf("ResolveOrCreateIdentity() error: %v", err)
		}
		if isNewUser {
			t.Error("isNewUser = true on the second resolve, want false")
		}
		if second.ID != first.ID {
			t.Errorf("second resolve returned user %q, want the same user %q", second.ID, first.ID)
		}
	})

	t.Run("google: creates and resolves independently of apple (different provider, same subject namespace)", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		user, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderGoogle, "shared-sub", "", "Bob", "", true)
		if err != nil || !isNewUser {
			t.Fatalf("google create: user=%+v isNewUser=%v err=%v", user, isNewUser, err)
		}

		// The SAME subject string under a DIFFERENT provider must not
		// resolve to the google user — (provider, subject) is the real key.
		other, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderApple, "shared-sub", "", "Someone Else", "", true)
		if err != nil || !isNewUser {
			t.Fatalf("apple create with same subject string: user=%+v isNewUser=%v err=%v", other, isNewUser, err)
		}
		if other.ID == user.ID {
			t.Error("apple and google resolves with the same subject string returned the same user — provider must be part of the key")
		}
	})

	t.Run("apple: rejects account creation when age is not confirmed, without persisting anything", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)

		_, _, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderApple, "apple-sub-1", "", "Ada", "", false)
		if err == nil {
			t.Fatal("ResolveOrCreateIdentity() returned nil error for ageConfirmedOver18=false, want error")
		}
		if !isInvalidInput(err) {
			t.Errorf("error = %v, want apperror.ErrInvalidInput", err)
		}
		if len(deps.users.createCalls) != 0 {
			t.Errorf("Create called %d times, want 0", len(deps.users.createCalls))
		}
	})

	t.Run("linkedin: creates a new Level 1 user when subject is unknown", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		user, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderLinkedIn, "li-sub-1", "", "Ada Lovelace", "https://example.com/p.jpg", true)
		if err != nil {
			t.Fatalf("ResolveOrCreateIdentity() error: %v", err)
		}
		if !isNewUser {
			t.Error("isNewUser = false, want true")
		}
		if user.TrustLevel != 1 {
			t.Errorf("TrustLevel = %d, want 1 (LinkedIn direct signup grants Level 1 immediately)", user.TrustLevel)
		}
		if user.ProfilePhotoURL != "https://example.com/p.jpg" {
			t.Errorf("ProfilePhotoURL = %q, want the photo passed in (no regression vs. ADR-011's existing behavior)", user.ProfilePhotoURL)
		}
	})

	t.Run("linkedin: resolves the existing user on a second call with the same subject", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		first, _, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderLinkedIn, "li-sub-1", "", "Ada", "", true)
		if err != nil {
			t.Fatalf("seed call error: %v", err)
		}

		second, isNewUser, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderLinkedIn, "li-sub-1", "", "Ada", "", true)
		if err != nil {
			t.Fatalf("ResolveOrCreateIdentity() error: %v", err)
		}
		if isNewUser {
			t.Error("isNewUser = true on the second resolve, want false")
		}
		if second.ID != first.ID {
			t.Errorf("second resolve returned user %q, want the same user %q", second.ID, first.ID)
		}
	})

	t.Run("linkedin: rejects account creation when age is not confirmed, without persisting anything", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)

		_, _, err := svc.ResolveOrCreateIdentity(context.Background(), FederatedProviderLinkedIn, "li-sub-1", "", "Ada", "", false)
		if err == nil {
			t.Fatal("ResolveOrCreateIdentity() returned nil error for ageConfirmedOver18=false, want error")
		}
		if !isInvalidInput(err) {
			t.Errorf("error = %v, want apperror.ErrInvalidInput", err)
		}
		if len(deps.users.createCalls) != 0 {
			t.Errorf("Create called %d times, want 0", len(deps.users.createCalls))
		}
	})
}

// TestLinkIdentityToUser_TableDriven is the required link-success vs.
// link-reject-already-claimed matrix (Step 3) — "the one real abuse edge in
// this whole design" per ADR-014's Identity Resolution section, covering
// both the LinkedIn (users.linkedin_sub) and Apple/Google (user_identities)
// branches.
func TestLinkIdentityToUser_TableDriven(t *testing.T) {
	t.Run("linkedin: links successfully and raises trust level", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

		if err := svc.LinkIdentityToUser(context.Background(), user.ID, FederatedProviderLinkedIn, "li-sub-99"); err != nil {
			t.Fatalf("LinkIdentityToUser() error: %v", err)
		}

		linked := deps.users.byID[user.ID]
		if linked.LinkedInSub != "li-sub-99" {
			t.Errorf("LinkedInSub = %q, want %q", linked.LinkedInSub, "li-sub-99")
		}
		if linked.TrustLevel != 1 {
			t.Errorf("TrustLevel = %d, want 1", linked.TrustLevel)
		}
	})

	t.Run("linkedin: hard-rejects when subject already belongs to a different user, no merge", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		_, _ = deps.users.Create(context.Background(), repository.NewUser{LinkedInSub: "li-sub-taken", FullName: "Original Owner", TrustLevel: 1, AgeConfirmedOver18: true})
		victim, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Victim", TrustLevel: 0, AgeConfirmedOver18: true})

		err := svc.LinkIdentityToUser(context.Background(), victim.ID, FederatedProviderLinkedIn, "li-sub-taken")
		if err == nil {
			t.Fatal("LinkIdentityToUser() returned nil error for an already-claimed subject, want error")
		}
		if !isConflict(err) {
			t.Errorf("error = %v, want apperror.ErrConflict", err)
		}
		if unchanged := deps.users.byID[victim.ID]; unchanged.LinkedInSub != "" {
			t.Errorf("victim's LinkedInSub = %q, want unchanged (empty) — must not silently merge", unchanged.LinkedInSub)
		}
	})

	t.Run("apple: links successfully and does not raise trust level", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		user, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Ada", TrustLevel: 0, AgeConfirmedOver18: true})

		if err := svc.LinkIdentityToUser(context.Background(), user.ID, FederatedProviderApple, "apple-sub-42"); err != nil {
			t.Fatalf("LinkIdentityToUser() error: %v", err)
		}

		row, err := deps.identities.GetByProviderSubject(context.Background(), repository.IdentityProviderApple, "apple-sub-42")
		if err != nil {
			t.Fatalf("expected a user_identities row, got error: %v", err)
		}
		if row.UserID != user.ID {
			t.Errorf("identity row UserID = %q, want %q", row.UserID, user.ID)
		}
		if unchanged := deps.users.byID[user.ID]; unchanged.TrustLevel != 0 {
			t.Errorf("TrustLevel = %d, want unchanged 0 — linking Apple never raises trust level", unchanged.TrustLevel)
		}
	})

	t.Run("apple: hard-rejects when subject already belongs to a different user, no merge", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		owner, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Original Owner", TrustLevel: 0, AgeConfirmedOver18: true})
		if _, err := deps.identities.Insert(context.Background(), owner.ID, repository.IdentityProviderApple, "apple-sub-taken", "owner@example.com"); err != nil {
			t.Fatalf("seed existing identity: %v", err)
		}
		victim, _ := deps.users.Create(context.Background(), repository.NewUser{FullName: "Victim", TrustLevel: 0, AgeConfirmedOver18: true})

		err := svc.LinkIdentityToUser(context.Background(), victim.ID, FederatedProviderApple, "apple-sub-taken")
		if err == nil {
			t.Fatal("LinkIdentityToUser() returned nil error for an already-claimed apple subject, want error")
		}
		if !isConflict(err) {
			t.Errorf("error = %v, want apperror.ErrConflict", err)
		}
		rows, _ := deps.identities.ListForUser(context.Background(), victim.ID)
		if len(rows) != 0 {
			t.Errorf("victim gained %d identity rows, want 0 — must not silently merge", len(rows))
		}
	})
}

// TestSignUpOrRecoverWithEmail_TableDriven is the required
// email-signup-new vs. email-signup-recovers-existing matrix (Step 3) — the
// recovery branch is the one place cross-account resolution happens
// automatically, so getting the "only a VERIFIED personal_email counts"
// condition right matters (Step 7's self-review checklist calls this out
// explicitly as an account-takeover-risk area if gotten wrong).
func TestSignUpOrRecoverWithEmail_TableDriven(t *testing.T) {
	t.Run("creates a new Level 0 user when the email matches nobody", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)

		user, isNewUser, err := svc.SignUpOrRecoverWithEmail(context.Background(), "new@example.com", true)
		if err != nil {
			t.Fatalf("SignUpOrRecoverWithEmail() error: %v", err)
		}
		if !isNewUser {
			t.Error("isNewUser = false, want true")
		}
		// CHANGED (ADR-002 §2): was 0, "email alone never grants Level 1".
		if user.TrustLevel != 1 {
			t.Errorf("TrustLevel = %d, want 1 (email signup grants Level 1 immediately, ADR-002 §2)", user.TrustLevel)
		}
		if user.IsGuest {
			t.Error("IsGuest = true for an email signup — only GuestSignup creates guests")
		}
		if user.PersonalEmail != "new@example.com" {
			t.Errorf("PersonalEmail = %q, want %q", user.PersonalEmail, "new@example.com")
		}
	})

	t.Run("recovers an existing account with a VERIFIED matching personal_email, does not create a duplicate", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		existing, err := deps.users.Create(context.Background(), repository.NewUser{LinkedInSub: "li-sub-1", FullName: "Ada", TrustLevel: 1, AgeConfirmedOver18: true})
		if err != nil {
			t.Fatalf("seed existing user: %v", err)
		}
		if _, err := deps.users.UpdatePersonalEmail(context.Background(), existing.ID, "ada@example.com", func(repository.User) int { return 1 }); err != nil {
			t.Fatalf("seed verified personal_email: %v", err)
		}
		createCallsBeforeRecovery := len(deps.users.createCalls)

		user, isNewUser, err := svc.SignUpOrRecoverWithEmail(context.Background(), "ada@example.com", true)
		if err != nil {
			t.Fatalf("SignUpOrRecoverWithEmail() error: %v", err)
		}
		if isNewUser {
			t.Error("isNewUser = true on a recovery, want false")
		}
		if user.ID != existing.ID {
			t.Errorf("recovered user ID = %q, want the existing user %q", user.ID, existing.ID)
		}
		if len(deps.users.createCalls) != createCallsBeforeRecovery {
			t.Errorf("Create called %d more time(s) during recovery, want 0 — must not create a duplicate account", len(deps.users.createCalls)-createCallsBeforeRecovery)
		}
	})

	t.Run("recovery ignores ageConfirmedOver18 — an existing account is never blocked by a stale/false flag", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		existing, _ := deps.users.Create(context.Background(), repository.NewUser{LinkedInSub: "li-sub-1", FullName: "Ada", TrustLevel: 1, AgeConfirmedOver18: true})
		_, _ = deps.users.UpdatePersonalEmail(context.Background(), existing.ID, "ada@example.com", func(repository.User) int { return 1 })

		user, isNewUser, err := svc.SignUpOrRecoverWithEmail(context.Background(), "ada@example.com", false)
		if err != nil {
			t.Fatalf("SignUpOrRecoverWithEmail() error: %v", err)
		}
		if isNewUser {
			t.Error("isNewUser = true, want false")
		}
		if user.ID != existing.ID {
			t.Errorf("recovered user ID = %q, want %q", user.ID, existing.ID)
		}
	})

	t.Run("rejects new-account creation when age is not confirmed, without persisting anything", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)

		_, _, err := svc.SignUpOrRecoverWithEmail(context.Background(), "new@example.com", false)
		if err == nil {
			t.Fatal("SignUpOrRecoverWithEmail() returned nil error for ageConfirmedOver18=false, want error")
		}
		if !isInvalidInput(err) {
			t.Errorf("error = %v, want apperror.ErrInvalidInput", err)
		}
		if len(deps.users.createCalls) != 0 {
			t.Errorf("Create called %d times, want 0", len(deps.users.createCalls))
		}
	})
}

// isInvalidInput/isConflict check the plain (non-gRPC-wrapped) errors
// identity_resolution.go's functions return directly — apperror.
// ToGRPCStatus wrapping happens one layer up, in service.go's RPC handlers,
// not inside these directly-tested functions.
func isInvalidInput(err error) bool {
	return errors.Is(err, apperror.ErrInvalidInput)
}

func isConflict(err error) bool {
	return errors.Is(err, apperror.ErrConflict)
}

// TestLinkIdentityToUser_LinkedIn_NeverOverwritesExistingFullName is the
// guarantee Plan 22 exists to protect, tested at the lowest level that can
// break it. Connecting LinkedIn to an account that already has a name must
// leave that name alone, no matter what LinkedIn calls the same person.
//
// The name is the user's: they either typed it into profile editing
// (ADR-023 §5) or it arrived with their original signup, including from
// Apple's one-time out-of-band hint. Renaming them as a side effect of
// connecting an account is not a thing they asked for, and they would have
// no way to work out why it happened.
//
// This is a regression test, not a bug fix — the LinkedIn branch has never
// written FullName. It fails the moment somebody "harmonizes" this branch
// with resolveOrCreateLinkedIn, which takes LinkedIn's name because it is
// creating the account and has nothing to overwrite. The supported way to
// act on a mismatch is LinkIdentity's SuggestedNameUpdate, which asks
// (TestLinkIdentity_LinkedInNameSuggestion).
func TestLinkIdentityToUser_LinkedIn_NeverOverwritesExistingFullName(t *testing.T) {
	// The whole matrix of "the account already has a name" cases: hand-typed,
	// provider-supplied, and one that differs only in case/spacing (a
	// tempting thing to "normalize" away).
	for _, existingName := range []string{"Ada Lovelace", "A. Lovelace", "ada lovelace"} {
		t.Run(existingName, func(t *testing.T) {
			svc, deps := newFederatedTestService(t)
			user, err := deps.users.Create(context.Background(), repository.NewUser{
				FullName: existingName, TrustLevel: 0, AgeConfirmedOver18: true,
			})
			if err != nil {
				t.Fatalf("seed user: %v", err)
			}

			// li-sub-77 is whatever LinkedIn just authorized; the userinfo
			// name ("Ada Lovelace", per newTestLinkedInServer) is deliberately
			// NOT passed in — LinkIdentityToUser takes no name parameter at
			// all, which is itself the guarantee. If a future change adds one,
			// this test's assertion is what catches it writing.
			if err := svc.LinkIdentityToUser(context.Background(), user.ID, FederatedProviderLinkedIn, "li-sub-77"); err != nil {
				t.Fatalf("LinkIdentityToUser() error: %v", err)
			}

			linked := deps.users.byID[user.ID]
			if linked.FullName != existingName {
				t.Errorf("FullName = %q after linking LinkedIn, want unchanged %q — linking must never rename the user", linked.FullName, existingName)
			}
			// The link itself still has to have happened, or the assertion
			// above would pass for the wrong reason.
			if linked.LinkedInSub != "li-sub-77" {
				t.Errorf("LinkedInSub = %q, want %q — the link itself must still succeed", linked.LinkedInSub, "li-sub-77")
			}
			if linked.TrustLevel != 1 {
				t.Errorf("TrustLevel = %d, want 1 — linking still raises trust", linked.TrustLevel)
			}
		})
	}
}

// TestLinkIdentity_LinkedIn_SuggestionNeverTouchesTheStoredName is the same
// guarantee one level up, through the full LinkIdentity path that DOES know
// LinkedIn's name and DOES return a suggestion. A suggestion is a field on a
// response; it must never be a write.
func TestLinkIdentity_LinkedIn_SuggestionNeverTouchesTheStoredName(t *testing.T) {
	svc, deps := newFederatedTestService(t, func(d *testServiceDeps) {
		li, closeLI := newTestLinkedInServerNamed(t, "Grace Hopper")
		t.Cleanup(closeLI)
		d.linkedin = li
	})
	user, err := deps.users.Create(context.Background(), repository.NewUser{
		FullName: "Ada Lovelace", TrustLevel: 0, AgeConfirmedOver18: true,
	})
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	resp, err := svc.LinkIdentity(context.Background(), LinkIdentityRequest{
		UserID:            user.ID,
		Provider:          FederatedProviderLinkedIn,
		AuthorizationCode: "auth-code",
		RedirectURI:       "app://callback",
	})
	if err != nil {
		t.Fatalf("LinkIdentity() error: %v", err)
	}

	if resp.SuggestedNameUpdate != "Grace Hopper" {
		t.Errorf("SuggestedNameUpdate = %q, want %q", resp.SuggestedNameUpdate, "Grace Hopper")
	}
	if stored := deps.users.byID[user.ID].FullName; stored != "Ada Lovelace" {
		t.Errorf("stored FullName = %q, want unchanged %q — the suggestion must not be applied server-side", stored, "Ada Lovelace")
	}
	// The session the caller gets back still reports the account's real
	// name, not the suggested one: a client that ignores the new field shows
	// exactly what it showed before.
	if resp.FullName != "Ada Lovelace" {
		t.Errorf("session FullName = %q, want the account's own %q", resp.FullName, "Ada Lovelace")
	}
}
