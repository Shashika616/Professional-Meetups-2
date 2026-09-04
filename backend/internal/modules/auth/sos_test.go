package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/sos"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// errAlertSendFailed simulates one contact's transport failing —
// TriggerSOS must tolerate this and still notify/count the others
// (ADR-026 §4).
var errAlertSendFailed = errors.New("simulated alert send failure")

// newTestServiceForSOS mirrors newTestServiceWithCompanies' shape — a
// dedicated helper for this file's tests, returning direct access to the
// trusted-contact/SOS-event fakes so tests can assert against them (ADR-026).
func newTestServiceForSOS(t *testing.T) (*service, *fakeUserRepository, *fakeTrustedContactRepository, *fakeSOSEventRepository, *fakeEmailSender, *fakeSmsSender) {
	t.Helper()
	users := newFakeUserRepository()
	trustedContacts := newFakeTrustedContactRepository()
	sosEvents := &fakeSOSEventRepository{}
	emailSender := &fakeEmailSender{}
	smsSender := &fakeSmsSender{}
	svc := New(Deps{
		Users:                   users,
		Identities:              newFakeUserIdentityRepository(),
		RefreshTokens:           newFakeRefreshTokenRepository(),
		VerificationCodes:       newFakeVerificationCodeRepository(),
		KnownCompanies:          newFakeKnownCompanyRepository(),
		UnverifiedCompanyClaims: &fakeUnverifiedCompanyClaimRepository{},
		TrustedContacts:         trustedContacts,
		SOSEvents:               sosEvents,
		Apple:                   &fakeIdentityProvider{},
		Google:                  &fakeIdentityProvider{},
		Email:                   emailSender,
		SMS:                     smsSender,
		WorkEmailHMACKey:        []byte("test-hmac-key"),
		Logger:                  slog.New(slog.DiscardHandler),
	}).(*service)
	return svc, users, trustedContacts, sosEvents, emailSender, smsSender
}

func TestAddTrustedContact_EnforcesSoftCapOfThree(t *testing.T) {
	svc, _, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()

	for i := 0; i < sos.MaxTrustedContactsPerUser; i++ {
		_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
			UserID: "user-1", Name: "Contact", PhoneNumber: "+94771234567",
		})
		if err != nil {
			t.Fatalf("AddTrustedContact() #%d error: %v", i, err)
		}
	}

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
		UserID: "user-1", Name: "One Too Many", PhoneNumber: "+94770000000",
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("4th AddTrustedContact() code = %v, want %v (soft cap)", err, apperror.ErrInvalidInput)
	}
}

func TestAddTrustedContact_RequiresPhoneOrEmail(t *testing.T) {
	svc, _, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{UserID: "user-1", Name: "No Contact Info"})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("AddTrustedContact() with neither phone nor email: code = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

func TestAddTrustedContact_RejectsEmptyName(t *testing.T) {
	svc, _, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{UserID: "user-1", Name: "  ", PhoneNumber: "+94771234567"})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("AddTrustedContact() with blank name: code = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

func TestListTrustedContacts_ScopedToCaller(t *testing.T) {
	svc, _, trustedContacts, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	if _, err := trustedContacts.Insert(ctx, "user-1", "Ada", "+94771234567", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}
	if _, err := trustedContacts.Insert(ctx, "user-2", "Grace", "+94779999999", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}

	resp, err := svc.ListTrustedContacts(ctx, "user-1")
	if err != nil {
		t.Fatalf("ListTrustedContacts() error: %v", err)
	}
	if len(resp) != 1 || resp[0].Name != "Ada" {
		t.Errorf("ListTrustedContacts(user-1) = %+v, want only Ada's contact", resp)
	}
}

// TestRemoveTrustedContact_RejectsNonOwnerCaller is the delete-authorization
// check — a caller must not be able to remove another user's contact by
// guessing its id.
func TestRemoveTrustedContact_RejectsNonOwnerCaller(t *testing.T) {
	svc, _, trustedContacts, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	contact, err := trustedContacts.Insert(ctx, "user-1", "Ada", "+94771234567", "")
	if err != nil {
		t.Fatalf("seed error: %v", err)
	}

	err = svc.RemoveTrustedContact(ctx, RemoveTrustedContactRequest{UserID: "someone-else", ContactID: contact.ID})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Fatalf("RemoveTrustedContact() by a non-owner: code = %v, want %v (Forbidden)", err, apperror.ErrForbidden)
	}

	// Confirm it's still there — the non-owner's call must not have deleted it.
	list, err := svc.ListTrustedContacts(ctx, "user-1")
	if err != nil {
		t.Fatalf("ListTrustedContacts() error: %v", err)
	}
	if len(list) != 1 {
		t.Errorf("contact was deleted by a non-owner's call, want it to still exist")
	}
}

func TestRemoveTrustedContact_OwnerSucceeds(t *testing.T) {
	svc, _, trustedContacts, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	contact, err := trustedContacts.Insert(ctx, "user-1", "Ada", "+94771234567", "")
	if err != nil {
		t.Fatalf("seed error: %v", err)
	}

	if err := svc.RemoveTrustedContact(ctx, RemoveTrustedContactRequest{UserID: "user-1", ContactID: contact.ID}); err != nil {
		t.Fatalf("RemoveTrustedContact() error: %v", err)
	}
	list, err := svc.ListTrustedContacts(ctx, "user-1")
	if err != nil {
		t.Fatalf("ListTrustedContacts() error: %v", err)
	}
	if len(list) != 0 {
		t.Errorf("contact still present after owner's own delete")
	}
}

func TestTriggerSOS_RejectsWithZeroContacts(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}

	_, err := svc.TriggerSOS(ctx, TriggerSOSRequest{UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("TriggerSOS() with zero contacts: code = %v, want %v", err, apperror.ErrInvalidInput)
	}
}

// TestTriggerSOS_RejectsInvalidLatLng (2026-08-31 round-2 hardening) —
// garbage coordinates previously flowed straight into a real maps link
// sent to a real trusted contact. Seeds a contact first so a rejection
// here is unambiguously about the coordinates, not the zero-contacts case
// TestTriggerSOS_RejectsWithZeroContacts already covers.
func TestTriggerSOS_RejectsInvalidLatLng(t *testing.T) {
	cases := []struct {
		name string
		lat  float64
		lng  float64
	}{
		{"NaN latitude", math.NaN(), 79.8},
		{"NaN longitude", 6.9, math.NaN()},
		{"latitude too high", 91, 79.8},
		{"latitude too low", -91, 79.8},
		{"longitude too high", 6.9, 181},
		{"longitude too low", 6.9, -181},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc, users, trustedContacts, _, _, _ := newTestServiceForSOS(t)
			ctx := context.Background()
			users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
			if _, err := trustedContacts.Insert(ctx, "user-1", "Phone Contact", "+94771234567", ""); err != nil {
				t.Fatalf("seed error: %v", err)
			}

			_, err := svc.TriggerSOS(ctx, TriggerSOSRequest{UserID: "user-1", Latitude: tc.lat, Longitude: tc.lng})
			if !errors.Is(err, apperror.ErrInvalidInput) {
				t.Errorf("TriggerSOS() with lat=%v lng=%v: code = %v, want %v", tc.lat, tc.lng, err, apperror.ErrInvalidInput)
			}
		})
	}
}

func TestTriggerSOS_SendsToAllContacts(t *testing.T) {
	svc, users, trustedContacts, sosEvents, emailSender, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Phone Contact", "+94771234567", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Email Contact", "", "friend@example.com"); err != nil {
		t.Fatalf("seed error: %v", err)
	}

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{
		UserID: "user-1", ContextMessage: "at the coffee meetup", Latitude: 6.9271, Longitude: 79.8612,
	})
	if err != nil {
		t.Fatalf("TriggerSOS() error: %v", err)
	}
	if resp.ContactsNotified != 2 {
		t.Errorf("contacts_notified = %d, want 2", resp.ContactsNotified)
	}
	if len(smsSender.alertsSent) != 1 || !strings.Contains(smsSender.alertsSent[0].message, "Ada Lovelace") {
		t.Errorf("sms alerts = %+v, want one containing the caller's name", smsSender.alertsSent)
	}
	if len(emailSender.alertsSent) != 1 || !strings.Contains(emailSender.alertsSent[0].message, "at the coffee meetup") {
		t.Errorf("email alerts = %+v, want one containing the context message", emailSender.alertsSent)
	}
	if len(sosEvents.events) != 1 || sosEvents.events[0].ContactsNotified != 2 {
		t.Errorf("sos_events = %+v, want one row with contacts_notified=2", sosEvents.events)
	}
}

// TestTriggerSOS_TolerantOfPartialSendFailure makes every SMS send fail
// (simulating one transport being down) while email keeps working — the
// call as a whole must still succeed, with contacts_notified reflecting
// only the sends that actually went through.
func TestTriggerSOS_TolerantOfPartialSendFailure(t *testing.T) {
	svc, users, trustedContacts, sosEvents, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Phone Contact (will fail)", "+94771111111", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Email Contact (will succeed)", "", "friend@example.com"); err != nil {
		t.Fatalf("seed error: %v", err)
	}
	smsSender.alertErr = errAlertSendFailed

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{UserID: "user-1", Latitude: 1, Longitude: 2})
	if err != nil {
		t.Fatalf("TriggerSOS() error: %v, want the call to succeed despite the SMS failure", err)
	}
	if resp.ContactsNotified != 1 {
		t.Errorf("contacts_notified = %d, want 1 (only the email contact succeeded)", resp.ContactsNotified)
	}
	if len(sosEvents.events) != 1 || sosEvents.events[0].ContactsNotified != 1 {
		t.Errorf("sos_events = %+v, want one row with contacts_notified=1", sosEvents.events)
	}
}

// TestTriggerSOS_RetriesTransientSendFailure (2026-08-31 round-3
// hardening) — TriggerSOS was the one send in this app with no retry at
// all; confirms a send that fails once but succeeds on the bounded retry
// still counts as notified, and that the retry actually happened (2 real
// attempts against the underlying sender), not just that the end result
// looks right by coincidence.
func TestTriggerSOS_RetriesTransientSendFailure(t *testing.T) {
	svc, users, trustedContacts, _, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Phone Contact", "+94771234567", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}
	smsSender.alertErr = errAlertSendFailed
	smsSender.alertFailFirstN = 1 // fails once (transient), succeeds on the retry

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
	if err != nil {
		t.Fatalf("TriggerSOS() error: %v", err)
	}
	if resp.ContactsNotified != 1 {
		t.Errorf("contacts_notified = %d, want 1 — the retry should have recovered the transient failure", resp.ContactsNotified)
	}
	if smsSender.alertCallCount != 2 {
		t.Errorf("real send attempts = %d, want exactly 2 (one failure, one successful retry) — not just 1 (no retry happened) or more (retried past success)", smsSender.alertCallCount)
	}
}

// TestTriggerSOS_SustainedChannelFailureStillAlertsEveryOtherChannel
// replaces the source's TestTriggerSOS_CircuitBreakerOpensAfterRepeatedFailures.
//
// That test asserted the circuit breaker's behavior: with 3 phone-only
// contacts and a sustained SMS failure, the source's breaker opens on the
// 5th recorded failure, so the 6th possible real send never happens
// (alertCallCount == 5, not 6). ADR-001 §7 does not carry shared/breaker
// into this repo and the phase prompt names the circuit-breaker pattern as
// out of scope, so that behavior is deliberately gone — see
// sos.sendWithRetry's own comment and the completion report's Availability
// section.
//
// What this asserts instead is what IS still true, and what actually
// matters for the caller: the bounded retry still runs (2 attempts per
// send, no more), a sustained failure on one channel doesn't abort the
// whole call, and every contact is still attempted rather than the loop
// giving up early. The full 6 attempts is the documented cost of dropping
// the breaker, pinned here so the change is visible rather than implicit.
func TestTriggerSOS_SustainedChannelFailureStillAlertsEveryOtherChannel(t *testing.T) {
	svc, users, trustedContacts, _, emailSender, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	for i := 0; i < sos.MaxTrustedContactsPerUser; i++ {
		// Each contact has BOTH channels, so a total SMS outage must still
		// leave every contact reachable by email.
		if _, err := trustedContacts.Insert(ctx, "user-1",
			fmt.Sprintf("Contact %d", i), fmt.Sprintf("+9477000000%d", i), fmt.Sprintf("c%d@example.com", i)); err != nil {
			t.Fatalf("seed contact %d: %v", i, err)
		}
	}
	smsSender.alertErr = errAlertSendFailed // sustained failure (alertFailFirstN left at 0)

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
	if err != nil {
		t.Fatalf("TriggerSOS() error: %v", err)
	}
	if resp.ContactsNotified != int32(sos.MaxTrustedContactsPerUser) {
		t.Errorf("contacts_notified = %d, want %d — a dead SMS channel must not stop the email alert going out",
			resp.ContactsNotified, sos.MaxTrustedContactsPerUser)
	}
	if len(emailSender.alertsSent) != sos.MaxTrustedContactsPerUser {
		t.Errorf("email alerts sent = %d, want %d", len(emailSender.alertsSent), sos.MaxTrustedContactsPerUser)
	}
	// 3 contacts x 2 attempts. Every failed send is retried exactly once and
	// no more; without the source's breaker there is no early exit, which is
	// the deliberate, reported trade-off.
	if want := sos.MaxTrustedContactsPerUser * 2; smsSender.alertCallCount != want {
		t.Errorf("real SMS send attempts = %d, want %d (2 bounded attempts per contact, no breaker short-circuit)",
			smsSender.alertCallCount, want)
	}
}

func TestTriggerSOS_WritesSosEventRow(t *testing.T) {
	svc, users, trustedContacts, sosEvents, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Contact", "+94771234567", ""); err != nil {
		t.Fatalf("seed error: %v", err)
	}

	if _, err := svc.TriggerSOS(ctx, TriggerSOSRequest{
		UserID: "user-1", ContextMessage: "help", Latitude: 6.9, Longitude: 79.8,
	}); err != nil {
		t.Fatalf("TriggerSOS() error: %v", err)
	}

	if len(sosEvents.events) != 1 {
		t.Fatalf("sos_events rows = %d, want 1", len(sosEvents.events))
	}
	got := sosEvents.events[0]
	if got.UserID != "user-1" || got.ContextMessage != "help" || got.Latitude != 6.9 || got.Longitude != 79.8 {
		t.Errorf("sos event = %+v, want the trigger's own values recorded", got)
	}
}
