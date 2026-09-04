// Package sms sends OTP verification codes for phone verification
// (backend/PLAN.md's Level 2/3 addendum, Step C/D). Two implementations:
// LoggingSmsSender (default — logs the code instead of sending, used by
// local dev and every automated test) and TwilioSmsSender (real delivery
// via Twilio's plain Programmable Messaging API — deliberately not Twilio
// Verify, see ADR-012's 2026-08-17 correction: this backend keeps owning
// code generation/storage/verification for phone exactly like it already
// does for email, Twilio is just the SMS carrier). Which one main.go wires
// up is a config switch on whether the TWILIO_* env vars are all set — see
// cmd/server/main.go.
package sms

import "context"

// SmsSender sends a 6-digit verification code to to (E.164 format).
//
// SendAlert (ADR-026 §2) sends a free-text message — the SOS-trigger path's
// transport for a trusted contact's phone number. Reuses this same
// interface/client wiring rather than a new provider integration; a
// trusted contact is, by definition, not necessarily a registered app
// user, so this can't route through Notification Dispatch (ADR-022, which
// only reaches known device tokens).
type SmsSender interface {
	SendVerificationCode(ctx context.Context, to, code string) error
	SendAlert(ctx context.Context, to, message string) error
}

func bodyFor(code string) string {
	return "Your Professional Connections verification code is " + code + ". It expires in 10 minutes."
}
