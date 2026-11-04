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
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/breaker"
	"professional-meetups-monolith/backend/internal/platform/geo"
	"professional-meetups-monolith/backend/internal/platform/ratelimit"
)

// MaxTrustedContactsPerUser is how many contacts can be added, and how many
// are alerted (plan 2.2). An account from before the cap may hold 3: it
// keeps them, and SOS alerts the 2 oldest (decision D5). Exported so the
// module's tests assert against the rule rather than a copied literal.
const MaxTrustedContactsPerUser = 2

// MaxContextMessageLength bounds the audit-only context string.
const MaxContextMessageLength = 500

// TrustedContact is one of a user's own emergency contacts: a name and a
// phone number (ADR-013). They never confirm and hear from us only when the
// user presses SOS or shares a meetup.
type TrustedContact struct {
	ID                   string
	Name                 string
	PhoneNumber          string
	CreatedAtUnixSeconds int64
}

const (
	// maxSOSPerDay bounds alerts per user. Generous for real use — an
	// emergency is not ten emergencies — and small enough that SOS is no
	// longer a way to text the same people without limit. The message a
	// capped user sees tells them to call emergency services.
	maxSOSPerDay = 10
	sosCapWindow = 24 * time.Hour
	// maxSOSPerHour was the gateway's in-memory limit, one count per
	// instance; it is now counted with the daily cap (#81).
	maxSOSPerHour = 5

	// sosDuplicateWait is how long a retry waits for the attempt it
	// duplicates to finish, so it can report that attempt's real outcome.
	// Under the app's 10 s per-attempt deadline.
	sosDuplicateWait = 8 * time.Second
	sosDuplicatePoll = 250 * time.Millisecond

	// MaxClientRequestIDLength bounds the retry key a client may send.
	MaxClientRequestIDLength = 64

	// clockSkew forgives a phone clock a little ahead of ours: a fix taken
	// just now must not be thrown away for that.
	clockSkew = 5 * time.Minute

	// meetupLookupTimeout bounds the optional meetup section: the alert
	// never waits long for it.
	meetupLookupTimeout = 2 * time.Second
)

// MeetupLookup finds the meetup a user is on around now: hosting or
// accepted, status open or full, now within the window give or take 2
// hours. A port: the meetup module owns meetups (wired in cmd/monolith).
type MeetupLookup interface {
	ActiveMeetup(ctx context.Context, userID string, now time.Time) (AlertMeetup, bool, error)
}

// AddTrustedContactRequest adds one contact. UserID always comes from the
// gateway's verified JWT, never a client-supplied field.
type AddTrustedContactRequest struct {
	UserID      string
	Name        string
	PhoneNumber string
	// CallerTrustLevel comes from the JWT via the gateway, never from the
	// client. Read by the auth service's gate (ADR-003) BEFORE it delegates
	// here — this package deliberately does not check it itself, for the
	// same reason the validator is injected rather than duplicated: this
	// stays a plain CRUD/alerting layer.
	CallerTrustLevel int
}

// UpdateTrustedContactRequest changes one contact belonging to UserID.
type UpdateTrustedContactRequest struct {
	UserID      string
	ContactID   string
	Name        string
	PhoneNumber string
	// CallerTrustLevel — see AddTrustedContactRequest.CallerTrustLevel.
	CallerTrustLevel int
}

// RemoveTrustedContactRequest removes one contact belonging to UserID.
type RemoveTrustedContactRequest struct {
	UserID    string
	ContactID string
}

// TriggerSOSRequest alerts the caller's two oldest trusted contacts.
type TriggerSOSRequest struct {
	UserID         string
	ContextMessage string // optional — meetup title/location/time, or empty
	// ClientRequestID is the same for an attempt and its automatic retry,
	// so the retry reports the first attempt's outcome instead of alerting
	// everyone twice. Empty from app builds that predate it.
	ClientRequestID string
	// OPTIONAL (tracker #78, finding N-D2). nil means the device had no
	// usable fix: indoors, permission denied, or the read timed out. The
	// alert still goes, using the location we stored, or saying there is
	// none.
	Latitude  *float64
	Longitude *float64
	// CapturedAt is when the phone took that fix, and Source is "gps" or
	// "device_last_known". Both are absent from older app builds, which
	// only ever sent a fresh fix.
	CapturedAt *time.Time
	Source     string
	// CallerTrustLevel — see AddTrustedContactRequest.CallerTrustLevel.
	CallerTrustLevel int
}

// TriggerSOSResult reports how many of the caller's trusted contacts were
// actually alerted — individual send failures don't fail the whole call, so
// this may be less than the caller's total contact count.
type TriggerSOSResult struct {
	ContactsNotified int32
}

// Service implements the trusted-contacts/SOS half of the auth module.
type Service struct {
	users           repository.UserRepository
	trustedContacts repository.TrustedContactRepository
	sosEvents       repository.SOSEventRepository
	sms             sms.SmsSender
	logger          *slog.Logger

	// smsBreaker — per CHANNEL, not per call and not per contact. A
	// breaker's entire purpose is remembering consecutive failures ACROSS
	// requests, so it can notice "Twilio is down right now"; one constructed
	// per RPC could never do that. It is therefore a field on the long-lived
	// Service, built once in New, and shared by every call from every user.
	smsBreaker *breaker.Breaker

	// limits counts trusted-contact changes and meetup shares across
	// instances (#81). Nil: no such limits (unit tests).
	limits *ratelimit.Shared

	// meetups finds the meetup section of an alert. Nil: no section.
	meetups MeetupLookup

	// now is time.Now; tests fix it.
	now func() time.Time
}

// Limits counted in Postgres (#81, plan 30 D1). Contact changes fail closed:
// the contacts did not opt in, so an unlimited stream of changes is the abuse
// to stop. A share failing open costs at most a few extra texts.
var (
	contactChangeRule = ratelimit.Rule{Name: "auth:trusted-contact-change", Limit: 5, Window: 24 * time.Hour, FailClosed: true}
	meetupShareRule   = ratelimit.Rule{Name: "auth:meetup-share", Limit: 3, Window: 24 * time.Hour}
)

// WithLimits sets the shared limiter and returns s.
func (s *Service) WithLimits(l *ratelimit.Shared) *Service {
	s.limits = l
	return s
}

// WithMeetups sets the meetup lookup and returns s.
func (s *Service) WithMeetups(m MeetupLookup) *Service {
	s.meetups = m
	return s
}

// New constructs a Service. Every dependency is passed explicitly — no
// framework, no globals.
func New(
	users repository.UserRepository,
	trustedContacts repository.TrustedContactRepository,
	sosEvents repository.SOSEventRepository,
	smsSender sms.SmsSender,
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
		logger:          logger,
		smsBreaker:      breaker.New(sosBreakerFailureThreshold, sosBreakerResetTimeout),
		now:             time.Now,
	}
}

// sosBreakerFailureThreshold/sosBreakerResetTimeout size the breaker. Same values as the source: open after 5 consecutive failures,
// and after 30s let exactly one trial call through (half-open) — a success
// closes it again, a failure re-opens it. 30s is short enough that a
// recovered vendor is picked up again within one emergency's timescale.
const (
	sosBreakerFailureThreshold = 5
	sosBreakerResetTimeout     = 30 * time.Second
)

// AddTrustedContact adds a name and number. It sends nothing (ADR-013): the
// contact hears from us only if the user presses SOS.
func (s *Service) AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error) {
	name, phone, err := contactFields(req.Name, req.PhoneNumber)
	if err != nil {
		return TrustedContact{}, err
	}
	if err := s.checkContactChange(ctx, req.UserID); err != nil {
		return TrustedContact{}, err
	}
	contact, err := s.trustedContacts.Insert(ctx, repository.NewContact{
		UserID: req.UserID, Name: name, PhoneNumber: phone, MaxContacts: MaxTrustedContactsPerUser,
	})
	switch {
	case errors.Is(err, repository.ErrTooManyTrustedContacts):
		return TrustedContact{}, fmt.Errorf(
			"auth: at most %d trusted contacts are allowed: %w", MaxTrustedContactsPerUser, apperror.ErrInvalidInput,
		)
	case errors.Is(err, repository.ErrDuplicateTrustedContact):
		return TrustedContact{}, errDuplicateContact
	case err != nil:
		return TrustedContact{}, err
	}
	return trustedContactFromRepo(contact), nil
}

// UpdateTrustedContact changes a contact's name or number, within the same
// daily limit as adding one. It sends nothing either.
func (s *Service) UpdateTrustedContact(ctx context.Context, req UpdateTrustedContactRequest) (TrustedContact, error) {
	name, phone, err := contactFields(req.Name, req.PhoneNumber)
	if err != nil {
		return TrustedContact{}, err
	}
	if err := s.checkContactChange(ctx, req.UserID); err != nil {
		return TrustedContact{}, err
	}
	contact, err := s.trustedContacts.Update(ctx, req.ContactID, req.UserID, name, phone)
	switch {
	case errors.Is(err, apperror.ErrNotFound):
		return TrustedContact{}, fmt.Errorf("auth: caller does not own trusted contact %s: %w", req.ContactID, apperror.ErrForbidden)
	case errors.Is(err, repository.ErrDuplicateTrustedContact):
		return TrustedContact{}, errDuplicateContact
	case err != nil:
		return TrustedContact{}, err
	}
	return trustedContactFromRepo(contact), nil
}

var errDuplicateContact = fmt.Errorf("auth: this number is already one of your trusted contacts: %w", apperror.ErrConflict)

func contactFields(rawName, rawPhone string) (name, phone string, err error) {
	if name, err = CleanContactName(rawName); err != nil {
		return "", "", err
	}
	if phone, err = NormalizeContactPhone(rawPhone); err != nil {
		return "", "", err
	}
	return name, phone, nil
}

func (s *Service) checkContactChange(ctx context.Context, userID string) error {
	if err := s.limits.Check(ctx, contactChangeRule, userID); err != nil {
		return fmt.Errorf("auth: you can change your trusted contacts %d times a day: %w", contactChangeRule.Limit, err)
	}
	return nil
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

// TriggerSOS alerts the caller's two oldest trusted contacts by SMS. SOS is
// strictly reactive: this is the only thing that ever alerts them (ADR-013).
// Rejects if the caller has zero trusted contacts — the gateway routes that
// to a clear "add a contact first" state, not a raw error. Individual
// send failures don't fail the whole call: they're logged and skipped.
//
//   - The event is claimed BEFORE anything is sent. A retry carrying the
//     same ClientRequestID finds the claim and reports that attempt's
//     outcome instead of alerting everyone a second time.
//   - At most maxSOSPerHour and maxSOSPerDay per user, counted under a lock
//     with the claim.
//   - The text is a fixed template. Nothing the client sends reaches the
//     message, so this cannot be used to text arbitrary words or links.
//     The context string is still kept in the audit row.
//
// Everything that adds to the message degrades rather than fails: without
// the user's row, a location or a meetup, the alert still goes and says
// what it knows.
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
	if req.Latitude != nil && req.Longitude != nil {
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
	// Oldest first: an account with 3 alerts the first two (D5).
	if len(contacts) > MaxTrustedContactsPerUser {
		contacts = contacts[:MaxTrustedContactsPerUser]
	}

	now := s.now()
	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		s.logger.Error("sos: read the user, alerting without their name", "error", err)
		user = repository.User{}
	}
	location := resolveLocation(req, user, now)

	event := repository.SOSEvent{
		UserID: req.UserID, ContextMessage: contextMessage, LocationSource: location.Kind.Source(),
	}
	if location.Kind != LocationUnknown {
		event.Latitude, event.Longitude = &location.Lat, &location.Lng
		event.LocationCapturedAt = &location.CapturedAt
	}
	outcome, err := s.sosEvents.Claim(ctx, repository.SOSClaim{
		Event:           event,
		ClientRequestID: req.ClientRequestID,
		MaxPerWindow:    maxSOSPerDay,
		Window:          sosCapWindow,
		MaxPerHour:      maxSOSPerHour,
	})
	switch {
	case errors.Is(err, repository.ErrSOSLimit):
		return TriggerSOSResult{}, fmt.Errorf(
			"auth: you have sent the maximum number of SOS alerts today. Call your local emergency number: %w",
			apperror.ErrRateLimited)
	case errors.Is(err, repository.ErrSOSHourlyLimit):
		return TriggerSOSResult{}, fmt.Errorf(
			"auth: you have sent the maximum number of SOS alerts for this hour. Call your local emergency number: %w",
			apperror.ErrRateLimited)
	case err != nil:
		// The claim is bookkeeping and deduplication; the alert is the
		// emergency. A database problem here must not stop it going out.
		s.logger.Error("claim sos event, sending without a claim", "error", err)
	case outcome.Duplicate && outcome.Completed && outcome.ContactsNotified == 0:
		// The attempt this repeats reached nobody, so the user's Retry must
		// really try again. Nobody can be alerted twice.
	case outcome.Duplicate:
		return s.awaitDuplicate(ctx, req, outcome, len(contacts)), nil
	}

	if location.Kind == LocationUnknown {
		// Worth a line in the logs: a run of these is the signal that
		// location permission or the fix itself is broken on real
		// devices, which is invisible from the alert alone.
		s.logger.Warn("sos triggered without a location",
			"event", "sos_without_location", "user_id", req.UserID)
	}
	message := AlertMessage(AlertInput{
		Name: user.FullName, Location: location, Meetup: s.activeMeetup(ctx, req.UserID, now), TriggeredAt: now,
	})

	notified := 0
	for _, contact := range contacts {
		if err := s.sendWithResilience(ctx, s.smsBreaker, func() error {
			return s.sms.SendAlert(ctx, contact.PhoneNumber, message)
		}); err != nil {
			// Never logs the contact's number or the message body — an
			// SOS alert carries a real name and precise coordinates.
			s.logger.Error("send sos alert sms", "error", err)
			continue
		}
		notified++
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

// resolveLocation walks the chain (plan 2.2): the phone's fix, if it is
// usable, then the location we stored, then unknown.
//
// A fix stamped in the future, or older than a day, is treated as no fix.
// The alert is never refused for it: a wrong phone clock must not stop an
// SOS. A stored location older than a day says as little, and is left out
// the same way.
func resolveLocation(req TriggerSOSRequest, user repository.User, now time.Time) AlertLocation {
	if loc, ok := phoneFix(req, now); ok {
		return loc
	}
	if user.LastLocationLat != nil && user.LastLocationLng != nil && user.LastLocationUpdatedAt != nil &&
		now.Sub(*user.LastLocationUpdatedAt) <= geo.LocationFreshFor {
		return AlertLocation{
			Kind: LocationServer, Lat: *user.LastLocationLat, Lng: *user.LastLocationLng,
			CapturedAt: *user.LastLocationUpdatedAt,
		}
	}
	return AlertLocation{}
}

// phoneFix reads the phone's part of the chain. Only "gps", or a build too
// old to say, is called current; anything else is the weaker claim.
func phoneFix(req TriggerSOSRequest, now time.Time) (AlertLocation, bool) {
	if req.Latitude == nil || req.Longitude == nil {
		return AlertLocation{}, false
	}
	loc := AlertLocation{Kind: LocationDevice, Lat: *req.Latitude, Lng: *req.Longitude, CapturedAt: now}
	if req.Source == "gps" || (req.Source == "" && req.CapturedAt == nil) {
		loc.Kind = LocationGPS
	}
	if req.CapturedAt == nil {
		return loc, true
	}
	at := *req.CapturedAt
	if at.After(now.Add(clockSkew)) || now.Sub(at) > geo.LocationFreshFor {
		return AlertLocation{}, false
	}
	if at.Before(now) {
		loc.CapturedAt = at
	}
	return loc, true
}

// activeMeetup is the optional meetup section. A failure leaves it out.
func (s *Service) activeMeetup(ctx context.Context, userID string, now time.Time) *AlertMeetup {
	if s.meetups == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, meetupLookupTimeout)
	defer cancel()
	m, ok, err := s.meetups.ActiveMeetup(ctx, userID, now)
	if err != nil {
		s.logger.Error("sos: look up the active meetup, alerting without it", "error", err)
		return nil
	}
	if !ok {
		return nil
	}
	return &m
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

func trustedContactFromRepo(c repository.TrustedContact) TrustedContact {
	return TrustedContact{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		CreatedAtUnixSeconds: c.CreatedAt.Unix(),
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
// TriggerSOS is an emergency: it alerts the two oldest contacts. This is the calm,
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
// Sends are SMS only and best-effort per contact, exactly like TriggerSOS:
// one contact's failure is logged and skipped rather than failing the whole
// call, and the same circuit breaker applies so a degraded Twilio cannot
// stall the request.
func (s *Service) NotifyMeetupShare(ctx context.Context, userID string, share MeetupShare) ([]string, error) {
	if len(share.ContactIDs) == 0 {
		return nil, fmt.Errorf("auth: pick at least one trusted contact: %w", apperror.ErrInvalidInput)
	}
	if err := geo.ValidateLatLng(share.Latitude, share.Longitude); err != nil {
		return nil, fmt.Errorf("auth: %v: %w", err, apperror.ErrInvalidInput)
	}

	contacts, err := s.trustedContacts.ListForUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	if len(contacts) == 0 {
		return nil, fmt.Errorf("auth: add a trusted contact first: %w", apperror.ErrInvalidInput)
	}

	// Intersect with what the caller actually owns. This is the check that
	// makes a contact id safe to accept from the client at all.
	wanted := make(map[string]bool, len(share.ContactIDs))
	for _, id := range share.ContactIDs {
		wanted[id] = true
	}
	selected := make([]repository.TrustedContact, 0, len(share.ContactIDs))
	for _, c := range contacts {
		if wanted[c.ID] {
			selected = append(selected, c)
		}
	}
	if len(selected) == 0 {
		return nil, fmt.Errorf("auth: none of those contacts belong to you: %w", apperror.ErrInvalidInput)
	}
	// Three shares a day (D1), counted only once there is someone to tell.
	if err := s.limits.Check(ctx, meetupShareRule, userID); err != nil {
		return nil, fmt.Errorf("auth: you can share %d meetups a day with your contacts: %w", meetupShareRule.Limit, err)
	}

	user, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	message := MeetupShareMessage(
		user.FullName, share.LocationLabel, share.Latitude, share.Longitude,
		share.WindowStart, share.WindowEnd,
	)

	var notified []string
	for _, contact := range selected {
		if err := s.sendWithResilience(ctx, s.smsBreaker, func() error {
			return s.sms.SendAlert(ctx, contact.PhoneNumber, message)
		}); err != nil {
			// Never logs the number or the body — this message names a
			// real person, a real place and a real time.
			s.logger.Error("send meetup share sms", "error", err)
			continue
		}
		notified = append(notified, contact.ID)
	}
	return notified, nil
}
