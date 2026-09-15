package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"

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
			CallerTrustLevel: safetyFeatureTrustFloor,
			UserID:           "user-1", Name: "Contact", PhoneNumber: "+94771234567",
		})
		if err != nil {
			t.Fatalf("AddTrustedContact() #%d error: %v", i, err)
		}
	}

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
		CallerTrustLevel: safetyFeatureTrustFloor,
		UserID:           "user-1", Name: "One Too Many", PhoneNumber: "+94770000000",
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("4th AddTrustedContact() code = %v, want %v (soft cap)", err, apperror.ErrInvalidInput)
	}
}

func TestAddTrustedContact_RequiresPhone(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	ctx := context.Background()

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Name: "No Contact Info"})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("AddTrustedContact() with neither phone nor email: code = %v, want %v", err, apperror.ErrInvalidInput)
	}

	// An email alone is not enough: an SOS needs someone reachable now.
	_, err = svc.AddTrustedContact(ctx, AddTrustedContactRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Name: "Email Only", Email: "friend@example.com"})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("AddTrustedContact() with email only: code = %v, want %v", err, apperror.ErrInvalidInput)
	}

	// Phone alone is the minimum; email is the optional extra channel.
	if _, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Name: "Phone Only", PhoneNumber: "+94771234567"}); err != nil {
		t.Fatalf("AddTrustedContact() with phone only: %v, want nil", err)
	}
	if _, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Name: "Both", PhoneNumber: "+94771234568", Email: "friend@example.com"}); err != nil {
		t.Fatalf("AddTrustedContact() with phone and email: %v, want nil", err)
	}
}

func TestAddTrustedContact_RejectsEmptyName(t *testing.T) {
	svc, _, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()

	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Name: "  ", PhoneNumber: "+94771234567"})
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

	_, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
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

			_, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: tc.lat, Longitude: tc.lng})
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
		CallerTrustLevel: safetyFeatureTrustFloor,
		UserID:           "user-1", ContextMessage: "at the coffee meetup", Latitude: 6.9271, Longitude: 79.8612,
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

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 1, Longitude: 2})
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

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
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

// TestTriggerSOS_SustainedChannelFailureStillAlertsEveryOtherChannel: a
// total outage on one channel must not stop the other channel reaching every
// contact. This is the caller-visible half of the resilience story; the
// breaker's own mechanics are the two tests below it.
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

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
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
	// The email channel never failed, so ITS breaker must still be closed —
	// one channel's outage must not trip the other's.
	if len(emailSender.alertsSent) != sos.MaxTrustedContactsPerUser {
		t.Errorf("email sends = %d, want %d — the email breaker must be unaffected by the SMS outage",
			len(emailSender.alertsSent), sos.MaxTrustedContactsPerUser)
	}
}

// TestTriggerSOS_CircuitBreakerOpensAfterRepeatedFailures restores the
// source's own breaker test (services/auth/internal/service/sos_test.go),
// per ADR-001's 2026-09-04 correction.
//
// 3 phone-only contacts, SMS failing sustained. Each contact's send gets up
// to sendMaxAttempts (2) real attempts, so 3 x 2 = 6 real sends if the
// breaker never intervened. The threshold is 5, so the breaker opens exactly
// on the 3rd contact's 1st attempt (2+2+1 = 5 recorded failures); that
// contact's 2nd attempt must then short-circuit via breaker.ErrOpen without
// ever reaching the real sender — asserted via the call count, not inferred
// from the response.
func TestTriggerSOS_CircuitBreakerOpensAfterRepeatedFailures(t *testing.T) {
	svc, users, trustedContacts, _, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	for i := 0; i < sos.MaxTrustedContactsPerUser; i++ {
		if _, err := trustedContacts.Insert(ctx, "user-1", fmt.Sprintf("Contact %d", i), fmt.Sprintf("+9477000000%d", i), ""); err != nil {
			t.Fatalf("seed contact %d: %v", i, err)
		}
	}
	smsSender.alertErr = errAlertSendFailed // sustained failure

	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 6.9, Longitude: 79.8})
	if err != nil {
		t.Fatalf("TriggerSOS() error: %v", err)
	}
	if resp.ContactsNotified != 0 {
		t.Errorf("contacts_notified = %d, want 0 (every send failed)", resp.ContactsNotified)
	}
	if smsSender.alertCallCount != 5 {
		t.Errorf("real send attempts = %d, want exactly 5 — the breaker opening on the 5th recorded failure must prevent a 6th real attempt",
			smsSender.alertCallCount)
	}
}

// TestTriggerSOS_OpenBreakerFailsFastAcrossCallsAndSpareTheOtherChannel is
// the property the breaker exists for and that a per-call breaker could
// never provide: the failure memory persists ACROSS TriggerSOS calls, from
// DIFFERENT users. Once Twilio is known to be down, the next person's
// emergency doesn't pay the retry-and-timeout cost again — and their email
// alert still goes out.
func TestTriggerSOS_OpenBreakerFailsFastAcrossCallsAndSpareTheOtherChannel(t *testing.T) {
	svc, users, trustedContacts, _, emailSender, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	users.byID["user-2"] = repository.User{ID: "user-2", FullName: "Grace Hopper"}
	for i := 0; i < sos.MaxTrustedContactsPerUser; i++ {
		if _, err := trustedContacts.Insert(ctx, "user-1", fmt.Sprintf("Contact %d", i), fmt.Sprintf("+9477000000%d", i), ""); err != nil {
			t.Fatalf("seed user-1 contact %d: %v", i, err)
		}
	}
	// A different user, with both channels.
	if _, err := trustedContacts.Insert(ctx, "user-2", "Second user's contact", "+94779999999", "second@example.com"); err != nil {
		t.Fatalf("seed user-2 contact: %v", err)
	}
	smsSender.alertErr = errAlertSendFailed

	// First call trips the SMS breaker open (5 recorded failures).
	if _, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: 6.9, Longitude: 79.8}); err != nil {
		t.Fatalf("first TriggerSOS() error: %v", err)
	}
	callsAfterFirst := smsSender.alertCallCount
	if callsAfterFirst != 5 {
		t.Fatalf("SMS attempts after the first call = %d, want 5 (breaker should already be open)", callsAfterFirst)
	}

	// A DIFFERENT user's emergency, moments later. The SMS channel is already
	// known to be down, so it must fail fast — zero further real sends, and
	// no retry delay paid.
	start := time.Now()
	resp, err := svc.TriggerSOS(ctx, TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-2", Latitude: 6.9, Longitude: 79.8})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("second TriggerSOS() error: %v", err)
	}

	if smsSender.alertCallCount != callsAfterFirst {
		t.Errorf("SMS attempts after the second call = %d, want %d — an open breaker must not reach the real sender at all",
			smsSender.alertCallCount, callsAfterFirst)
	}
	// With the breaker open there is no retry delay: sendRetryDelay is 500ms,
	// so anything near that means it retried instead of failing fast.
	if elapsed >= 500*time.Millisecond {
		t.Errorf("second call took %v — an open breaker must fail fast, not pay the %v retry delay", elapsed, 500*time.Millisecond)
	}
	// And the healthy channel still delivered, so the caller is still helped.
	if resp.ContactsNotified != 1 {
		t.Errorf("contacts_notified = %d, want 1 — the email channel is healthy and must still alert the contact", resp.ContactsNotified)
	}
	if len(emailSender.alertsSent) != 1 {
		t.Errorf("email alerts sent = %d, want 1 — one channel's open breaker must not affect the other's", len(emailSender.alertsSent))
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
		CallerTrustLevel: safetyFeatureTrustFloor,
		UserID:           "user-1", ContextMessage: "help", Latitude: 6.9, Longitude: 79.8,
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

// --- NotifyMeetupShare -----------------------------------------------------
//
// The planned, non-emergency counterpart of TriggerSOS: the user picks WHO to
// tell, before anything has gone wrong. These tests are mostly about what a
// modified client cannot do, because this sends real text messages.

func TestNotifyMeetupShare_OnlyTextsTheContactsTheCallerPicked(t *testing.T) {
	svc, users, trustedContacts, _, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}

	picked, err := trustedContacts.Insert(ctx, "user-1", "Amma", "+94771111111", "")
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Friend", "+94772222222", ""); err != nil {
		t.Fatalf("seed: %v", err)
	}

	notified, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{
		ContactIDs:    []string{picked.ID},
		LocationLabel: "Colombo Fort Cafe",
		Latitude:      6.9271,
		Longitude:     79.8612,
		WindowStart:   time.Date(2026, 9, 8, 15, 0, 0, 0, time.UTC),
		WindowEnd:     time.Date(2026, 9, 8, 16, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatalf("NotifyMeetupShare: %v", err)
	}
	if notified != 1 {
		t.Errorf("notified = %d, want 1 — only the picked contact", notified)
	}
	if got := len(smsSender.alertsSent); got != 1 {
		t.Fatalf("sent %d messages, want 1 — the unpicked contact must not be texted", got)
	}
	if smsSender.alertsSent[0].to != "+94771111111" {
		t.Errorf("texted %q, want the picked contact", smsSender.alertsSent[0].to)
	}
}

func TestNotifyMeetupShare_RejectsContactsThatAreNotYours(t *testing.T) {
	svc, users, trustedContacts, _, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	if _, err := trustedContacts.Insert(ctx, "user-1", "Amma", "+94771111111", ""); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// A guessed id belonging to somebody else. Without the intersection
	// against the caller's own list this is a way to text a stranger.
	_, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{
		ContactIDs:  []string{"not-this-users-contact"},
		Latitude:    6.9271,
		Longitude:   79.8612,
		WindowStart: time.Now(),
		WindowEnd:   time.Now().Add(time.Hour),
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("error = %v, want ErrInvalidInput", err)
	}
	if len(smsSender.alertsSent) != 0 {
		t.Error("a message was sent to a contact the caller does not own")
	}
}

func TestNotifyMeetupShare_RejectsAnEmptySelectionAndBadCoordinates(t *testing.T) {
	svc, users, trustedContacts, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	c, _ := trustedContacts.Insert(ctx, "user-1", "Amma", "+94771111111", "")

	if _, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{
		Latitude: 6.9, Longitude: 79.8,
	}); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("empty selection: error = %v, want ErrInvalidInput", err)
	}

	// Garbage coordinates would otherwise flow into a real maps link.
	if _, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{
		ContactIDs: []string{c.ID}, Latitude: math.NaN(), Longitude: 79.8,
	}); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("NaN latitude: error = %v, want ErrInvalidInput", err)
	}
}

// TestMeetupShareMessage_StatesAWindowAndPlaceNotLiveTracking pins the
// wording. The app does not track anyone — it sends a static pin at the
// meetup's own coordinates — and a message implying otherwise would be a
// safety promise the product cannot keep.
func TestMeetupShareMessage_StatesAWindowAndPlaceNotLiveTracking(t *testing.T) {
	msg := sos.MeetupShareMessage(
		"Ada Lovelace", "Colombo Fort Cafe", 6.9271, 79.8612,
		time.Date(2026, 9, 8, 15, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 8, 16, 0, 0, 0, time.UTC),
	)

	for _, want := range []string{"Ada Lovelace", "Colombo Fort Cafe", "maps.google.com"} {
		if !strings.Contains(msg, want) {
			t.Errorf("message %q is missing %q", msg, want)
		}
	}
	for _, forbidden := range []string{"live", "Live", "track", "Track"} {
		if strings.Contains(msg, forbidden) {
			t.Errorf("message %q claims %q — the app sends a static pin, not tracking", msg, forbidden)
		}
	}
	// Not an emergency: it must not borrow SOS's alarm wording.
	if strings.Contains(msg, "may need help") {
		t.Errorf("message %q reads as an SOS alert", msg)
	}
}
