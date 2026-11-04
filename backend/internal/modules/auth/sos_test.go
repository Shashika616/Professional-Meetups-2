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

// errAlertSendFailed simulates one contact's send failing — TriggerSOS must
// tolerate this and still notify and count the others (ADR-026 §4).
var errAlertSendFailed = errors.New("simulated alert send failure")

// newTestServiceForSOS returns a service with direct access to the
// trusted-contact and SOS-event fakes.
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

func coord(v float64) *float64 { return &v }

func trigger(svc *service, user string) (TriggerSOSResult, error) {
	return svc.TriggerSOS(context.Background(), TriggerSOSRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: user, Latitude: coord(6.9), Longitude: coord(79.8),
	})
}

func addContact(svc *service, user, name, phone string) (TrustedContact, error) {
	return svc.AddTrustedContact(context.Background(), AddTrustedContactRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: user, Name: name, PhoneNumber: phone,
	})
}

// ADR-013: adding a contact sends nothing at all. No invitation, no
// confirmation code.
func TestAddTrustedContactSendsNothing(t *testing.T) {
	svc, users, _, _, emailSender, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	c, err := addContact(svc, "user-1", "Amma", "077 123 4567")
	if err != nil {
		t.Fatal(err)
	}
	if c.PhoneNumber != "+94771234567" {
		t.Errorf("stored %q, want E.164", c.PhoneNumber)
	}
	if len(smsSender.alertsSent) != 0 || smsSender.alertCallCount != 0 || len(smsSender.sent) != 0 || len(emailSender.sent) != 0 {
		t.Error("adding a contact reached someone")
	}
	if _, err := svc.UpdateTrustedContact(context.Background(), UpdateTrustedContactRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ContactID: c.ID, Name: "Thaththa", PhoneNumber: "+94771234568",
	}); err != nil {
		t.Fatal(err)
	}
	if smsSender.alertCallCount != 0 {
		t.Error("editing a contact reached someone")
	}
}

func TestAddTrustedContact_EnforcesTheCapOfTwo(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	for i := 0; i < sos.MaxTrustedContactsPerUser; i++ {
		if _, err := addContact(svc, "user-1", fmt.Sprintf("Contact %d", i), fmt.Sprintf("+9477000000%d", i)); err != nil {
			t.Fatalf("contact %d: %v", i, err)
		}
	}
	if _, err := addContact(svc, "user-1", "One more", "+94770000099"); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("a 3rd contact: %v, want invalid input", err)
	}
}

func TestContactFieldsAreValidatedOnAddAndEdit(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	for name, c := range map[string]struct{ name, phone string }{
		"no phone":     {"Amma", ""},
		"bad phone":    {"Amma", "12345"},
		"blank name":   {"   ", "+94771234567"},
		"long name":    {strings.Repeat("a", 61), "+94771234567"},
		"line break":   {"Amma\nDad", "+94771234567"},
		"link in name": {"see https://x.co", "+94771234567"},
	} {
		if _, err := addContact(svc, "user-1", c.name, c.phone); !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("%s on add: %v, want invalid input", name, err)
		}
		if _, err := svc.UpdateTrustedContact(context.Background(), UpdateTrustedContactRequest{
			CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ContactID: "contact-1", Name: c.name, PhoneNumber: c.phone,
		}); !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("%s on edit: %v, want invalid input", name, err)
		}
	}
}

func TestUpdateTrustedContact_RejectsNonOwnerCaller(t *testing.T) {
	svc, users, contacts, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	c := contacts.seed("user-2", "Theirs", "+94771234567")
	_, err := svc.UpdateTrustedContact(context.Background(), UpdateTrustedContactRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ContactID: c.ID, Name: "Mine", PhoneNumber: "+94771234568",
	})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want forbidden", err)
	}
	if contacts.byID[c.ID].Name != "Theirs" {
		t.Error("another user's contact was changed")
	}
}

func TestUpdateTrustedContact_NeedsTheSafetyTrustLevel(t *testing.T) {
	svc, users, contacts, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	c := contacts.seed("user-1", "Amma", "+94771234567")
	_, err := svc.UpdateTrustedContact(context.Background(), UpdateTrustedContactRequest{
		CallerTrustLevel: 0, UserID: "user-1", ContactID: c.ID, Name: "Amma", PhoneNumber: "+94771234567",
	})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want forbidden", err)
	}
}

func TestListTrustedContacts_ScopedToCaller(t *testing.T) {
	svc, _, contacts, _, _, _ := newTestServiceForSOS(t)
	contacts.seed("user-1", "Mine", "+94771234567")
	contacts.seed("user-2", "Theirs", "+94771234568")
	got, err := svc.ListTrustedContacts(context.Background(), "user-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Name != "Mine" {
		t.Errorf("listed %+v", got)
	}
}

func TestRemoveTrustedContact_RejectsNonOwnerCaller(t *testing.T) {
	svc, _, contacts, _, _, _ := newTestServiceForSOS(t)
	c := contacts.seed("user-2", "Theirs", "+94771234567")
	err := svc.RemoveTrustedContact(context.Background(), RemoveTrustedContactRequest{UserID: "user-1", ContactID: c.ID})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want forbidden", err)
	}
	if _, still := contacts.byID[c.ID]; !still {
		t.Error("another user's contact was removed")
	}
}

func TestRemoveTrustedContact_OwnerSucceeds(t *testing.T) {
	svc, _, contacts, _, _, _ := newTestServiceForSOS(t)
	c := contacts.seed("user-1", "Mine", "+94771234567")
	if err := svc.RemoveTrustedContact(context.Background(), RemoveTrustedContactRequest{UserID: "user-1", ContactID: c.ID}); err != nil {
		t.Fatal(err)
	}
	if _, still := contacts.byID[c.ID]; still {
		t.Error("the contact is still there")
	}
}

func TestTriggerSOS_RejectsWithZeroContacts(t *testing.T) {
	svc, users, _, sosEvents, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	if _, err := trigger(svc, "user-1"); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("error = %v, want invalid input", err)
	}
	if len(sosEvents.events) != 0 {
		t.Error("an event was recorded for an alert that could not go")
	}
}

func TestTriggerSOS_RejectsInvalidLatLng(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Amma", "+94771234567")
	for name, c := range map[string][2]float64{
		"nan":          {math.NaN(), 79.8},
		"out of range": {91, 79.8},
		"null island":  {0, 0},
	} {
		_, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
			CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", Latitude: coord(c[0]), Longitude: coord(c[1]),
		})
		if !errors.Is(err, apperror.ErrInvalidInput) {
			t.Errorf("%s: %v, want invalid input", name, err)
		}
	}
	if smsSender.alertCallCount != 0 {
		t.Error("a bad coordinate reached a contact")
	}
}

// Plan 2.2 and D5: SMS only, and an account from before the cap that still
// has 3 contacts alerts the 2 oldest.
func TestTriggerSOS_AlertsOnlyTheTwoOldestContacts(t *testing.T) {
	svc, users, contacts, sosEvents, emailSender, smsSender := newTestServiceForSOS(t)
	users.byID["user-1"] = repository.User{ID: "user-1", FullName: "Ada Lovelace"}
	contacts.seed("user-1", "First", "+94770000001")
	contacts.seed("user-1", "Second", "+94770000002")
	contacts.seed("user-1", "Third", "+94770000003")

	resp, err := trigger(svc, "user-1")
	if err != nil {
		t.Fatal(err)
	}
	if resp.ContactsNotified != 2 {
		t.Errorf("notified %d, want 2", resp.ContactsNotified)
	}
	if len(smsSender.alertsSent) != 2 || smsSender.alertsSent[0].to != "+94770000001" || smsSender.alertsSent[1].to != "+94770000002" {
		t.Errorf("texted %+v, want the two oldest", smsSender.alertsSent)
	}
	if len(emailSender.alertsSent) != 0 {
		t.Error("an alert went by email")
	}
	if len(sosEvents.events) != 1 || sosEvents.events[0].ContactsNotified != 2 {
		t.Errorf("events %+v", sosEvents.events)
	}
	msg := smsSender.alertsSent[0].message
	if !strings.HasPrefix(msg, "Ada Lovelace triggered an SOS alert through TieHere") ||
		!strings.Contains(msg, "https://maps.google.com/?q=6.90000,79.80000") ||
		!strings.Contains(msg, "(Sri Lanka time)") {
		t.Errorf("message = %q", msg)
	}
}

// A repeat with the same request id alerts nobody twice.
func TestTriggerSOS_SameRequestIDAlertsOnce(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Amma", "+94771234567")
	for i := 0; i < 2; i++ {
		resp, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
			CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ClientRequestID: "one",
		})
		if err != nil || resp.ContactsNotified != 1 {
			t.Fatalf("attempt %d: %+v, %v", i, resp, err)
		}
	}
	if len(smsSender.alertsSent) != 1 {
		t.Errorf("%d alerts for one emergency", len(smsSender.alertsSent))
	}
}

// The alert goes out even when the user's row cannot be read: an emergency
// must not depend on a display name.
func TestTriggerSOS_GoesOutWithoutTheUsersName(t *testing.T) {
	svc, _, contacts, _, _, smsSender := newTestServiceForSOS(t)
	contacts.seed("user-1", "Amma", "+94771234567")
	if _, err := trigger(svc, "user-1"); err != nil {
		t.Fatal(err)
	}
	if len(smsSender.alertsSent) != 1 || !strings.HasPrefix(smsSender.alertsSent[0].message, "A TieHere member triggered") {
		t.Errorf("sent %+v", smsSender.alertsSent)
	}
}

func TestTriggerSOS_TolerantOfPartialSendFailure(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "First", "+94770000001")
	contacts.seed("user-1", "Second", "+94770000002")
	smsSender.alertErr = errAlertSendFailed
	smsSender.alertFailFirstN = 2 // the first contact fails on both tries
	resp, err := trigger(svc, "user-1")
	if err != nil {
		t.Fatalf("one contact's failure failed the call: %v", err)
	}
	if resp.ContactsNotified != 1 {
		t.Errorf("notified %d, want 1", resp.ContactsNotified)
	}
}

func TestTriggerSOS_RetriesTransientSendFailure(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Amma", "+94771234567")
	smsSender.alertErr = errAlertSendFailed
	smsSender.alertFailFirstN = 1
	resp, err := trigger(svc, "user-1")
	if err != nil {
		t.Fatal(err)
	}
	if resp.ContactsNotified != 1 || smsSender.alertCallCount != 2 {
		t.Errorf("notified %d after %d attempts, want 1 after 2", resp.ContactsNotified, smsSender.alertCallCount)
	}
}

// The breaker opens across calls and users: once Twilio is known to be down,
// the next emergency fails fast rather than paying the retry cost again.
func TestTriggerSOS_OpenBreakerFailsFastAcrossCalls(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	smsSender.alertErr = errAlertSendFailed
	for i := 0; i < 3; i++ {
		user := fmt.Sprintf("user-%d", i)
		seedUser(t, users, user)
		contacts.seed(user, "Amma", fmt.Sprintf("+9477000000%d", i))
		if _, err := trigger(svc, user); err != nil {
			t.Fatal(err)
		}
	}
	// Two attempts each for two users, one for the third, then open.
	if smsSender.alertCallCount != 5 {
		t.Errorf("real sends = %d, want 5: the breaker must stop the 6th", smsSender.alertCallCount)
	}
}

func TestTriggerSOS_RecordsTheLocationSource(t *testing.T) {
	svc, users, contacts, sosEvents, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Amma", "+94771234567")
	resp, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ContextMessage: "Coffee at 3pm",
	})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ContactsNotified != 1 {
		t.Errorf("notified %d", resp.ContactsNotified)
	}
	e := sosEvents.events[0]
	if e.Latitude != nil || e.LocationSource != "" || e.LocationCapturedAt != nil || e.ContextMessage != "Coffee at 3pm" {
		t.Errorf("event %+v", e)
	}
	if strings.Contains(smsSender.alertsSent[0].message, "Coffee at 3pm") {
		t.Error("client text reached the message")
	}
	if !strings.Contains(smsSender.alertsSent[0].message, "Current location unknown") {
		t.Errorf("message = %q", smsSender.alertsSent[0].message)
	}
}

func TestNotifyMeetupShare_OnlyTextsTheContactsTheCallerPicked(t *testing.T) {
	svc, users, contacts, _, emailSender, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	picked := contacts.seed("user-1", "Picked", "+94770000001")
	contacts.seed("user-1", "Other", "+94770000002")
	notified, err := svc.NotifyMeetupShare(context.Background(), "user-1", MeetupShare{
		ContactIDs: []string{picked.ID}, LocationLabel: "Cafe", Latitude: 6.9, Longitude: 79.8,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(notified) != 1 || notified[0] != picked.ID {
		t.Errorf("notified %v", notified)
	}
	if len(smsSender.alertsSent) != 1 || smsSender.alertsSent[0].to != "+94770000001" || len(emailSender.alertsSent) != 0 {
		t.Errorf("sent %+v", smsSender.alertsSent)
	}
}

func TestNotifyMeetupShare_RefusesContactsThatAreNotYours(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Mine", "+94770000001")
	theirs := contacts.seed("user-2", "Theirs", "+94770000002")
	_, err := svc.NotifyMeetupShare(context.Background(), "user-1", MeetupShare{ContactIDs: []string{theirs.ID}, Latitude: 6.9, Longitude: 79.8})
	if !errors.Is(err, apperror.ErrInvalidInput) || smsSender.alertCallCount != 0 {
		t.Errorf("error = %v after %d sends", err, smsSender.alertCallCount)
	}
}

func TestNotifyMeetupShare_RefusesAnEmptySelectionAndBadCoordinates(t *testing.T) {
	svc, users, contacts, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	c := contacts.seed("user-1", "Mine", "+94770000001")
	ctx := context.Background()
	if _, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{Latitude: 6.9, Longitude: 79.8}); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("no contacts: %v", err)
	}
	if _, err := svc.NotifyMeetupShare(ctx, "user-1", MeetupShare{ContactIDs: []string{c.ID}, Latitude: 91}); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("bad coordinates: %v", err)
	}
}

type fakeMeetupLookup struct {
	meetup sos.AlertMeetup
	found  bool
	err    error
}

func (f fakeMeetupLookup) ActiveMeetup(context.Context, string, time.Time) (sos.AlertMeetup, bool, error) {
	return f.meetup, f.found, f.err
}

// The meetup section comes through the port, and a failed lookup costs the
// section, never the alert.
func TestTriggerSOS_MeetupSection(t *testing.T) {
	for name, tc := range map[string]struct {
		lookup fakeMeetupLookup
		want   bool
	}{
		"on a meetup":      {fakeMeetupLookup{meetup: sos.AlertMeetup{Intent: "coffee", Label: "Colombo 07", Lat: 6.91234, Lng: 79.86543}, found: true}, true},
		"not on a meetup":  {fakeMeetupLookup{}, false},
		"the lookup fails": {fakeMeetupLookup{err: errors.New("down")}, false},
	} {
		t.Run(name, func(t *testing.T) {
			smsSender := &fakeSmsSender{}
			users, contacts := newFakeUserRepository(), newFakeTrustedContactRepository()
			seedUser(t, users, "user-1")
			contacts.seed("user-1", "Amma", "+94771234567")
			svc := New(Deps{
				Users: users, TrustedContacts: contacts, SOSEvents: &fakeSOSEventRepository{}, SMS: smsSender,
				SOSMeetups: tc.lookup, Logger: slog.New(slog.DiscardHandler),
			}).(*service)
			if _, err := trigger(svc, "user-1"); err != nil {
				t.Fatal(err)
			}
			if len(smsSender.alertsSent) != 1 {
				t.Fatalf("%d alerts", len(smsSender.alertsSent))
			}
			if got := strings.Contains(smsSender.alertsSent[0].message, "Coffee meetup - Colombo 07"); got != tc.want {
				t.Errorf("section present %v, want %v:\n%s", got, tc.want, smsSender.alertsSent[0].message)
			}
		})
	}
}

// One request id per SOS dialog: the user's Retry repeats it. When every
// send failed, that Retry has to really send, not report the same zero.
func TestTriggerSOS_RetryAfterReachingNobodySendsAgain(t *testing.T) {
	svc, users, contacts, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	contacts.seed("user-1", "Amma", "+94771234567")
	smsSender.alertErr = errAlertSendFailed
	smsSender.alertFailFirstN = 2
	again := func() int32 {
		resp, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
			CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1", ClientRequestID: "dialog-1",
		})
		if err != nil {
			t.Fatal(err)
		}
		return resp.ContactsNotified
	}
	if n := again(); n != 0 {
		t.Fatalf("first attempt notified %d", n)
	}
	if n := again(); n != 1 {
		t.Errorf("the retry notified %d, want 1", n)
	}
	if n := again(); n != 1 || len(smsSender.alertsSent) != 1 {
		t.Errorf("a repeat after success notified %d and sent %d", n, len(smsSender.alertsSent))
	}
}
