// Package email sends OTP verification codes for personal/corporate email
// verification and email+password signup (backend/PLAN.md's Level 2/3
// addendum, Step C/D; ADR-014 decision #2). Three implementations:
// LoggingEmailSender (default — logs the code instead of sending, used by
// local dev and every automated test), GmailSMTPEmailSender (real delivery
// via a personal Gmail account's SMTP relay — no sandbox-recipient
// restriction, useful for testing signup with arbitrary addresses), and
// ResendEmailSender (real delivery via Resend). Which one main.go wires up
// is a config switch — see cmd/server/main.go's newEmailSender.
package email

import "context"

// Purpose distinguishes personal vs. corporate email verification for copy
// purposes only — both share the same OTP mechanism (Step C/D). Deliberately
// its own type, not repository.VerificationPurpose, so this package doesn't
// depend on the persistence layer for a value it only ever uses to pick
// wording.
type Purpose string

const (
	PurposePersonalEmail  Purpose = "personal_email"
	PurposeCorporateEmail Purpose = "corporate_email"
)

// EmailSender sends a 6-digit verification code to to. Implementations
// never see anything beyond what's needed to send — no verification_codes
// row access, no user lookup.
//
// SendAlert (ADR-026 §2) sends a free-text message — the SOS-trigger path's
// transport for a trusted contact's email address, alongside SmsSender's
// equivalent for phone. Same reasoning: a trusted contact isn't necessarily
// a registered app user, so this can't route through Notification Dispatch
// (ADR-022), and reuses this same client wiring rather than a new provider.
type EmailSender interface {
	SendVerificationCode(ctx context.Context, to, code string, purpose Purpose) error
	SendAlert(ctx context.Context, to, message string) error
}

// sosAlertSubject is fixed, not caller-supplied — matches
// SendVerificationCode's own pattern (subjectAndBodyFor picks the subject
// internally too) and keeps SendAlert's signature identical across both
// sender interfaces (ADR-026 §2: "adding one new method... alongside the
// existing SendVerificationCode").
const sosAlertSubject = "Emergency alert — Professional Connections"

func subjectAndBodyFor(code string, purpose Purpose) (subject, body string) {
	switch purpose {
	case PurposeCorporateEmail:
		subject = "Verify your work email — Professional Connections"
	default:
		subject = "Verify your email — Professional Connections"
	}
	body = "Your verification code is " + code + ". It expires in 10 minutes. " +
		"If you didn't request this, you can ignore this email."
	return subject, body
}
