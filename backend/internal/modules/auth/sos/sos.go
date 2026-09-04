// Package sos implements trusted contacts and the SOS trigger. It is a
// sub-package of the auth module, not a module of its own (ADR-001 §2): in
// the sibling microservices repo this is already part of the auth service —
// its tables live in auth_db and its four operations are AuthService RPCs —
// and re-homing it here would have been a redesign, not a port.
//
// Ported from ../Professional-Meetups/backend/services/auth/internal/
// service/sos.go. One deliberate behavior change, flagged at
// sendSOSAlertWithRetry: the source wraps each send in a circuit breaker
// (shared/breaker) as well as a bounded retry, and ADR-001 §7 does not carry
// shared/breaker into this repo at all. The retry is kept, the breaker is
// not — see that function's comment for the consequence.
package sos

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sms"
	"professional-meetups-monolith/backend/internal/platform/apperror"
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
}

// AddTrustedContactRequest adds one contact. UserID always comes from the
// gateway's verified JWT, never a client-supplied field.
type AddTrustedContactRequest struct {
	UserID string
	Name   string
	// At least one of PhoneNumber/Email is required — enforced server-side
	// here, mirroring the DB CHECK constraint so the caller gets a clean
	// ErrInvalidInput rather than a raw constraint-violation error.
	PhoneNumber string
	Email       string
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
	Latitude       float64
	Longitude      float64
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
	}
}

// AddTrustedContact enforces the soft cap of 3 (ErrInvalidInput if exceeded)
// and requires at least one of phone_number/email.
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
	if phone == "" && emailAddr == "" {
		return TrustedContact{}, fmt.Errorf("auth: at least one of phone_number/email is required: %w", apperror.ErrInvalidInput)
	}
	// Format checks are an addition over the source, which validated these
	// two fields only in the Flutter client (manage_trusted_contacts_page's
	// Validators.phone/Validators.email) and accepted anything non-empty
	// server-side. Per docs/security-review-framework.md's "no
	// client-side-only validation, anywhere", the same rules are enforced
	// here — deliberately the frontend's exact rules, so nothing the
	// existing UI accepts is now rejected by the server.
	if phone != "" {
		if err := s.validate.PhoneNumber(phone); err != nil {
			return TrustedContact{}, err
		}
	}
	if emailAddr != "" {
		if err := s.validate.Email(emailAddr); err != nil {
			return TrustedContact{}, err
		}
	}

	count, err := s.trustedContacts.CountForUser(ctx, req.UserID)
	if err != nil {
		return TrustedContact{}, err
	}
	if count >= MaxTrustedContactsPerUser {
		return TrustedContact{}, fmt.Errorf(
			"auth: at most %d trusted contacts are allowed: %w", MaxTrustedContactsPerUser, apperror.ErrInvalidInput,
		)
	}

	contact, err := s.trustedContacts.Insert(ctx, req.UserID, name, phone, emailAddr)
	if err != nil {
		return TrustedContact{}, err
	}
	return trustedContactFromRepo(contact), nil
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
func (s *Service) TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error) {
	contextMessage := strings.TrimSpace(req.ContextMessage)
	if len(contextMessage) > MaxContextMessageLength {
		return TriggerSOSResult{}, fmt.Errorf("auth: context message is too long: %w", apperror.ErrInvalidInput)
	}
	// Garbage coordinates would otherwise flow straight into a real maps
	// link sent to a real trusted contact.
	if err := geo.ValidateLatLng(req.Latitude, req.Longitude); err != nil {
		return TriggerSOSResult{}, fmt.Errorf("auth: %v: %w", err, apperror.ErrInvalidInput)
	}

	contacts, err := s.trustedContacts.ListForUser(ctx, req.UserID)
	if err != nil {
		return TriggerSOSResult{}, err
	}
	if len(contacts) == 0 {
		return TriggerSOSResult{}, fmt.Errorf("auth: add a trusted contact before triggering SOS: %w", apperror.ErrInvalidInput)
	}

	user, err := s.users.GetByID(ctx, req.UserID)
	if err != nil {
		return TriggerSOSResult{}, err
	}

	message := AlertMessage(user.FullName, contextMessage, req.Latitude, req.Longitude)

	notified := 0
	for _, contact := range contacts {
		sent := false
		if contact.PhoneNumber != "" {
			if err := s.sendWithRetry(ctx, func() error {
				return s.sms.SendAlert(ctx, contact.PhoneNumber, message)
			}); err != nil {
				// Never logs the contact's number or the message body — an
				// SOS alert carries a real name, free-text context and
				// precise coordinates.
				s.logger.Error("send sos alert sms", "error", err)
			} else {
				sent = true
			}
		}
		if contact.Email != "" {
			if err := s.sendWithRetry(ctx, func() error {
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

	if err := s.sosEvents.Insert(ctx, repository.SOSEvent{
		UserID:           req.UserID,
		ContextMessage:   contextMessage,
		Latitude:         req.Latitude,
		Longitude:        req.Longitude,
		ContactsNotified: notified,
	}); err != nil {
		// The alerts themselves already went out — a failure to write the
		// audit row shouldn't make a real, already-sent emergency alert look
		// like it failed to the caller. Logged, not propagated: "business
		// action first, bookkeeping best-effort after".
		s.logger.Error("write sos event", "error", err)
	}

	return TriggerSOSResult{ContactsNotified: int32(notified)}, nil
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

// sendWithRetry runs send up to sendMaxAttempts times, giving an individual
// send a fighting chance against a transient failure before TriggerSOS's
// per-contact tolerance kicks in.
//
// DELIBERATE DEVIATION FROM THE SOURCE, reported rather than silent: the
// source additionally wraps each send in a per-channel circuit breaker
// (services/auth/internal/service/sos.go's smsBreaker/emailBreaker), so that
// once Twilio or Resend is genuinely down, subsequent contacts fail fast
// instead of each paying the full retry delay. ADR-001 §7 does not carry
// shared/breaker into this repo, and the phase prompt names the
// circuit-breaker pattern as out of scope, so it isn't rebuilt here. The
// consequence, worth knowing: during a full channel outage this call can
// take up to (contacts x channels x attempts x per-send timeout) instead of
// failing fast after the first few. See the completion report's Availability
// section.
func (s *Service) sendWithRetry(ctx context.Context, send func() error) error {
	var lastErr error
	for attempt := 1; attempt <= sendMaxAttempts; attempt++ {
		if err := send(); err == nil {
			return nil
		} else {
			lastErr = err
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
// caller's name, "may need help," the optional context message, and a maps
// link built from the coordinates. Exported for the module's tests.
func AlertMessage(callerName, contextMessage string, lat, lng float64) string {
	msg := fmt.Sprintf("%s may need help.", callerName)
	if contextMessage != "" {
		msg += " " + contextMessage
	}
	msg += fmt.Sprintf(" Location: https://maps.google.com/?q=%f,%f", lat, lng)
	return msg
}

func trustedContactFromRepo(c repository.TrustedContact) TrustedContact {
	return TrustedContact{
		ID:                   c.ID,
		Name:                 c.Name,
		PhoneNumber:          c.PhoneNumber,
		Email:                c.Email,
		CreatedAtUnixSeconds: c.CreatedAt.Unix(),
	}
}
