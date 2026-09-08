package meetup

import (
	"fmt"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The meetup trust gate, split in two by ADR-002 §4 (canonical decision:
// ADR-033 §5 in the sibling repo). Both mirror the frontend's IntentType
// getters exactly (frontend/lib/core/models/intent_type.dart) — noted
// explicitly as intentional duplication, same as the intent_type Postgres
// enum. A change to one side must be made on the other, in the same commit.
//
// # WHY TWO NUMBERS INSTEAD OF ONE
//
// Until ADR-002 a single requiredTrustLevel served both CreateMeetup and
// RequestToJoin. Hosting carries materially more responsibility than joining
// — a host owns a real-world gathering and decides who shows up — so the two
// actions no longer share a bar. Joining is unchanged; hosting is raised.
//
// Keeping them as two functions rather than one function with a mode
// parameter is deliberate: a bool argument at the call site
// (`checkTrustLevel(intent, level, true)`) reads as nothing at all, and the
// two call sites are the entire population. Named functions make the wrong
// one visibly wrong.

// requiredTrustLevelToJoin gates RequestToJoin. UNCHANGED from the
// pre-ADR-002 single value — Level 2 for the four ordinary intents,
// Level 4 for ride-share/dating.
func requiredTrustLevelToJoin(intent Intent) int {
	switch intent {
	case IntentRideShare, IntentDating:
		return 4
	default:
		return 2
	}
}

// requiredTrustLevelToHost gates CreateMeetup. RAISED to Level 3 for the four
// ordinary intents (ADR-002 §4) — hosting now additionally requires a
// registered company name and a verified work email, which is exactly what
// Level 3 means after ADR-002 §2.
//
// ride_share/dating stay at 4 for both actions: they are still deferred
// entirely (ADR-004), and this change deliberately builds nothing new for
// them as a side effect of touching this function.
func requiredTrustLevelToHost(intent Intent) int {
	switch intent {
	case IntentRideShare, IntentDating:
		return 4
	default:
		return 3
	}
}

// checkTrustLevel is the server-side trust gate, non-negotiable per
// backend/meetup-scheduling-PLAN.md Step B — called from CreateMeetup and
// RequestToJoin regardless of what the client's own UI already gates on.
// callerTrustLevel comes from the JWT's trust_level claim, threaded through
// by the gateway (never a value the client sets directly) — the claim can
// only be stale *low* (a user's trust level only ever increases, never
// decreases, so an unrefreshed token under-grants at worst, never
// over-grants), which is the safe direction for a gate to be wrong in.
//
// It takes the already-resolved required level rather than looking it up
// itself, since ADR-002 §4 made that lookup caller-dependent. The `action`
// string is there purely so the rejection says which bar was missed — a user
// told "requires level 3" when they are level 2 and can already join meetups
// needs to know it was the HOSTING bar, not a mysteriously moved one.
func checkTrustLevel(intent Intent, callerTrustLevel, required int, action string) error {
	if callerTrustLevel < required {
		return fmt.Errorf(
			"meetup: %s a %q meetup requires trust level %d, caller has %d: %w",
			action, intent, required, callerTrustLevel, apperror.ErrForbidden,
		)
	}
	return nil
}
