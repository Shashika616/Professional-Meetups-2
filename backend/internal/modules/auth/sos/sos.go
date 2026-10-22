// Package sos implements trusted contacts and the SOS trigger. It is a
// sub-package of the auth module, not a module of its own (ADR-001 §2): in
// the sibling microservices repo this is already part of the auth service —
// its tables live in auth_db and its four operations are AuthService RPCs —
// and re-homing it here would have been a redesign, not a port.
//
// Ported from ../Professional-Meetups/backend/services/auth/internal/
// service/sos.go, including its per-channel circuit breakers — see
// sendWithResilience and ADR-001's 2026-09-04 correction, which scoped "no
// breaker" back to the outbox/Pub/Sub use case it was actually about.
package sos

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/breaker"
	"professional-meetups-monolith/backend/internal/platform/geo"
)

// MaxTrustedContactsPerUser is a soft cap enforced here at the service
// layer, not as a DB constraint — mirrors how other soft caps in this
// codebase are enforced ("count then reject"). Exported so the module's
// tests assert against the rule rather than a copied literal.
const MaxTrustedContactsPerUser = 3

// Length caps mirror the auth module's own maxLegalNameLength-style
// constants — generous for any real name/message, not a tight UX-driven
// limit (the frontend has its own, tighter, purely-cosmetic ones).
const (
	MaxTrustedContactNameLength = 200
	MaxContextMessageLength     = 500
)

// TrustedContact is one of a user's own emergency contacts.
type TrustedContact struct {
	ID                   string
	Name                 string
	PhoneNumber          string
	Email                string
	CreatedAtUnixSeconds int64
	// Status is StatusConfirmed, StatusPending or StatusExpired (#80).
	Status string
}

// A trusted contact's consent state (#80). Only a confirmed contact is ever
// alerted.
const (
	StatusConfirmed = "confirmed"
	// StatusPending: texted a link, has not used it yet.
	StatusPending = "pending"
	// StatusExpired: the link lapsed unused. The only way on is to remove
	// the contact and add them again, which sends a fresh link.
	StatusExpired = "expired"
)

// Consent and abuse limits (#80).
//
// Every number here bounds something that costs money or reaches a person
// who did not ask for it. Adding a contact texts a stranger, so the per-user
// and per-number invitation caps are what stop "remove, re-add, repeat"
// from being a free way to spam someone at this project's Twilio expense.
const (
	contactConfirmTTL         = 24 * time.Hour
	maxInvitesPerUserPerDay   = 5
	maxInvitesPerNumberPerDay = 3
	inviteCapWindow           = 24 * time.Hour
	// contactInviteRetention keeps the invitation log a little past the
	// one-day window the caps read, then the auth sweeper drops it.
	contactInviteRetention = 7 * 24 * time.Hour

	// maxSOSPerDay bounds alerts per user. Generous for real use — an
	// emergency is not ten emergencies — and small enough that SOS is no
	// longer a way to text the same people without limit. The message a
	// capped user sees tells them to call emergency services.
	maxSOSPerDay = 10
	sosCapWindow = 24 * time.Hour

	// sosDuplicateWait is how long a retry waits for the attempt it
	// duplicates to finish, so it can report that attempt's real outcome.
	// Under the app's 10 s per-attempt deadline.
	sosDuplicateWait = 8 * time.Second
	sosDuplicatePoll = 250 * time.Millisecond

	// MaxClientRequestIDLength bounds the retry key a client may send.
	MaxClientRequestIDLength = 64
)

// AddTrustedContactRequest adds one contact. UserID always comes from the
// gateway's verified JWT, never a client-supplied field.
type AddTrustedContactRequest struct {
	UserID string
	Name   string
	// PhoneNumber is required and Email is optional — enforced here, in
	// AddTrustedContact, as ErrInvalidInput. The DB CHECK constraint
	// (migrations/0001, `phone_number IS NOT NULL OR email IS NOT NULL`) is
	// intentionally LOOSER: it predates the phone-mandatory rule and is not
	// a backstop for it. This method is the only insert path, which is what
	// makes the Go check sufficient; tightening the constraint is separate
	// work (gap tracker, Round 6 §Backend #36).
	PhoneNumber string
	Email       string
	// CallerTrustLevel comes from the JWT via the gateway, never from the
	// client. Read by the auth service's gate (ADR-003) BEFORE it delegates
	// here — this package deliberately does not check it itself, for the
	// same reason the validator is injected rather than duplicated: this
	// stays a plain CRUD/alerting layer.
	CallerTrustLevel int
}

// RemoveTrustedContactRequest removes one contact belonging to UserID.
type RemoveTrustedContactRequest struct {
	UserID    string
	ContactID string
}

// TriggerSOSRequest alerts every one of the caller's trusted contacts.
type TriggerSOSRequest struct {
	UserID         string
	ContextMessage string // optional — meetup title/location/time, or empty
	// ClientRequestID is the same for an attempt and its automatic retry,
	// so the retry reports the first attempt's outcome instead of alerting
	// everyone twice. Empty from app builds that predate it.
	ClientRequestID string
	// OPTIONAL (tracker #78, finding N-D2). nil means the device had no
	// usable fix: indoors, permission denied, or the read timed out. The
	// alert still goes, and says so.
	Latitude  *float64
	Longitude *float64
	// CallerTrustLevel — see AddTrustedContactRequest.CallerTrustLevel.
	CallerTrustLevel int
}

// TriggerSOSResult reports how many of the caller's trusted contacts were
// actually alerted — individual send failures don't fail the whole call, so
// this may be less than the caller's total contact count.
type TriggerSOSResult struct {
	ContactsNotified int32
}

// Validator is the auth module's own input validation, injected rather than
// duplicated: trusted-contact phone/email fields are validated by exactly
// the same rules as the verification flows' targets, and those rules live in
// the parent package. A function pair rather than an import, because the
// parent package imports this one.
type Validator struct {
	PhoneNumber func(string) error
	Email       func(string) error
}

// Service implements the trusted-contacts/SOS half of the auth module.
type Service struct {
	users           repository.UserRepository
	trustedContacts repository.TrustedContactRepository
	sosEvents       repository.SOSEventRepository
	sms             sms.SmsSender
	email           email.EmailSender
	validate        Validator
	logger          *slog.Logger
	// confirmBaseURL is the public origin the invitation link points at
	// (the gateway), e.g. https://meetups-backend-….run.app.
	confirmBaseURL string

	// smsBreaker/emailBreaker — one breaker per CHANNEL, not per call and not
	// per contact. A breaker's entire purpose is remembering consecutive
	// failures ACROSS requests, so it can notice "Twilio is down right now";
	// one constructed per RPC (or per contact) could never do that, and would
	// be indistinguishable from no breaker at all. They are therefore fields
	// on the long-lived Service, built once in New, and shared by every
	// TriggerSOS call from every user.
	//
	// Constructed internally with fixed thresholds rather than injected,
	// mirroring the source: these are tuning constants of this failure-
	// handling strategy, not a dependency a caller should be choosing.
	smsBreaker   *breaker.Breaker
	emailBreaker *breaker.Breaker
}

// New constructs a Service. Every dependency is passed explicitly — no
// framework, no globals.
func New(
	users repository.UserRepository,
	trustedContacts repository.TrustedContactRepository,
	sosEvents repository.SOSEventRepository,
	smsSender sms.SmsSender,
	emailSender email.EmailSender,
	validate Validator,
	confirmBaseURL string,
	logger *slog.Logger,
) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{
		users:           users,
		trustedContacts: trustedContacts,
		sosEvents:       sosEvents,
		sms:             smsSender,
		email:           emailSender,
		validate:        validate,
		logger:          logger,
		confirmBaseURL:  strings.TrimRight(confirmBaseURL, "/"),
		smsBreaker:      breaker.New(sosBreakerFailureThreshold, sosBreakerResetTimeout),
		emailBreaker:    breaker.New(sosBreakerFailureThreshold, sosBreakerResetTimeout),
	}
}

// sosBreakerFailureThreshold/sosBreakerResetTimeout size the two per-channel
// breakers. Same values as the source: open after 5 consecutive failures,
// and after 30s let exactly one trial call through (half-open) — a success
// closes it again, a failure re-opens it. 30s is short enough that a
// recovered vendor is picked up again within one emergency's timescale.
const (
	sosBreakerFailureThreshold = 5
	sosBreakerResetTimeout     = 30 * time.Second
)

// AddTrustedContact enforces the soft cap of 3 (ErrInvalidInput if exceeded)
// and requires a phone number (email is optional).
func (s *Service) AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error) {
	name := strings.TrimSpace(req.Name)
	if name == "" {
		return TrustedContact{}, fmt.Errorf("auth: name is required: %w", apperror.ErrInvalidInput)
	}
	if len(name) > MaxTrustedContactNameLength {
		return TrustedContact{}, fmt.Errorf("auth: name is too long: %w", apperror.ErrInvalidInput)
	}
	phone := strings.TrimSpace(req.PhoneNumber)
	emailAddr := strings.TrimSpace(req.Email)
	// PHONE IS MANDATORY, EMAIL OPTIONAL. An SOS is a phone call or a text
	// to someone who can act in the next few minutes; an inbox is checked
	// later. A contact reachable only by email is not a trusted contact in
	// the sense this feature promises, so the number is required and the
	// address is the extra channel when it is known.
	if phone == "" {
		return TrustedContact{}, fmt.Errorf("auth: a phone number is required for a trusted contact: %w", apperror.ErrInvalidInput)
	}
	// Format checks are an addition over the source, which validated these
	// two fields only in the Flutter client (manage_trusted_contacts_page's
	// Validators.phone/Validators.email) and accepted anything non-empty
	// server-side. Per docs/security-review-framework.md's "no
	// client-side-only validation, anywhere", the same rules are enforced
	// here — deliberately the frontend's exact rules, so nothing the
	// existing UI accepts is now rejected by the server.
	if err := s.validate.PhoneNumber(phone); err != nil {
		return TrustedContact{}, err
	}
	if emailAddr != "" {
		if err := s.validate.Email(emailAddr); err != nil {
			return TrustedContact{}, err
		}
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return TrustedContact{}, err
	}

	token, err := newConfirmToken()
	if err != nil {
		return TrustedContact{}, err
	}
	contact, err := s.trustedContacts.InsertPending(ctx, repository.NewPendingContact{
		UserID:             req.UserID,
		Name:               name,
		PhoneNumber:        phone,
		Email:              emailAddr,
		PhoneHash:          sha256Hex(identity.NormalizePhone(phone)),
		TokenHash:          sha256Hex(token),
		ExpiresAt:          time.Now().Add(contactConfirmTTL),
		MaxContacts:        MaxTrustedContactsPerUser,
		MaxInvitesPerUser:  maxInvitesPerUserPerDay,
		MaxInvitesPerPhone: maxInvitesPerNumberPerDay,
		CapWindow:          inviteCapWindow,
	})
	switch {
	case errors.Is(err, repository.ErrTooManyTrustedContacts):
		return TrustedContact{}, fmt.Errorf(
			"auth: at most %d trusted contacts are allowed: %w", MaxTrustedContactsPerUser, apperror.ErrInvalidInput,
		)
	case errors.Is(err, repository.ErrContactInviteLimit):
		return TrustedContact{}, fmt.Errorf(
			"auth: too many contact invitations today, try again tomorrow: %w", apperror.ErrRateLimited,
		)
	case err != nil:
		return TrustedContact{}, err
	}

	// The invitation goes out after the commit, so a number is never texted
	// for a contact that does not exist. A failed send leaves the contact
	// pending; the app shows it as waiting, and removing and re-adding it
	// sends a fresh link (within the caps).
	link := s.confirmBaseURL + "/c/" + token
	if err := s.sendWithResilience(ctx, s.smsBreaker, func() error {
		return s.sms.SendAlert(ctx, phone, InviteMessage(user.FullName, link))
	}); err != nil {
		// Never the number or the link: the link is a credential.
		s.logger.Error("send trusted contact invitation", "error", err)
	}
	return trustedContactFromRepo(contact), nil
}

// ConfirmTrustedContact records a contact's consent from the token in the
// link they were texted, and returns whose contact they have become. It
// needs no signed-in user: the token is the proof, single-use and
// short-lived. Unknown, expired and already-used tokens are all
// ErrNotFound, so the page cannot be used to probe which is which.
func (s *Service) ConfirmTrustedContact(ctx context.Context, token string) (string, error) {
	token = strings.TrimSpace(token)
	if token == "" || len(token) > 64 {
		return "", fmt.Errorf("auth: confirmation link: %w", apperror.ErrNotFound)
	}
	return s.trustedContacts.Confirm(ctx, sha256Hex(token))
}

// SweepContactInvites trims the invitation log the caps read.
func (s *Service) SweepContactInvites(ctx context.Context, batchSize int) (int, error) {
	return s.trustedContacts.DeleteInvitesSentBefore(ctx, time.Now().Add(-contactInviteRetention), batchSize)
}

// InviteMessage is the one SMS a new contact receives. It names who is
// asking, says what agreeing means, and carries the link. Nothing in it
// comes from the client except the requester's own account name.
func InviteMessage(requesterName, link string) string {
	return fmt.Sprintf(
		"%s wants you as their emergency contact on TieHere. To agree, open %s (expires in 24 hours). Ignore this to decline.",
		requesterName, link,
	)
}

// newConfirmToken is 128 random bits, URL-safe: short enough that the link
// keeps the SMS to one segment, and far beyond guessing.
func newConfirmToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("auth: confirmation token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// ListTrustedContacts is self-scoped — userID comes from the verified JWT,
// never a client-supplied id.
func (s *Service) ListTrustedContacts(ctx context.Context, userID string) ([]TrustedContact, error) {
	contacts, err := s.trustedContacts.ListForUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]TrustedContact, 0, len(contacts))
	for _, c := range contacts {
		out = append(out, trustedContactFromRepo(c))
	}
	return out, nil
}

// RemoveTrustedContact scopes the delete to (contact_id, user_id) in one
// atomic statement — a caller can never remove another user's contact by
// guessing an id, and there is no check-then-delete TOCTOU gap.
func (s *Service) RemoveTrustedContact(ctx context.Context, req RemoveTrustedContactRequest) error {
	if err := s.trustedContacts.Delete(ctx, req.ContactID, req.UserID); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			// No row matched (contact_id, user_id) — either it doesn't exist
			// or it belongs to someone else; deliberately not distinguished,
			// so this never confirms or denies whether a given contact_id
			// exists under a different account.
			return fmt.Errorf("auth: caller does not own trusted contact %s: %w", req.ContactID, apperror.ErrForbidden)
		}
		return err
	}
	return nil
}

// TriggerSOS is entirely an auth-module operation, no cross-module call: the
// client supplies meetup context as a plain string rather than this module
// reaching into the meetup module's data (which ADR-001 §2 forbids anyway).
// Rejects if the caller has zero trusted contacts — the gateway routes that
// to a clear "add a contact first" state, not a raw error. Individual
// contact-send failures don't fail the whole call: they're logged and
// skipped.
//
// Four guarantees on top of that (#80, and the retry duplicate):
//
//   - Only CONFIRMED contacts are alerted. A pending contact has not agreed
//     to receive these.
//   - The event is claimed BEFORE anything is sent. A retry carrying the
//     same ClientRequestID finds the claim and reports that attempt's
//     outcome instead of alerting everyone a second time.
//   - At most maxSOSPerDay per user, counted under a lock with the claim.
//   - The text is a fixed template. Nothing the client sends reaches the
//     message, so this cannot be used to text arbitrary words or links.
//     The context string is still kept in the audit row.
func (s *Service) TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error) {
	contextMessage := strings.TrimSpace(req.ContextMessage)
	if len(contextMessage) > MaxContextMessageLength {
		return TriggerSOSResult{}, fmt.Errorf("auth: context message is too long: %w", apperror.ErrInvalidInput)
	}
	if len(req.ClientRequestID) > MaxClientRequestIDLength {
		return TriggerSOSResult{}, fmt.Errorf("auth: client request id is too long: %w", apperror.ErrInvalidInput)
	}
	// Garbage coordinates would otherwise flow straight into a real maps
	// link sent to a real trusted contact. Absent coordinates are not
	// garbage, though — they are a legitimate state now (#78), and only a
	// COMPLETE pair is validated or used.
	hasLocation := req.Latitude != nil && req.Longitude != nil
	if hasLocation {
		if err := geo.ValidateLatLng(*req.Latitude, *req.Longitude); err != nil {
			return TriggerSOSResult{}, fmt.Errorf("auth: %v: %w", err, apperror.ErrInvalidInput)
		}
	}

	contacts, err := s.trustedContacts.ListForUser(ctx, req.UserID)
	if err != nil {
		return TriggerSOSResult{}, err
	}
	if len(contacts) == 0 {
		return TriggerSOSResult{}, fmt.Errorf("auth: add a trusted contact before triggering SOS: %w", apperror.ErrInvalidInput)
	}
	confirmed := make([]repository.TrustedContact, 0, len(contacts))
	for _, c := range contacts {
		if c.Confirmed() {
			confirmed = append(confirmed, c)
		}
	}
	if len(confirmed) == 0 {
		return TriggerSOSResult{}, fmt.Errorf(
			"auth: none of your trusted contacts has confirmed yet, so no alert could be sent. Call your local emergency number: %w",
			apperror.ErrInvalidInput)
	}

	outcome, err := s.sosEvents.Claim(ctx, repository.SOSClaim{
		Event: repository.SOSEvent{
			UserID:         req.UserID,
			ContextMessage: contextMessage,
			Latitude:       req.Latitude,
			Longitude:      req.Longitude,
		},
		ClientRequestID: req.ClientRequestID,
		MaxPerWindow:    maxSOSPerDay,
		Window:          sosCapWindow,
	})
	switch {
	case errors.Is(err, repository.ErrSOSLimit):
		return TriggerSOSResult{}, fmt.Errorf(
			"auth: you have sent the maximum number of SOS alerts today. Call your local emergency number: %w",
			apperror.ErrRateLimited)
	case err != nil:
		// The claim is bookkeeping and deduplication; the alert is the
		// emergency. A database problem here must not stop it going out.
		s.logger.Error("claim sos event, sending without a claim", "error", err)
	case outcome.Duplicate:
		return s.awaitDuplicate(ctx, req, outcome, len(confirmed)), nil
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return TriggerSOSResult{}, err
	}

	message := AlertMessage(user.FullName, req.Latitude, req.Longitude)
	if !hasLocation {
		// Worth a line in the logs: a run of these is the signal that
		// location permission or the fix itself is broken on real
		// devices, which is invisible from the alert alone.
		s.logger.Warn("sos triggered without a location fix",
			"event", "sos_without_location", "user_id", req.UserID)
	}

	notified := 0
	for _, contact := range confirmed {
		sent := false
		if contact.PhoneNumber != "" {
			if err := s.sendWithResilience(ctx, s.smsBreaker, func() error {
				return s.sms.SendAlert(ctx, contact.PhoneNumber, message)
			}); err != nil {
				// Never logs the contact's number or the message body — an
				// SOS alert carries a real name and precise coordinates.
				s.logger.Error("send sos alert sms", "error", err)
			} else {
				sent = true
			}
		}
		if contact.Email != "" {
			if err := s.sendWithResilience(ctx, s.emailBreaker, func() error {
				return s.email.SendAlert(ctx, contact.Email, message)
			}); err != nil {
				s.logger.Error("send sos alert email", "error", err)
			} else {
				sent = true
			}
		}
		if sent {
			notified++
		}
	}

	if outcome.EventID != "" {
		// A detached context: the alerts are out, and the record of how
		// many went must survive the caller hanging up — a retry is about
		// to read it.
		recordCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if err := s.sosEvents.Complete(recordCtx, outcome.EventID, notified); err != nil {
			s.logger.Error("complete sos event", "error", err)
		}
	}
	return TriggerSOSResult{ContactsNotified: int32(notified)}, nil
}

// awaitDuplicate answers a retry of an SOS that is already claimed. It
// sends nothing. If the original attempt has finished, its real count is
// the answer. If it is still sending — the usual reason the client timed
// out and retried — wait briefly for it, so the user is told what actually
// happened.
//
// If it is STILL running when the wait runs out, report the contacts it is
// sending to. That attempt is live and alerting exactly those people; the
// alternative, an error, would invite the user to press SOS again and
// alert them twice, which is the thing this exists to prevent.
func (s *Service) awaitDuplicate(ctx context.Context, req TriggerSOSRequest, outcome repository.SOSOutcome, confirmed int) TriggerSOSResult {
	waitCtx, cancel := context.WithTimeout(ctx, sosDuplicateWait)
	defer cancel()
	ticker := time.NewTicker(sosDuplicatePoll)
	defer ticker.Stop()

	for !outcome.Completed {
		select {
		case <-waitCtx.Done():
			s.logger.Warn("sos retry arrived while the original was still sending",
				"event", "sos_duplicate_still_sending", "user_id", req.UserID)
			return TriggerSOSResult{ContactsNotified: int32(confirmed)}
		case <-ticker.C:
			latest, err := s.sosEvents.Outcome(waitCtx, req.UserID, req.ClientRequestID)
			if err == nil {
				outcome = latest
			}
		}
	}
	return TriggerSOSResult{ContactsNotified: int32(outcome.ContactsNotified)}
}

// sendMaxAttempts/sendRetryDelay bound each individual alert send.
// Deliberately NOT moved onto an async/eventual-delivery path — that would
// trade the caller's immediate success/failure feedback for eventual
// consistency they can't see, the wrong trade for an emergency alert. A
// small bounded retry with a short FIXED delay (not exponential — this needs
// to resolve inside the RPC's own timeout, not stretch it out).
const (
	sendMaxAttempts = 2
	sendRetryDelay  = 500 * time.Millisecond
)

// sendWithResilience runs send through br — so a channel that is currently
// down fails fast via breaker.ErrOpen instead of eating the retry delay on
// every subsequent contact — with up to sendMaxAttempts tries inside it.
// Same shape as the source's sendSOSAlertWithResilience: the retry is the
// inner layer, the breaker the outer one.
//
// The RPC's response contract is unchanged by this — still fully
// synchronous, still a real success count; this only gives an individual
// send a fighting chance against a transient failure before TriggerSOS's
// existing per-contact tolerance (a failed contact doesn't fail the whole
// call) kicks in.
func (s *Service) sendWithResilience(ctx context.Context, br *breaker.Breaker, send func() error) error {
	var lastErr error
	for attempt := 1; attempt <= sendMaxAttempts; attempt++ {
		err := br.Execute(send)
		if err == nil {
			return nil
		}
		lastErr = err
		if errors.Is(err, breaker.ErrOpen) {
			// The breaker itself is refusing to even try — retrying
			// immediately would just get ErrOpen again with no real send
			// attempted, so stop here rather than burning the remaining
			// attempts (and their delays) on a channel already known to be
			// down. This is exactly the fail-fast the breaker exists for.
			return lastErr
		}
		if attempt < sendMaxAttempts {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(sendRetryDelay):
			}
		}
	}
	return lastErr
}

// AlertMessage builds the alert body sent to each trusted contact: the
// caller's name, "may need help," and a maps link built from the
// coordinates. Exported for the module's tests.
//
// A FIXED TEMPLATE (#80). It used to append the client's context string,
// which made SOS a way to send arbitrary text — links included — to anyone
// entered as a contact. The app only ever sent a constant there, so
// dropping it costs nothing; every field below is server-sourced.
//
// With no coordinates (#78) it says so outright instead of omitting the
// line. A contact who has just been told someone may need help will look
// for a location; silence there reads as "the message was cut off", while
// "Location unavailable" tells them what they actually need to know —
// that this one has to be answered by calling the person.
func AlertMessage(callerName string, lat, lng *float64) string {
	msg := fmt.Sprintf("%s may need help.", callerName)
	if lat == nil || lng == nil {
		return msg + " Location unavailable."
	}
	msg += fmt.Sprintf(" Location: https://maps.google.com/?q=%f,%f", *lat, *lng)
	return msg
}

func trustedContactFromRepo(c repository.TrustedContact) TrustedContact {
	status := StatusConfirmed
	switch {
	case c.Confirmed():
	case time.Now().Before(c.PendingUntil):
		status = StatusPending
	default:
		status = StatusExpired
	}
	return TrustedContact{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		Email:                c.Email,
		CreatedAtUnixSeconds: c.CreatedAt.Unix(),
		Status:               status,
	}
}

// MeetupShare is what a caller wants their chosen contacts told about one
// meetup. Every field is server-sourced by the meetup module from the meetup
// row itself — see NotifyMeetupShare for why none of it comes from the
// client.
type MeetupShare struct {
	ContactIDs    []string
	LocationLabel string
	Latitude      float64
	Longitude     float64
	WindowStart   time.Time
	WindowEnd     time.Time
}

// NotifyMeetupShare tells the caller's SELECTED trusted contacts where and
// when they are meeting someone.
//
// # HOW THIS DIFFERS FROM TriggerSOS
//
// TriggerSOS is an emergency: it alerts EVERY contact, and its body carries
// a free-text context message the client supplies. This is the calm,
// planned version — the user picks who to tell, before anything has gone
// wrong — so:
//
//   - it fans out only to [MeetupShare.ContactIDs], and silently ignores an
//     id that is not one of this user's own contacts. A caller cannot text a
//     stranger by guessing a uuid;
//   - NOTHING in the body comes from the client. The meetup module reads the
//     window, label and coordinates off the meetup row and passes them here,
//     so the worst a modified client can do is tell its own contacts about a
//     meetup it is genuinely a participant of.
//
// Sends are best-effort per contact, exactly like TriggerSOS: one contact's
// failure is logged and skipped rather than failing the whole call, and the
// same per-channel circuit breakers apply so a degraded Twilio cannot stall
// the request.
func (s *Service) NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) (int, error) {
	if len(share.ContactIDs) == 0 {
		return 0, fmt.Errorf("auth: pick at least one trusted contact: %w", apperror.ErrInvalidInput)
	}
	if err := geo.ValidateLatLng(share.Latitude, share.Longitude); err != nil {
		return 0, fmt.Errorf("auth: %v: %w", err, apperror.ErrInvalidInput)
	}

	contacts, err := s.trustedContacts.ListForUser(ctx, userID)
	if err != nil {
		return 0, err
	}
	if len(contacts) == 0 {
		return 0, fmt.Errorf("auth: add a trusted contact first: %w", apperror.ErrInvalidInput)
	}

	// Intersect with what the caller actually owns. This is the check that
	// makes a contact id safe to accept from the client at all.
	wanted := make(map[string]bool, len(share.ContactIDs))
	for _, id := range share.ContactIDs {
		wanted[id] = true
	}
	selected := make([]repository.TrustedContact, 0, len(share.ContactIDs))
	unconfirmed := 0
	for _, c := range contacts {
		if !wanted[c.ID] {
			continue
		}
		// Only a contact who agreed is texted (#80), here as for SOS.
		if !c.Confirmed() {
			unconfirmed++
			continue
		}
		selected = append(selected, c)
	}
	if len(selected) == 0 {
		if unconfirmed > 0 {
			return 0, fmt.Errorf("auth: those contacts have not confirmed yet: %w", apperror.ErrInvalidInput)
		}
		return 0, fmt.Errorf("auth: none of those contacts belong to you: %w", apperror.ErrInvalidInput)
	}

	user, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return 0, err
	}

	message := MeetupShareMessage(
		user.FullName, share.LocationLabel, share.Latitude, share.Longitude,
		share.WindowStart, share.WindowEnd,
	)

	notified := 0
	for _, contact := range selected {
		sent := false
		if contact.PhoneNumber != "" {
			if err := s.sendWithResilience(ctx, s.smsBreaker, func() error {
				return s.sms.SendAlert(ctx, contact.PhoneNumber, message)
			}); err != nil {
				// Never logs the number or the body — this message names a
				// real person, a real place and a real time.
				s.logger.Error("send meetup share sms", "error", err)
			} else {
				sent = true
			}
		}
		if contact.Email != "" {
			if err := s.sendWithResilience(ctx, s.emailBreaker, func() error {
				return s.email.SendAlert(ctx, contact.Email, message)
			}); err != nil {
				s.logger.Error("send meetup share email", "error", err)
			} else {
				sent = true
			}
		}
		if sent {
			notified++
		}
	}
	return notified, nil
}

// MeetupShareMessage builds the body each selected contact receives.
// Exported for the module's tests, same as AlertMessage.
//
// Deliberately states a WINDOW and a PLACE, not "live location". The link is
// a static map pin at the meetup's own coordinates — the app does not track
// anyone, and a message implying otherwise would be a safety promise it
// cannot keep.
func MeetupShareMessage(callerName, locationLabel string, lat, lng float64, start, end time.Time) string {
	msg := fmt.Sprintf(
		"%s is meeting %s–%s",
		callerName,
		start.Format("Mon 3:04 PM"),
		end.Format("3:04 PM"),
	)
	if strings.TrimSpace(locationLabel) != "" {
		msg += fmt.Sprintf(" at %s", locationLabel)
	}
	msg += fmt.Sprintf(". Location: https://maps.google.com/?q=%f,%f", lat, lng)
	return msg
}
