package auth

import (
	"fmt"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// safetyFeatureTrustFloor is the trust level required to add a trusted
// contact or trigger SOS (ADR-003) — the same floor required to join a
// meetup (the meetup module's requiredTrustLevelToJoin) and the same one
// participantIdentityFloor uses for "may this viewer see who is on a
// meetup."
//
// Trusted contacts and SOS exist to protect someone meeting a stranger.
// Joining a meetup already requires Level 2, so gating the safety tools at
// a LOWER bar than the thing they protect during would be backwards.
//
// These two RPCs previously required only `requireAuth`, so a guest account
// — Level 0, is_guest = true, no verification of any kind — could add a
// trusted contact and fire a real SMS/email alert at them.
const safetyFeatureTrustFloor = 2

// requireSafetyFeatureTrustLevel is the server-side gate, non-negotiable
// regardless of what the client's own UI already checks.
//
// callerTrustLevel comes from the JWT's trust_level claim, threaded through
// by the gateway — never a value the client sets directly. As with the
// meetup module's checkTrustLevel, the claim can only be stale LOW (a trust
// level only ever rises), so an unrefreshed token under-grants at worst,
// which is the safe direction for a gate to be wrong in.
//
// The `action` string is there so the rejection says which action was
// refused, rather than leaving the caller to guess which of the two hit the
// bar.
func requireSafetyFeatureTrustLevel(action string, callerTrustLevel int) error {
	if callerTrustLevel < safetyFeatureTrustFloor {
		return fmt.Errorf(
			"auth: %s requires trust level %d, caller has %d: %w",
			action, safetyFeatureTrustFloor, callerTrustLevel, apperror.ErrForbidden,
		)
	}
	return nil
}
