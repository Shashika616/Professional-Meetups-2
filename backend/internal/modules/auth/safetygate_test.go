package auth

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// ADR-003: AddTrustedContact and TriggerSOS require trust level 2 — the same
// floor as joining a meetup. Before this gate, both required only being
// logged in, so a guest account (Level 0, no verification of any kind) could
// add a trusted contact and fire a real alert at them.
func TestSafetyFeatures_RequireTrustLevelTwo(t *testing.T) {
	ctx := context.Background()

	// Every level below the floor, not just 0: Level 1 is a real signed-up
	// account, and it is the level most likely to be waved through by a
	// future change that only remembers to exclude guests.
	for _, level := range []int{0, 1} {
		svc, users, _, sosEvents, _, _ := newTestServiceForSOS(t)
		seedUser(t, users, "user-1")

		_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
			CallerTrustLevel: level,
			UserID:           "user-1",
			Name:             "Contact",
			PhoneNumber:      "+94771234567",
		})
		if !errors.Is(err, apperror.ErrForbidden) {
			t.Errorf("AddTrustedContact at level %d: error = %v, want ErrForbidden", level, err)
		}

		_, err = svc.TriggerSOS(ctx, TriggerSOSRequest{
			CallerTrustLevel: level,
			UserID:           "user-1",
			Latitude:         6.9271,
			Longitude:        79.8612,
		})
		if !errors.Is(err, apperror.ErrForbidden) {
			t.Errorf("TriggerSOS at level %d: error = %v, want ErrForbidden", level, err)
		}

		// A rejection, not a silent no-op: nothing may reach the alerting
		// layer, or the guest-cleanup job's two-condition assumption
		// (ADR-003's Consequences) stops holding.
		if len(sosEvents.events) != 0 {
			t.Errorf("level %d wrote %d sos_event row(s), want none", level, len(sosEvents.events))
		}
	}
}

func TestSafetyFeatures_AllowedAtTheFloorAndAbove(t *testing.T) {
	ctx := context.Background()

	for _, level := range []int{safetyFeatureTrustFloor, safetyFeatureTrustFloor + 1} {
		svc, users, contacts, _, _, _ := newTestServiceForSOS(t)
		seedUser(t, users, "user-1")

		if _, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
			CallerTrustLevel: level,
			UserID:           "user-1",
			Name:             "Contact",
			PhoneNumber:      "+94771234567",
		}); err != nil {
			t.Fatalf("AddTrustedContact at level %d: %v", level, err)
		}

		stored, err := contacts.ListForUser(ctx, "user-1")
		if err != nil {
			t.Fatalf("ListForUser: %v", err)
		}
		if len(stored) != 1 {
			t.Errorf("level %d stored %d contact(s), want 1", level, len(stored))
		}

		if _, err := svc.TriggerSOS(ctx, TriggerSOSRequest{
			CallerTrustLevel: level,
			UserID:           "user-1",
			Latitude:         6.9271,
			Longitude:        79.8612,
		}); err != nil {
			t.Fatalf("TriggerSOS at level %d: %v", level, err)
		}
	}
}

// The gate must run BEFORE the sos subpackage's own validation, so a
// sub-floor caller cannot learn anything about the layer behind it — an
// invalid-input error where a forbidden one belongs would confirm the
// request got through.
func TestSafetyFeatures_GateRunsBeforeValidation(t *testing.T) {
	ctx := context.Background()
	svc, users, _, _, _, _ := newTestServiceForSOS(t)
	seedUser(t, users, "user-1")

	// Name is blank AND the caller is below the floor. The blank name would
	// be ErrInvalidInput if it were reached.
	_, err := svc.AddTrustedContact(ctx, AddTrustedContactRequest{
		CallerTrustLevel: 0,
		UserID:           "user-1",
		Name:             "   ",
	})
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("error = %v, want ErrForbidden — the gate must short-circuit validation", err)
	}
}
