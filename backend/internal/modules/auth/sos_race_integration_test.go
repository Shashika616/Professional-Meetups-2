package auth_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// sosAlertsCaptured counts the SOS alerts (not invitations) texted so far.
func (h *harness) sosAlertsCaptured() int {
	h.smser.mu.Lock()
	defer h.smser.mu.Unlock()
	n := 0
	for _, m := range h.smser.alerts {
		if strings.Contains(m, "triggered an SOS alert") {
			n++
		}
	}
	return n
}

// The duplicate this fix exists for, against real Postgres with real
// concurrency: an SOS attempt and its automatic retry, carrying the same
// client_request_id, arriving together. The claim is the only thing standing
// between them, so it has to hold under -race with a barrier releasing every
// request at once — not just when they happen to arrive in turn.
//
// Before the fix every one of these sent its own round of alerts: the
// contacts got the same emergency once per request.
func TestTriggerSOS_ConcurrentRetriesOfOneSOSAlertOnce_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	owner := h.signUpByEmail(t, "sos-race@example.com")
	for i := 0; i < 2; i++ {
		if _, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
			CallerTrustLevel: 2, UserID: owner.UserID,
			Name: fmt.Sprintf("Contact %d", i), PhoneNumber: fmt.Sprintf("+9477555000%d", i),
		}); err != nil {
			t.Fatalf("AddTrustedContact: %v", err)
		}
	}

	const attempts = 6
	results := make([]auth.TriggerSOSResult, attempts)
	errs := race(t, attempts, func(i int) error {
		out, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{
			CallerTrustLevel: 2, UserID: owner.UserID,
			ClientRequestID: "one-emergency",
			Latitude:        sosCoord(6.9271), Longitude: sosCoord(79.8612),
		})
		results[i] = out
		return err
	})
	for i, err := range errs {
		if err != nil {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}

	if got := h.sosAlertsCaptured(); got != 2 {
		t.Errorf("SOS alerts texted = %d, want 2 (one per contact): %d concurrent "+
			"requests for ONE emergency each alerted the contacts", got, attempts)
	}
	for i, r := range results {
		if r.ContactsNotified != 2 {
			t.Errorf("attempt %d reported %d contacts notified, want 2", i, r.ContactsNotified)
		}
	}

	var rows int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM auth.sos_events WHERE user_id = $1 AND client_request_id = 'one-emergency'`,
		owner.UserID).Scan(&rows); err != nil {
		t.Fatalf("count sos_events: %v", err)
	}
	if rows != 1 {
		t.Errorf("sos_events rows for one emergency = %d, want 1", rows)
	}
}

// The contact cap moved into the insert's transaction because two additions
// racing could each count one contact and each insert, ending past it.
func TestAddTrustedContact_ConcurrentAdditionsRespectTheCap_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "contact-race@example.com")

	const attempts = 6
	errs := race(t, attempts, func(i int) error {
		_, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
			CallerTrustLevel: 2, UserID: owner.UserID,
			Name: fmt.Sprintf("Contact %d", i), PhoneNumber: fmt.Sprintf("+9477666000%d", i),
		})
		return err
	})

	added := 0
	for _, err := range errs {
		switch {
		case err == nil:
			added++
		case isSentinel(err, apperror.ErrInvalidInput):
		// The daily change limit (#81) refuses the 6th attempt; either
		// refusal is fine, the cap of 3 is what this test is about.
		case isSentinel(err, apperror.ErrRateLimited):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if added != 2 {
		t.Errorf("concurrent additions stored %d contacts, want exactly the cap of 2", added)
	}
	var stored int
	if err := h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.trusted_contacts WHERE user_id = $1`,
		owner.UserID).Scan(&stored); err != nil {
		t.Fatalf("count: %v", err)
	}
	if stored != 2 {
		t.Errorf("trusted_contacts rows = %d, want 2", stored)
	}
}

// Tracker #81: the hourly SOS limit used to live only in the gateway's
// memory, one count per instance. It is now counted in the claim, in
// Postgres, under the same per-user lock as the daily cap, so every
// instance shares it, and a retry carrying the same client_request_id is
// recognised before it is counted.
func TestTriggerSOS_HourlyLimitIsSharedAndIgnoresRetries_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "sos-hourly@example.com")
	if _, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		CallerTrustLevel: 2, UserID: owner.UserID, Name: "Contact", PhoneNumber: "+94775550099",
	}); err != nil {
		t.Fatal(err)
	}
	trigger := func(id string) error {
		_, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{CallerTrustLevel: 2, UserID: owner.UserID, ClientRequestID: id})
		return err
	}
	for i := 1; i <= 5; i++ {
		if err := trigger(fmt.Sprintf("hourly-%d", i)); err != nil {
			t.Fatalf("SOS %d: %v", i, err)
		}
		if err := trigger(fmt.Sprintf("hourly-%d", i)); err != nil { // its retry
			t.Fatalf("the retry of SOS %d: %v", i, err)
		}
	}
	err := trigger("hourly-6")
	if !isSentinel(err, apperror.ErrRateLimited) {
		t.Fatalf("the 6th SOS in an hour: %v, want rate limited", err)
	}
	if !strings.Contains(err.Error(), "emergency number") {
		t.Errorf("the refusal does not point to the emergency number: %v", err)
	}
}

// Plan 2.2: five trusted-contact adds or edits a day per account, counted in
// Postgres. The contacts never opted in, so changing numbers without end is
// the abuse this stops. The 6th, whichever kind, is refused.
func TestTrustedContactChangesAreCappedPerDay_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "contact-churn@example.com")
	c, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		CallerTrustLevel: 2, UserID: owner.UserID, Name: "Contact", PhoneNumber: "+94778880000",
	})
	if err != nil {
		t.Fatal(err)
	}
	edit := func(i int) error {
		_, err := h.svc.UpdateTrustedContact(ctx, auth.UpdateTrustedContactRequest{
			CallerTrustLevel: 2, UserID: owner.UserID, ContactID: c.ID,
			Name: fmt.Sprintf("Contact %d", i), PhoneNumber: fmt.Sprintf("+9477888000%d", i),
		})
		return err
	}
	for i := 1; i <= 4; i++ {
		if err := edit(i); err != nil {
			t.Fatalf("edit %d: %v", i, err)
		}
	}
	if err := edit(5); !isSentinel(err, apperror.ErrRateLimited) {
		t.Errorf("the 6th change today: %v, want rate limited", err)
	}
	var phone string
	_ = h.pool.QueryRow(ctx, `SELECT phone_number FROM auth.trusted_contacts WHERE id = $1`, c.ID).Scan(&phone)
	if phone != "+94778880004" {
		t.Errorf("stored %q; the refused edit must not have landed", phone)
	}
}

// Two contacts, one number: the unique index, in the two spellings a person
// would type.
func TestTrustedContactNumberIsUniquePerUser_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "contact-dupe@example.com")
	if _, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		CallerTrustLevel: 2, UserID: owner.UserID, Name: "One", PhoneNumber: "+94778880000",
	}); err != nil {
		t.Fatal(err)
	}
	_, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		CallerTrustLevel: 2, UserID: owner.UserID, Name: "Two", PhoneNumber: "077 888 0000",
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("the same number again: %v, want conflict", err)
	}
}

// D5: an account from before the cap keeps its three contacts, and SOS
// reaches the two oldest. Real ordering, real claim.
func TestTriggerSOS_ReachesOnlyTheTwoOldestOfThree_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "three-contacts@example.com")
	for i, age := range []string{"3 days", "2 days", "1 day"} {
		phone := fmt.Sprintf("+9477888100%d", i)
		if _, err := h.pool.Exec(ctx, `INSERT INTO auth.trusted_contacts (user_id, name, phone_number, phone_normalized, created_at)
			VALUES ($1, 'Contact', $2, $2, now() - $3::interval)`, owner.UserID, phone, age); err != nil {
			t.Fatal(err)
		}
	}
	result, err := h.svc.TriggerSOS(ctx, auth.TriggerSOSRequest{CallerTrustLevel: 2, UserID: owner.UserID})
	if err != nil {
		t.Fatal(err)
	}
	if result.ContactsNotified != 2 || h.sosAlertsCaptured() != 2 {
		t.Errorf("notified %d, captured %d; want 2", result.ContactsNotified, h.sosAlertsCaptured())
	}
}

// D1: three meetup shares a day per account.
func TestMeetupSharesAreCappedPerDay_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.signUpByEmail(t, "sharer@example.com")
	c, err := h.svc.AddTrustedContact(ctx, auth.AddTrustedContactRequest{
		CallerTrustLevel: 2, UserID: owner.UserID, Name: "Contact", PhoneNumber: "+94778881000",
	})
	if err != nil {
		t.Fatal(err)
	}
	share := func() ([]string, error) {
		return h.svc.NotifyMeetupShare(ctx, owner.UserID, auth.MeetupShare{
			ContactIDs: []string{c.ID}, LocationLabel: "Colombo", Latitude: 6.9271, Longitude: 79.8612,
			WindowStart: time.Now().Add(time.Hour), WindowEnd: time.Now().Add(2 * time.Hour),
		})
	}
	for i := 1; i <= 3; i++ {
		notified, err := share()
		if err != nil || len(notified) != 1 || notified[0] != c.ID {
			t.Fatalf("share %d: %v, %v", i, notified, err)
		}
	}
	if _, err := share(); !isSentinel(err, apperror.ErrRateLimited) {
		t.Errorf("the 4th share today: %v, want rate limited", err)
	}
}
