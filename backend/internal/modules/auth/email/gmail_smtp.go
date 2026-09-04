package email

import (
	"context"
	"fmt"
	"net/smtp"
)

// gmailSMTPAddr is Gmail's SMTP relay — STARTTLS on 587, not the legacy
// implicit-TLS port 465.
const gmailSMTPAddr = "smtp.gmail.com:587"

// GmailSMTPEmailSender sends real verification emails through a personal
// Gmail account's SMTP relay — a lower-friction alternative to Resend for
// local testing: a Gmail account can send to any recipient immediately,
// with none of Resend's sandbox-account restriction (limited to the
// account owner's own inbox until a domain is verified there).
//
// appPassword must be a Google App Password (Google Account -> Security ->
// 2-Step Verification -> App passwords), never the account's real login
// password — Gmail's SMTP AUTH rejects the real password outright once
// 2-Step Verification is enabled, which it is by default on any account
// created in the last several years.
type GmailSMTPEmailSender struct {
	address     string
	appPassword string
}

// NewGmailSMTPEmailSender constructs a GmailSMTPEmailSender. address is the
// full Gmail address, used as both the SMTP username and the From address.
func NewGmailSMTPEmailSender(address, appPassword string) *GmailSMTPEmailSender {
	return &GmailSMTPEmailSender{address: address, appPassword: appPassword}
}

func (s *GmailSMTPEmailSender) SendVerificationCode(_ context.Context, to, code string, purpose Purpose) error {
	subject, body := subjectAndBodyFor(code, purpose)
	return s.send(to, subject, body)
}

// SendAlert (ADR-026 §2) reuses the exact same Gmail SMTP wiring as
// SendVerificationCode.
func (s *GmailSMTPEmailSender) SendAlert(_ context.Context, to, message string) error {
	return s.send(to, sosAlertSubject, message)
}

func (s *GmailSMTPEmailSender) send(to, subject, body string) error {
	// net/smtp has no context-aware send — the ctx parameter on the
	// interface methods above is accepted only to satisfy the shared
	// EmailSender interface, same as every other implementation of it.
	msg := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\n%s\r\n", s.address, to, subject, body)

	auth := smtp.PlainAuth("", s.address, s.appPassword, "smtp.gmail.com")
	if err := smtp.SendMail(gmailSMTPAddr, auth, s.address, []string{to}, []byte(msg)); err != nil {
		return fmt.Errorf("email: gmail smtp send: %w", err)
	}
	return nil
}
