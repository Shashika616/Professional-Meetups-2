package auth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// seedGoogleAccount creates an account the ordinary way, through Google, and
// returns it. Using the real signup path rather than writing a row directly
// is what makes the collision tests below meaningful: the address under test
// got into personal_email the same way a real user's would.
func seedGoogleAccount(t *testing.T, svc *service, email string) repository.User {
	t.Helper()
	user, isNew, err := svc.ResolveOrCreateIdentity(
		context.Background(), FederatedProviderGoogle, "google-sub-seed", email, "Ada Lovelace", "", true,
	)
	if err != nil || !isNew {
		t.Fatalf("seeding the first account: isNew=%v err=%v", isNew, err)
	}
	if user.PersonalEmail != email {
		t.Fatalf("seeded PersonalEmail = %q, want %q — the provider address must land on the account", user.PersonalEmail, email)
	}
	return user
}

func claimRequired(t *testing.T, err error) *AccountClaimRequiredError {
	t.Helper()
	var claim *AccountClaimRequiredError
	if !errors.As(err, &claim) {
		t.Fatalf("error = %v, want an *AccountClaimRequiredError", err)
	}
	if !errors.Is(err, apperror.ErrConflict) {
		t.Error("the claim error must still classify as ErrConflict for anything that has not been taught about it")
	}
	return claim
}

func TestFederatedSignup_WhenTheAddressIsFree(t *testing.T) {
	svc, _ := newFederatedTestService(t)

	user, isNew, err := svc.ResolveOrCreateIdentity(
		context.Background(), FederatedProviderApple, "apple-sub-1", "Ada@Example.COM", "Ada", "", true,
	)
	if err != nil {
		t.Fatalf("an unregistered address must onboard normally, got: %v", err)
	}
	if !isNew {
		t.Error("isNewUser = false, want true")
	}
	// Normalised on the way in, so the next provider to present
	// "ada@example.com" matches this row rather than making a second one.
	if user.PersonalEmail != "ada@example.com" {
		t.Errorf("PersonalEmail = %q, want it lowercased to %q", user.PersonalEmail, "ada@example.com")
	}
}

func TestFederatedSignup_WhenTheAddressIsAlreadyTaken(t *testing.T) {
	t.Run("pauses the signup, mails a code, and creates no second account", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		first := seedGoogleAccount(t, svc, "ada@example.com")
		before := len(deps.users.byID)

		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)

		if claim.Ticket == "" {
			t.Error("no ticket: the popup has nothing to send back")
		}
		if claim.Email != "ada@example.com" {
			t.Errorf("Email = %q, want the address the code went to", claim.Email)
		}
		if claim.ResendAfterSeconds <= 0 {
			t.Error("ResendAfterSeconds = 0: the popup cannot disable its own resend control")
		}
		if got := deps.emailer.lastCode(); got == "" {
			t.Error("no code was mailed, so the popup would open with nothing to type")
		}
		if len(deps.users.byID) != before {
			t.Errorf("user count %d -> %d: the conflicting signup must not create an account", before, len(deps.users.byID))
		}
		// And nothing about the existing account leaks through the error.
		if msg := err.Error(); strings.Contains(msg, first.ID) || strings.Contains(msg, "Ada Lovelace") {
			t.Errorf("the error names the existing account: %q", msg)
		}
	})

	t.Run("a different capitalisation of the same mailbox still collides", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")

		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ADA@Example.com", "Ada", "", true,
		)
		claimRequired(t, err)
	})

	t.Run("an address-less provider is unaffected", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")

		// Apple's Hide My Email, or a provider that withheld the claim:
		// identity.Verify hands over "" and signup must proceed normally.
		_, isNew, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "", "Ada", "", true,
		)
		if err != nil || !isNew {
			t.Fatalf("no address means nothing to collide with: isNew=%v err=%v", isNew, err)
		}
	})
}

func TestCompleteAccountClaim(t *testing.T) {
	t.Run("the right code hands over the existing account and attaches the new provider", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		existing := seedGoogleAccount(t, svc, "ada@example.com")

		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)

		session, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{
			Ticket: claim.Ticket,
			Code:   deps.emailer.lastCode(),
		})
		if err != nil {
			t.Fatalf("CompleteAccountClaim() error: %v", err)
		}
		if session.UserID != existing.ID {
			t.Errorf("session is for %q, want the EXISTING account %q", session.UserID, existing.ID)
		}

		// Attached, so the next Apple sign-in resolves straight through
		// instead of asking for a code forever.
		resolved, isNew, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		if err != nil {
			t.Fatalf("second Apple sign-in error: %v", err)
		}
		if isNew {
			t.Error("isNewUser = true: the identity was not attached by the claim")
		}
		if resolved.ID != existing.ID {
			t.Errorf("resolved %q, want %q", resolved.ID, existing.ID)
		}
	})

	t.Run("the code is single use", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")
		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)
		code := deps.emailer.lastCode()

		if _, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{Ticket: claim.Ticket, Code: code}); err != nil {
			t.Fatalf("first claim: %v", err)
		}
		// Replaying the whole pair must fail — this is what makes a stolen
		// ticket worthless rather than merely inconvenient.
		if _, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{Ticket: claim.Ticket, Code: code}); err == nil {
			t.Error("the same ticket and code were spent twice")
		}
	})

	t.Run("a wrong code issues nothing", func(t *testing.T) {
		svc, _ := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")
		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)

		session, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{
			Ticket: claim.Ticket,
			Code:   "000000",
		})
		if err == nil {
			t.Fatal("a wrong code produced a session")
		}
		if session.UserID != "" || session.RefreshToken != "" {
			t.Errorf("a failed claim returned session material: %+v", session)
		}
	})

	t.Run("a tampered ticket is refused, so a real code cannot be aimed at another account", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")
		seedSecond, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderGoogle, "google-sub-victim", "grace@example.com", "Grace", "", true,
		)
		if err != nil {
			t.Fatalf("seeding the victim account: %v", err)
		}

		_, _, err = svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)
		code := deps.emailer.lastCode()

		// Re-point the payload at the victim's address, keeping the
		// signature that was issued for ada's. This is the attack the
		// signature exists for.
		forged := forgeTicketPayloadEmail(t, claim.Ticket, "grace@example.com")
		if _, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{Ticket: forged, Code: code}); err == nil {
			t.Fatalf("a re-pointed ticket was accepted and would have handed over account %q", seedSecond.ID)
		}

		// Flipping a byte of the signature is refused too.
		if _, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{
			Ticket: flipLastHexDigit(claim.Ticket), Code: code,
		}); err == nil {
			t.Error("a ticket with a corrupted signature was accepted")
		}

		// Garbage shapes.
		for _, bad := range []string{"", ".", "nodot", "body.notahexsignature"} {
			if _, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{Ticket: bad, Code: code}); err == nil {
				t.Errorf("ticket %q was accepted", bad)
			}
		}
	})
}

// THE REQUIREMENT THIS TEST EXISTS FOR: a claim must never cost somebody
// the LinkedIn connection their trust level rests on.
func TestCompleteAccountClaim_NeverOverwritesAnExistingLinkedInConnection(t *testing.T) {
	svc, deps := newFederatedTestService(t)

	// An account with LinkedIn already connected, holding the address.
	existing, _, err := svc.ResolveOrCreateIdentity(
		context.Background(), FederatedProviderLinkedIn, "linkedin-sub-original", "ada@example.com", "Ada", "", true,
	)
	if err != nil {
		t.Fatalf("seeding the LinkedIn account: %v", err)
	}
	if existing.LinkedInSub != "linkedin-sub-original" {
		t.Fatalf("LinkedInSub = %q, want the seeded sub", existing.LinkedInSub)
	}

	// A DIFFERENT LinkedIn member presenting the same address.
	_, _, err = svc.ResolveOrCreateIdentity(
		context.Background(), FederatedProviderLinkedIn, "linkedin-sub-other", "ada@example.com", "Ada", "", true,
	)
	claim := claimRequired(t, err)

	session, err := svc.CompleteAccountClaim(context.Background(), CompleteAccountClaimRequest{
		Ticket: claim.Ticket,
		Code:   deps.emailer.lastCode(),
	})
	if err != nil {
		t.Fatalf("CompleteAccountClaim() error: %v", err)
	}
	if session.UserID != existing.ID {
		t.Errorf("session is for %q, want %q", session.UserID, existing.ID)
	}

	after, err := svc.users.GetByID(context.Background(), existing.ID)
	if err != nil {
		t.Fatalf("re-reading the account: %v", err)
	}
	if after.LinkedInSub != "linkedin-sub-original" {
		t.Errorf("LinkedInSub = %q, want it untouched at %q — the claim disconnected a verified LinkedIn account",
			after.LinkedInSub, "linkedin-sub-original")
	}
	if after.TrustLevel < existing.TrustLevel {
		t.Errorf("TrustLevel fell from %d to %d across a claim", existing.TrustLevel, after.TrustLevel)
	}
}

func TestResendAccountClaimCode(t *testing.T) {
	t.Run("refuses without a valid ticket, so it is not an open mail-anyone endpoint", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")

		if _, err := svc.ResendAccountClaimCode(context.Background(), "not-a-ticket"); err == nil {
			t.Fatal("an unsigned ticket was accepted")
		}
		if deps.emailer.lastCode() != "" {
			t.Error("mail was sent for an invalid ticket")
		}
	})

	t.Run("honours the shared resend cooldown", func(t *testing.T) {
		svc, deps := newFederatedTestService(t)
		seedGoogleAccount(t, svc, "ada@example.com")
		_, _, err := svc.ResolveOrCreateIdentity(
			context.Background(), FederatedProviderApple, "apple-sub-1", "ada@example.com", "Ada", "", true,
		)
		claim := claimRequired(t, err)
		_ = deps

		if _, err := svc.ResendAccountClaimCode(context.Background(), claim.Ticket); !errors.Is(err, apperror.ErrRateLimited) {
			t.Errorf("error = %v, want ErrRateLimited — a code was sent seconds ago", err)
		}
	})
}

// forgeTicketPayloadEmail rewrites the payload half of a ticket to name a
// different address, leaving the signature alone — the forgery a signed
// ticket has to withstand.
func forgeTicketPayloadEmail(t *testing.T, ticket, email string) string {
	t.Helper()
	body, sig, found := strings.Cut(ticket, ".")
	if !found {
		t.Fatalf("ticket %q has no signature half", ticket)
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		t.Fatalf("decoding the ticket payload: %v", err)
	}
	var payload claimTicketPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("parsing the ticket payload: %v", err)
	}
	payload.Email = email
	reencoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("re-encoding the ticket payload: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(reencoded) + "." + sig
}

func flipLastHexDigit(ticket string) string {
	if ticket == "" {
		return ticket
	}
	last := ticket[len(ticket)-1]
	replacement := byte('a')
	if last == 'a' {
		replacement = 'b'
	}
	return ticket[:len(ticket)-1] + string(replacement)
}
