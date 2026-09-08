package meetup

import (
	"errors"
	"strings"
	"testing"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The single TestRequiredTrustLevel / TestCheckTrustLevel pair that used to
// live here was SPLIT, not extended (ADR-002 §4). Keeping one table would
// have meant asserting one number for two actions that no longer share one —
// the join values are unchanged, the host values are not.

func TestRequiredTrustLevelToJoin(t *testing.T) {
	// Every value here is UNCHANGED from the pre-ADR-002 single function.
	// That is the assertion: joining did not get harder.
	tests := []struct {
		intent Intent
		want   int
	}{
		{IntentCoffee, 2},
		{IntentLunch, 2},
		{IntentNetworking, 2},
		{IntentMentorship, 2},
		{IntentRideShare, 4},
		{IntentDating, 4},
	}
	for _, tt := range tests {
		t.Run(string(tt.intent), func(t *testing.T) {
			if got := requiredTrustLevelToJoin(tt.intent); got != tt.want {
				t.Errorf("requiredTrustLevelToJoin(%s) = %d, want %d", tt.intent, got, tt.want)
			}
		})
	}
}

func TestRequiredTrustLevelToHost(t *testing.T) {
	// The four ordinary intents moved 2 -> 3. ride_share/dating stay at 4:
	// they are deferred entirely (ADR-004) and ADR-002 deliberately builds
	// nothing new for them.
	tests := []struct {
		intent Intent
		want   int
	}{
		{IntentCoffee, 3},
		{IntentLunch, 3},
		{IntentNetworking, 3},
		{IntentMentorship, 3},
		{IntentRideShare, 4},
		{IntentDating, 4},
	}
	for _, tt := range tests {
		t.Run(string(tt.intent), func(t *testing.T) {
			if got := requiredTrustLevelToHost(tt.intent); got != tt.want {
				t.Errorf("requiredTrustLevelToHost(%s) = %d, want %d", tt.intent, got, tt.want)
			}
		})
	}
}

// TestHostBarIsNeverBelowJoinBar is the invariant that makes the split
// coherent: if hosting were ever easier than joining for some intent, someone
// could create a meetup they could not themselves join. Asserted as a
// property over every intent rather than re-listing the numbers, so a future
// edit to either function cannot break it silently.
func TestHostBarIsNeverBelowJoinBar(t *testing.T) {
	for _, intent := range []Intent{IntentCoffee, IntentLunch, IntentNetworking, IntentMentorship, IntentRideShare, IntentDating} {
		join := requiredTrustLevelToJoin(intent)
		host := requiredTrustLevelToHost(intent)
		if host < join {
			t.Errorf("%s: host bar (%d) is BELOW the join bar (%d) — a host could create a meetup they cannot join", intent, host, join)
		}
	}
}

func TestCheckTrustLevel_JoinSide(t *testing.T) {
	tests := []struct {
		name       string
		intent     Intent
		trustLevel int
		wantErr    bool
	}{
		{"level 2 unlocks joining coffee", IntentCoffee, 2, false},
		{"level 3 unlocks joining coffee (above floor)", IntentCoffee, 3, false},
		{"level 1 does not unlock joining coffee", IntentCoffee, 1, true},
		{"level 0 (guest) does not unlock joining coffee", IntentCoffee, 0, true},
		{"level 4 unlocks joining ride_share", IntentRideShare, 4, false},
		{"level 2 does not unlock joining ride_share", IntentRideShare, 2, true},
		{"level 3 does not unlock joining dating", IntentDating, 3, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := checkTrustLevel(tt.intent, tt.trustLevel, requiredTrustLevelToJoin(tt.intent), "joining")
			assertGate(t, err, tt.wantErr, tt.intent, tt.trustLevel)
		})
	}
}

func TestCheckTrustLevel_HostSide(t *testing.T) {
	tests := []struct {
		name       string
		intent     Intent
		trustLevel int
		wantErr    bool
	}{
		// The behaviour change: Level 2 used to be enough to host coffee.
		{"level 2 NO LONGER unlocks hosting coffee", IntentCoffee, 2, true},
		{"level 3 unlocks hosting coffee", IntentCoffee, 3, false},
		{"level 4 unlocks hosting coffee (above floor)", IntentCoffee, 4, false},
		{"level 2 no longer unlocks hosting lunch", IntentLunch, 2, true},
		{"level 3 unlocks hosting networking", IntentNetworking, 3, false},
		{"level 3 unlocks hosting mentorship", IntentMentorship, 3, false},
		{"level 1 does not unlock hosting", IntentCoffee, 1, true},
		{"level 0 (guest) does not unlock hosting", IntentCoffee, 0, true},
		{"level 3 does not unlock hosting ride_share", IntentRideShare, 3, true},
		{"level 4 unlocks hosting ride_share", IntentRideShare, 4, false},
		{"level 3 does not unlock hosting dating", IntentDating, 3, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := checkTrustLevel(tt.intent, tt.trustLevel, requiredTrustLevelToHost(tt.intent), "hosting")
			assertGate(t, err, tt.wantErr, tt.intent, tt.trustLevel)
		})
	}
}

// TestCheckTrustLevel_RejectionNamesTheAction covers the one thing the
// `action` parameter exists for. A Level 2 user can already join coffee
// meetups; told only "requires trust level 3", they have no way to tell which
// bar moved. The message has to say it was hosting.
func TestCheckTrustLevel_RejectionNamesTheAction(t *testing.T) {
	err := checkTrustLevel(IntentCoffee, 2, requiredTrustLevelToHost(IntentCoffee), "hosting")
	if err == nil {
		t.Fatal("level 2 was allowed to host coffee")
	}
	if !strings.Contains(err.Error(), "hosting") {
		t.Errorf("rejection does not name the action: %q", err)
	}

	joinErr := checkTrustLevel(IntentCoffee, 1, requiredTrustLevelToJoin(IntentCoffee), "joining")
	if joinErr == nil {
		t.Fatal("level 1 was allowed to join coffee")
	}
	if !strings.Contains(joinErr.Error(), "joining") {
		t.Errorf("rejection does not name the action: %q", joinErr)
	}
}

func assertGate(t *testing.T, err error, wantErr bool, intent Intent, trustLevel int) {
	t.Helper()
	if wantErr && err == nil {
		t.Fatalf("checkTrustLevel(%s, %d) = nil, want an error", intent, trustLevel)
	}
	if !wantErr && err != nil {
		t.Fatalf("checkTrustLevel(%s, %d) = %v, want nil", intent, trustLevel, err)
	}
	if wantErr && !errors.Is(err, apperror.ErrForbidden) {
		t.Errorf("checkTrustLevel(%s, %d) error = %v, want it to wrap apperror.ErrForbidden", intent, trustLevel, err)
	}
}
