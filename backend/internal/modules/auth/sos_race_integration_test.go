package auth_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// sosAlertsCaptured counts the SOS alerts (not invitations) texted so far.
func (h *harness) sosAlertsCaptured() int {
	h.smser.mu.Lock()
	defer h.smser.mu.Unlock()
	n := 0
	for _, m := range h.smser.alerts {
		if strings.Contains(m, "may need help") {
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
	if n := h.confirmAllInvites(t); n != 2 {
		t.Fatalf("confirmed %d contacts, want 2", n)
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
// racing could each count two contacts and each insert, ending at four.
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
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if added != 3 {
		t.Errorf("concurrent additions stored %d contacts, want exactly the cap of 3", added)
	}
	var stored int
	if err := h.pool.QueryRow(ctx, `SELECT count(*) FROM auth.trusted_contacts WHERE user_id = $1`,
		owner.UserID).Scan(&stored); err != nil {
		t.Fatalf("count: %v", err)
	}
	if stored != 3 {
		t.Errorf("trusted_contacts rows = %d, want 3", stored)
	}
}
