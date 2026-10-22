package email

import (
	"context"
	"net"
	"testing"
	"time"
)

// A relay that accepts the TCP connection and then says nothing. Before the
// fix, smtp.SendMail had no dial timeout, no deadline and no context, so a
// send against this blocked forever — and on the request path, every such
// stall pinned a goroutine and a socket for good.
func stalledSMTPServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// Hold it open and never send the 220 greeting.
			t.Cleanup(func() { _ = conn.Close() })
		}
	}()
	return ln.Addr().String()
}

func runWithin(t *testing.T, limit time.Duration, f func() error) error {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- f() }()
	select {
	case err := <-done:
		return err
	case <-time.After(limit):
		t.Fatalf("the send was still running after %s: a stalled SMTP relay "+
			"hangs it indefinitely", limit)
		return nil
	}
}

func TestGmailSMTP_AStalledRelayTimesOut(t *testing.T) {
	s := NewGmailSMTPEmailSender("from@example.com", "app-password")
	s.smtpAddr = stalledSMTPServer(t)
	s.timeout = 300 * time.Millisecond

	err := runWithin(t, 3*time.Second, func() error {
		return s.SendVerificationCode(context.Background(), "to@example.com", "123456", PurposePersonalEmail)
	})
	if err == nil {
		t.Fatal("a relay that never answered reported success")
	}
}

// The caller going away must end the send too, not just the timeout.
func TestGmailSMTP_ACancelledCallerEndsTheSend(t *testing.T) {
	s := NewGmailSMTPEmailSender("from@example.com", "app-password")
	s.smtpAddr = stalledSMTPServer(t)
	s.timeout = time.Hour // so only the cancellation can end it

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(200*time.Millisecond, cancel)

	err := runWithin(t, 3*time.Second, func() error {
		return s.SendAlert(ctx, "to@example.com", "test")
	})
	if err == nil {
		t.Fatal("a cancelled send reported success")
	}
}
