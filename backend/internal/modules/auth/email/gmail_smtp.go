package email

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"time"
)

// gmailSMTPAddr is Gmail's SMTP relay — STARTTLS on 587, not the legacy
// implicit-TLS port 465.
const gmailSMTPAddr = "smtp.gmail.com:587"

// smtpSendTimeout bounds one whole SMTP conversation: dial, STARTTLS, AUTH
// and DATA together. Generous for a relay that normally answers in well
// under a second, and still inside the gateway's own request deadline, so a
// stalled send surfaces as an error the caller can act on.
const smtpSendTimeout = 15 * time.Second

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
	smtpAddr    string        // host:port, gmailSMTPAddr outside tests
	timeout     time.Duration // smtpSendTimeout outside tests
}

// NewGmailSMTPEmailSender constructs a GmailSMTPEmailSender. address is the
// full Gmail address, used as both the SMTP username and the From address.
func NewGmailSMTPEmailSender(address, appPassword string) *GmailSMTPEmailSender {
	return &GmailSMTPEmailSender{
		address:     address,
		appPassword: appPassword,
		smtpAddr:    gmailSMTPAddr,
		timeout:     smtpSendTimeout,
	}
}

func (s *GmailSMTPEmailSender) SendVerificationCode(ctx context.Context, to, code string, purpose Purpose) error {
	subject, body := subjectAndBodyFor(code, purpose)
	return s.send(ctx, to, subject, body)
}

// SendAlert (ADR-026 §2) reuses the exact same Gmail SMTP wiring as
// SendVerificationCode.
func (s *GmailSMTPEmailSender) SendAlert(ctx context.Context, to, message string) error {
	return s.send(ctx, to, sosAlertSubject, message)
}

// send runs the same conversation smtp.SendMail does, but bounded.
//
// smtp.SendMail dials with no timeout, sets no deadline and takes no
// context. A relay that accepted the connection and then stalled held the
// goroutine and the socket forever — and since this runs on the request
// path for every verification email and SOS email, enough stalls would pin
// an unbounded number of both. Here the dial honours ctx, the connection
// carries a deadline for the whole exchange, and the socket is closed the
// moment the caller gives up, so every send ends.
//
// PlainAuth still refuses to send credentials unless STARTTLS succeeded
// (or the host is localhost), so dropping SendMail gives up no protection.
func (s *GmailSMTPEmailSender) send(ctx context.Context, to, subject, body string) error {
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "tcp", s.smtpAddr)
	if err != nil {
		return fmt.Errorf("email: gmail smtp dial: %w", err)
	}
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			_ = conn.Close()
			return fmt.Errorf("email: gmail smtp deadline: %w", err)
		}
	}
	// A cancelled caller closes the socket, which unblocks whichever read
	// or write the conversation is stuck in.
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()

	host, _, _ := net.SplitHostPort(s.smtpAddr)
	c, err := smtp.NewClient(conn, host)
	if err != nil {
		_ = conn.Close()
		return fmt.Errorf("email: gmail smtp greeting: %w", err)
	}
	defer func() { _ = c.Close() }()

	if ok, _ := c.Extension("STARTTLS"); ok {
		if err := c.StartTLS(&tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("email: gmail smtp starttls: %w", err)
		}
	}
	if err := c.Auth(smtp.PlainAuth("", s.address, s.appPassword, host)); err != nil {
		return fmt.Errorf("email: gmail smtp auth: %w", err)
	}
	if err := c.Mail(s.address); err != nil {
		return fmt.Errorf("email: gmail smtp mail from: %w", err)
	}
	if err := c.Rcpt(to); err != nil {
		return fmt.Errorf("email: gmail smtp rcpt to: %w", err)
	}
	w, err := c.Data()
	if err != nil {
		return fmt.Errorf("email: gmail smtp data: %w", err)
	}
	msg := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\n%s\r\n", s.address, to, subject, body)
	if _, err := w.Write([]byte(msg)); err != nil {
		return fmt.Errorf("email: gmail smtp write: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("email: gmail smtp send: %w", err)
	}
	return c.Quit()
}
