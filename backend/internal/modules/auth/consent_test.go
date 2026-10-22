package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/sos"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// #80. Before this, typing any number in as a "trusted contact" was enough
// to have the service text it — SOS alerts, meetup shares, all of it — with
// no say from the person at the other end.

func addContact(t *testing.T, svc *service, userID, phone string) (TrustedContact, error) {
	t.Helper()
	return svc.AddTrustedContact(context.Background(), AddTrustedContactRequest{
		CallerTrustLevel: safetyFeatureTrustFloor,
		UserID:           userID, Name: "Contact " + phone, PhoneNumber: phone,
	})
}

func TestAddTrustedContact_StartsPendingAndTextsOneLink(t *testing.T) {
	svc, users, _, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")

	contact, err := addContact(t, svc, "user-1", "+94771234567")
	if err != nil {
		t.Fatalf("AddTrustedContact: %v", err)
	}
	if contact.Status != sos.StatusPending {
		t.Errorf("new contact status = %q, want %q", contact.Status, sos.StatusPending)
	}
	if len(smsSender.alertsSent) != 1 {
		t.Fatalf("texts sent = %d, want exactly one invitation", len(smsSender.alertsSent))
	}
	invite := smsSender.alertsSent[0]
	if invite.to != "+94771234567" || !strings.Contains(invite.message, "/c/") {
		t.Errorf("invitation = %+v, want a link texted to the contact", invite)
	}
}

func TestTriggerSOS_DoesNotAlertAContactWhoHasNotAgreed(t *testing.T) {
	svc, users, _, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	if _, err := addContact(t, svc, "user-1", "+94771234567"); err != nil {
		t.Fatalf("AddTrustedContact: %v", err)
	}
	smsSender.alertsSent = nil

	_, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1",
		Latitude: coord(6.9), Longitude: coord(79.8),
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("SOS with only a pending contact: err = %v, want ErrInvalidInput", err)
	}
	if !strings.Contains(fmt.Sprint(err), "emergency number") {
		t.Errorf("the error does not tell the user to call for help: %v", err)
	}
	if len(smsSender.alertsSent) != 0 {
		t.Errorf("a contact who never agreed was texted: %+v", smsSender.alertsSent)
	}
}

func TestTriggerSOS_AlertsTheContactOnceTheyAgree(t *testing.T) {
	svc, users, _, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	if _, err := addContact(t, svc, "user-1", "+94771234567"); err != nil {
		t.Fatalf("AddTrustedContact: %v", err)
	}
	confirmFromInvite(t, svc, smsSender)
	smsSender.alertsSent = nil

	resp, err := svc.TriggerSOS(context.Background(), TriggerSOSRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1",
		Latitude: coord(6.9), Longitude: coord(79.8),
	})
	if err != nil {
		t.Fatalf("TriggerSOS: %v", err)
	}
	if resp.ContactsNotified != 1 || len(smsSender.alertsSent) != 1 {
		t.Errorf("notified %d, texts %d; want the confirmed contact alerted once",
			resp.ContactsNotified, len(smsSender.alertsSent))
	}
}

// The link is the contact's consent; it must work once and only once.
func TestConfirmTrustedContact_IsSingleUseAndRejectsUnknownTokens(t *testing.T) {
	svc, users, _, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	if _, err := addContact(t, svc, "user-1", "+94771234567"); err != nil {
		t.Fatalf("AddTrustedContact: %v", err)
	}
	confirmFromInvite(t, svc, smsSender)

	msg := smsSender.alertsSent[0].message
	token := msg[strings.Index(msg, "/c/")+3:]
	token = token[:strings.IndexAny(token, " )")]

	if _, err := svc.ConfirmTrustedContact(context.Background(), token); !errors.Is(err, apperror.ErrNotFound) {
		t.Errorf("reusing a confirmation link: err = %v, want ErrNotFound", err)
	}
	for _, bad := range []string{"", "not-a-token", strings.Repeat("x", 500)} {
		if _, err := svc.ConfirmTrustedContact(context.Background(), bad); !errors.Is(err, apperror.ErrNotFound) {
			t.Errorf("token %q: err = %v, want ErrNotFound", bad, err)
		}
	}
}

// Removing and re-adding a contact sends a new text each time, so without a
// cap it is an unlimited way to text a stranger at this project's expense.
func TestAddTrustedContact_CapsInvitationsToOneNumber(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	seedUser(t, users, "user-1")

	for i := 0; i < 3; i++ {
		c, err := addContact(t, svc, "user-1", "+94771234567")
		if err != nil {
			t.Fatalf("invitation %d: %v", i+1, err)
		}
		if err := svc.RemoveTrustedContact(ctx, RemoveTrustedContactRequest{UserID: "user-1", ContactID: c.ID}); err != nil {
			t.Fatalf("remove: %v", err)
		}
	}
	if _, err := addContact(t, svc, "user-1", "+94 77 123 4567"); !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("4th invitation to one number (spelled differently): err = %v, want ErrRateLimited", err)
	}
}

func TestAddTrustedContact_CapsInvitationsPerUser(t *testing.T) {
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	seedUser(t, users, "user-1")

	for i := 0; i < 5; i++ {
		c, err := addContact(t, svc, "user-1", fmt.Sprintf("+9477000000%d", i))
		if err != nil {
			t.Fatalf("invitation %d: %v", i+1, err)
		}
		if err := svc.RemoveTrustedContact(ctx, RemoveTrustedContactRequest{UserID: "user-1", ContactID: c.ID}); err != nil {
			t.Fatalf("remove: %v", err)
		}
	}
	if _, err := addContact(t, svc, "user-1", "+94770000009"); !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("6th invitation in a day: err = %v, want ErrRateLimited", err)
	}
}

// The retry duplicate. The app sends one client_request_id for an attempt
// and its automatic retry; the retry must report the first attempt's
// outcome and text nobody.
func TestTriggerSOS_ARetryWithTheSameRequestIDAlertsNobodyAgain(t *testing.T) {
	svc, users, trustedContacts, _, _, smsSender := newTestServiceForSOS(t)
	ctx := context.Background()
	seedUser(t, users, "user-1")
	for i := 0; i < 2; i++ {
		if _, err := trustedContacts.Insert(ctx, "user-1", "C", fmt.Sprintf("+9477100000%d", i), ""); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
	req := TriggerSOSRequest{
		CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1",
		Latitude: coord(6.9), Longitude: coord(79.8), ClientRequestID: "req-abc-123",
	}

	first, err := svc.TriggerSOS(ctx, req)
	if err != nil {
		t.Fatalf("first attempt: %v", err)
	}
	retry, err := svc.TriggerSOS(ctx, req)
	if err != nil {
		t.Fatalf("retry: %v", err)
	}

	if len(smsSender.alertsSent) != 2 {
		t.Errorf("texts sent = %d, want 2: the retry alerted everyone a second time", len(smsSender.alertsSent))
	}
	if retry.ContactsNotified != first.ContactsNotified {
		t.Errorf("retry reported %d, want the first attempt's %d", retry.ContactsNotified, first.ContactsNotified)
	}

	// A user-initiated retry is a new request id, and is a new alert.
	req.ClientRequestID = "req-def-456"
	if _, err := svc.TriggerSOS(ctx, req); err != nil {
		t.Fatalf("new request: %v", err)
	}
	if len(smsSender.alertsSent) != 4 {
		t.Errorf("texts sent = %d, want 4 after a genuinely new SOS", len(smsSender.alertsSent))
	}
}

func TestTriggerSOS_IsCappedPerDay(t *testing.T) {
	svc, users, trustedContacts, _, _, _ := newTestServiceForSOS(t)
	ctx := context.Background()
	seedUser(t, users, "user-1")
	if _, err := trustedContacts.Insert(ctx, "user-1", "C", "+94771000000", ""); err != nil {
		t.Fatalf("seed: %v", err)
	}
	req := TriggerSOSRequest{CallerTrustLevel: safetyFeatureTrustFloor, UserID: "user-1"}
	for i := 0; i < 10; i++ {
		if _, err := svc.TriggerSOS(ctx, req); err != nil {
			t.Fatalf("SOS %d: %v", i+1, err)
		}
	}
	_, err := svc.TriggerSOS(ctx, req)
	if !errors.Is(err, apperror.ErrRateLimited) {
		t.Errorf("11th SOS today: err = %v, want ErrRateLimited", err)
	}
	if !strings.Contains(fmt.Sprint(err), "emergency number") {
		t.Errorf("the cap message does not tell the user to call for help: %v", err)
	}
}

func TestNotifyMeetupShare_SkipsContactsWhoHaveNotAgreed(t *testing.T) {
	svc, users, _, _, _, smsSender := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")
	pending, err := addContact(t, svc, "user-1", "+94771234567")
	if err != nil {
		t.Fatalf("AddTrustedContact: %v", err)
	}
	smsSender.alertsSent = nil

	_, err = svc.NotifyMeetupShare(context.Background(), "user-1", MeetupShare{
		ContactIDs: []string{pending.ID}, LocationLabel: "Cafe", Latitude: 6.9, Longitude: 79.8,
	})
	if !errors.Is(err, apperror.ErrInvalidInput) {
		t.Errorf("share to a pending contact: err = %v, want ErrInvalidInput", err)
	}
	if len(smsSender.alertsSent) != 0 {
		t.Errorf("a contact who never agreed was texted about a meetup")
	}
}
