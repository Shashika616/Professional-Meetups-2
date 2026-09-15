package auth

import (
	"fmt"
	"regexp"
	"strings"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Server-side format validation for the two field shapes the source
// validated ONLY in the Flutter client.
//
// This is an addition over a 1:1 port, and a required one: the source's
// StartPhoneVerification/StartPersonalEmailVerification accept any non-empty
// target string, and AddTrustedContact accepts any non-empty phone/email —
// the actual shape rules live in frontend/lib/core/validation/validators.dart
// (Validators.phone / Validators.email), whose own header says "client-side
// checks exist only for UX speed. The server must re-validate every single
// input before acting on it." It didn't.
// docs/security-review-framework.md's "No client-side-only validation,
// anywhere" makes closing that the job of this port.
//
// The patterns below are copied from that Dart file verbatim rather than
// tightened into something stricter (e.g. real E.164), deliberately: the
// copied frontend/ must need zero changes to talk to this gateway, so the
// server must not reject anything the shipped UI already accepts. A stricter
// rule is a product decision, not a port decision.
var (
	// phonePattern is Validators._phone: an optional leading +, then 9-15
	// digits/spaces/hyphens.
	phonePattern = regexp.MustCompile(`^\+?[0-9\s-]{9,15}$`)
	// emailPattern is Validators._email.
	emailPattern = regexp.MustCompile(`^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$`)
)

// validatePhoneNumber rejects a phone number the shipped UI would itself
// have rejected. Returns a wrapped apperror.ErrInvalidInput, so it maps to
// the same 400 as every other validation failure in this module.
func validatePhoneNumber(value string) error {
	if !phonePattern.MatchString(strings.TrimSpace(value)) {
		return fmt.Errorf("auth: enter a valid phone number: %w", apperror.ErrInvalidInput)
	}
	return nil
}

// validateEmailShape rejects an address that isn't email-shaped. Shape only —
// the free-provider/role-based-mailbox rejection that corporate-email
// verification additionally applies is a separate, stronger rule and lives
// in isRejectedCorporateEmail (otp.go), exactly as in the source.
func validateEmailShape(value string) error {
	value = strings.TrimSpace(value)
	// RFC 5321's path limit. The regex alone accepted a 20 KB "address",
	// which was stored, then handed to Gmail, which refused it with a
	// protocol error that surfaced as a 500. A length cap makes that a 400
	// before any storage or delivery is attempted.
	if len(value) > maxEmailLength {
		return fmt.Errorf("auth: enter a valid email address: %w", apperror.ErrInvalidInput)
	}
	if !emailPattern.MatchString(value) {
		return fmt.Errorf("auth: enter a valid email address: %w", apperror.ErrInvalidInput)
	}
	return nil
}

// maxEmailLength is RFC 5321's maximum forward-path length.
const maxEmailLength = 254
