package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// # CLAIMING AN ACCOUNT THAT ALREADY HOLDS YOUR EMAIL
//
// 0017 made lower(personal_email) unique, which turned a quiet duplicate
// into a hard stop: someone who signed up with Google in March and comes
// back through Apple in October presents the same verified address, and the
// INSERT that used to make them a second, empty account now cannot.
//
// A hard stop is not an answer, so this is the answer. The signup is paused,
// a code goes to the address, and spending that code attaches the new
// provider to the account that was already there. They keep their meetups,
// their ratings, their trust level and their LinkedIn connection, and they
// never see a second account they did not know they had.
//
// WHAT THE CALLER IS TOLD, AND WHAT IT IS NOT TOLD. The response says an
// account exists for this address and nothing else — no name, no photo, no
// which-provider-it-was, no when. That existence is not a leak here: the
// provider already attested that this caller controls this mailbox, so they
// are being told something about their own address. Everything beyond that
// would be a statement about somebody who might not be them, and they have
// not proved anything yet.

// AccountClaimRequiredError is returned by the federated signup paths when
// the verified address belongs to an existing account. It carries what the
// claim popup needs and nothing more.
//
// An error rather than an extra return value because every caller of
// ResolveOrCreateIdentity already handles errors and none of them can
// sensibly continue: there is no user to issue a session for. errors.As is
// how the RPC layer picks it out of the ordinary failures.
type AccountClaimRequiredError struct {
	// Ticket is the signed proof of which identity is waiting to be
	// attached. Opaque to the client, which only hands it back.
	Ticket string
	// Email is the address the code was sent to — the caller's own, from
	// their own provider token, so echoing it reveals nothing they did not
	// supply. The popup needs it to say where to look.
	Email string
	// ResendAfterSeconds is the cooldown before another code may be asked
	// for, so the popup can disable its own resend control rather than
	// discovering the limit by being refused.
	ResendAfterSeconds int32
}

func (e *AccountClaimRequiredError) Error() string {
	return "an account already exists for this email address"
}

// Unwrap makes errors.Is(err, apperror.ErrConflict) true, so anything that
// has not been taught about this error specifically still classifies it
// correctly instead of reporting an internal failure.
func (e *AccountClaimRequiredError) Unwrap() error { return apperror.ErrConflict }

// claimTicketDomain separates this signature from every other use of the
// same key. The key already hashes work-email addresses (workemail.go), and
// one key signing two different kinds of message with no prefix is how a
// value minted for one purpose becomes valid for the other. The version
// suffix is what lets the payload shape change later without old tickets
// silently validating against new parsing rules.
const claimTicketDomain = "account-claim-ticket.v1|"

// claimTicketPayload is what the ticket asserts. Short JSON keys because
// this travels in an HTTP body and a header-sized value is easier to live
// with; nothing here is secret, so the encoding is base64url, not
// encryption.
type claimTicketPayload struct {
	Email     string `json:"e"`
	Provider  string `json:"p"`
	Subject   string `json:"s"`
	ExpiresAt int64  `json:"x"`
}

// mintClaimTicket signs one claim. The expiry deliberately matches the OTP's
// (otpExpiry) so the ticket and the code it is spent with die together — a
// ticket outliving its code would only produce a confusing second error
// after the user had already typed a valid-looking number.
func (s *service) mintClaimTicket(email string, provider FederatedProvider, subject string) (string, error) {
	payload, err := json.Marshal(claimTicketPayload{
		Email:     email,
		Provider:  string(provider),
		Subject:   subject,
		ExpiresAt: time.Now().Add(otpExpiry).Unix(),
	})
	if err != nil {
		return "", fmt.Errorf("%w: marshal claim ticket: %w", apperror.ErrInternal, err)
	}
	if len(s.workEmailHMACKey) == 0 {
		// Fail rather than sign with an empty key, which would make every
		// ticket forgeable by anyone who read this file. main.go requires
		// the key at startup, so this is a guard against a future wiring
		// change, not an expected state.
		return "", fmt.Errorf("%w: claim ticket signing key is not configured", apperror.ErrInternal)
	}
	body := base64.RawURLEncoding.EncodeToString(payload)
	return body + "." + hex.EncodeToString(signClaimTicket(s.workEmailHMACKey, body)), nil
}

func signClaimTicket(key []byte, body string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(claimTicketDomain))
	mac.Write([]byte(body))
	return mac.Sum(nil)
}

// errInvalidClaimTicket is one message for every way a ticket can be
// unusable — wrong shape, bad signature, expired, unparseable. They are all
// "start again", and distinguishing them in the response would tell someone
// probing the endpoint which part of their forgery was closest.
var errInvalidClaimTicket = fmt.Errorf("this request has expired, please sign in again: %w", apperror.ErrInvalidInput)

// parseClaimTicket verifies the signature and the expiry, in that order, and
// returns what the ticket asserts.
func (s *service) parseClaimTicket(ticket string) (claimTicketPayload, error) {
	body, sig, found := strings.Cut(ticket, ".")
	if !found || body == "" || sig == "" {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	presented, err := hex.DecodeString(sig)
	if err != nil {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	if len(s.workEmailHMACKey) == 0 {
		return claimTicketPayload{}, fmt.Errorf("%w: claim ticket signing key is not configured", apperror.ErrInternal)
	}
	// Constant time: the comparison is against a value an attacker chooses
	// and can retry, which is the exact shape a byte-by-byte compare leaks a
	// signature through.
	if !hmac.Equal(presented, signClaimTicket(s.workEmailHMACKey, body)) {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	var payload claimTicketPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	if payload.Email == "" || payload.Subject == "" || payload.Provider == "" {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	if time.Now().After(time.Unix(payload.ExpiresAt, 0)) {
		return claimTicketPayload{}, errInvalidClaimTicket
	}
	return payload, nil
}

// beginAccountClaim is called the moment a federated signup finds the
// address already taken: it mints the ticket and sends the code, so the
// popup the user is about to see already has one waiting rather than making
// them ask for it.
//
// Sending mail from an unauthenticated path is safe here in a way it is not
// in general: the address is not caller-supplied, it came out of a
// provider-signed token that this service verified, with email_verified set.
// The only mailbox anyone can aim this at is one they have already proved
// they own.
func (s *service) beginAccountClaim(
	ctx context.Context, normalizedEmail string, provider FederatedProvider, subject string,
) error {
	ticket, err := s.mintClaimTicket(normalizedEmail, provider, subject)
	if err != nil {
		return err
	}
	result, err := s.sendAccountClaimCode(ctx, normalizedEmail)
	if err != nil {
		return err
	}
	return &AccountClaimRequiredError{
		Ticket:             ticket,
		Email:              normalizedEmail,
		ResendAfterSeconds: result.ResendAfterSeconds,
	}
}

// sendAccountClaimCode mails one code for the claim purpose, reusing the
// same target-keyed machinery email signup and login already use — the
// cooldown, the expiry, the attempt ceiling and the test-address bypass all
// come along with it rather than being re-decided here.
func (s *service) sendAccountClaimCode(ctx context.Context, normalizedEmail string) (StartVerificationResult, error) {
	return s.startTargetKeyedVerification(ctx, repository.VerificationPurposeAccountClaim, normalizedEmail)
}

// ResendAccountClaimCode sends another code for a claim already in progress.
// The ticket is what authorises it: without one, this would be an open
// mail-anyone endpoint.
//
// A refused resend (the one-minute cooldown) comes back as ErrRateLimited
// from the shared sender, which the popup shows as-is.
func (s *service) ResendAccountClaimCode(ctx context.Context, ticket string) (StartVerificationResult, error) {
	payload, err := s.parseClaimTicket(ticket)
	if err != nil {
		return StartVerificationResult{}, err
	}
	return s.sendAccountClaimCode(ctx, payload.Email)
}

// CompleteAccountClaim spends the code and hands over the existing account.
//
// Order matters and is deliberate. The code is checked FIRST, before the
// account is even looked up, so that every wrong guess costs the same
// whether or not the ticket points at a real account — the same
// enumeration-safety discipline CompleteEmailLogin follows.
func (s *service) CompleteAccountClaim(ctx context.Context, req CompleteAccountClaimRequest) (SessionResult, error) {
	payload, err := s.parseClaimTicket(req.Ticket)
	if err != nil {
		return SessionResult{}, err
	}

	if err := s.verifyAndConsumeTargetKeyedCode(
		ctx, repository.VerificationPurposeAccountClaim, payload.Email, req.Code,
	); err != nil {
		return SessionResult{}, err
	}

	user, err := s.users.GetByPersonalEmail(ctx, payload.Email)
	if err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			// The account went away between the conflict and the code
			// coming back — deleted, or its address changed. There is
			// nothing to claim and nothing to apologise for; signing in
			// again now creates the account cleanly.
			return SessionResult{}, fmt.Errorf("that account is no longer available, please sign in again: %w", apperror.ErrInvalidInput)
		}
		return SessionResult{}, err
	}

	provider := FederatedProvider(payload.Provider)
	if err := s.attachClaimedIdentity(ctx, user, provider, payload.Subject); err != nil {
		return SessionResult{}, err
	}

	// Re-read rather than reuse the snapshot above: attaching LinkedIn
	// raises the trust level, and a session minted from the stale row would
	// hand the user an access token claiming the level they had a moment
	// ago. They would be told to verify something they just verified.
	refreshed, err := s.users.GetByID(ctx, user.ID)
	if err != nil {
		return SessionResult{}, err
	}
	return s.issueSession(ctx, refreshed)
}

// attachClaimedIdentity links the new provider to the claimed account so the
// next sign-in resolves directly instead of asking for a code again.
//
// # THE ONE CASE THAT MUST NOT OVERWRITE
//
// If the claimed account already has a DIFFERENT linkedin_sub, the LinkedIn
// connection on it is left exactly as it is. Writing the new sub would
// silently disconnect the LinkedIn account the user has been verified
// through — the thing their trust level, and every "verified professional"
// claim this product makes about them, actually rests on. Two LinkedIn
// members sharing one email address is genuinely ambiguous, and the safe
// reading of an ambiguous request is to change nothing.
//
// They still get in: proving control of the mailbox is what this ceremony
// is for, and that has already happened by the time this is called. They
// will be asked for a code again next time, which is the correct cost of an
// ambiguity this service cannot resolve on its own.
func (s *service) attachClaimedIdentity(
	ctx context.Context, user repository.User, provider FederatedProvider, subject string,
) error {
	if provider == FederatedProviderLinkedIn && user.LinkedInSub != "" && user.LinkedInSub != subject {
		s.logger.Warn("account claim left an existing LinkedIn connection in place",
			"event", "account_claim_linkedin_conflict", "user_id", user.ID)
		return nil
	}
	if provider == FederatedProviderLinkedIn && user.LinkedInSub == subject {
		// Already attached. Nothing to do, and the write would publish a
		// profile-updated event for a change that did not happen.
		return nil
	}

	err := s.LinkIdentityToUser(ctx, user.ID, provider, subject)
	if err == nil {
		return nil
	}
	if errors.Is(err, apperror.ErrConflict) {
		// That (provider, subject) belongs to somebody else's account.
		// LinkIdentityToUser refusing to merge is the correct behaviour and
		// must not be worked around here; the claim still succeeds, because
		// the mailbox proof was real, and the identity simply stays
		// unattached.
		s.logger.Warn("account claim could not attach an identity already linked elsewhere",
			"event", "account_claim_identity_taken", "user_id", user.ID, "provider", provider)
		return nil
	}
	return err
}

// claimIfEmailTaken is the pre-check both federated resolve paths run before
// creating an account. It returns nil when the address is free (including
// when there is no address at all, which is every guest and any provider
// that withheld one), and an *AccountClaimRequiredError when it is not.
//
// This is a check-then-act, and the gap is real: two signups for the same
// address can both find it free. That race is not this function's job to
// win. 0017's unique index is what makes the second INSERT fail, and the
// repository maps that failure to a conflict naming the email. The check
// exists to make the COMMON case a usable flow rather than an error.
func (s *service) claimIfEmailTaken(
	ctx context.Context, rawEmail string, provider FederatedProvider, subject string,
) error {
	normalized := identity.NormalizeEmail(rawEmail)
	if normalized == "" {
		return nil
	}
	if _, err := s.users.GetByPersonalEmail(ctx, normalized); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			return nil
		}
		return err
	}
	return s.beginAccountClaim(ctx, normalized, provider, subject)
}
