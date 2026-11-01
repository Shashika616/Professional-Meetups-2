package email

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"strings"
	"sync"
	"testing"
	"time"
)

const xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

func report() Attachment {
	return Attachment{Filename: "2026-10-31.xlsx", ContentType: xlsx, Data: bytes.Repeat([]byte{0x50, 0x4b, 0x03, 0x04}, 300)}
}

func TestValidateRefusesWhatCouldInjectOrOverflow(t *testing.T) {
	to := []string{"ops@example.com"}
	cases := map[string]struct {
		to      []string
		subject string
		att     func(*Attachment)
		want    error
	}{
		"no recipients":              {to: nil, subject: "s", want: ErrNoRecipients},
		"CRLF in the subject":        {to: to, subject: "Report\r\nBcc: x@evil.test", want: ErrHeaderInjection},
		"LF in a recipient":          {to: []string{"a@b.c\nBcc: x@evil.test"}, subject: "s", want: ErrHeaderInjection},
		"a quoted filename":          {to: to, subject: "s", att: func(a *Attachment) { a.Filename = `a".xlsx` }, want: ErrAttachmentName},
		"a path filename":            {to: to, subject: "s", att: func(a *Attachment) { a.Filename = "../etc/passwd" }, want: ErrAttachmentName},
		"an executable content type": {to: to, subject: "s", att: func(a *Attachment) { a.ContentType = "application/x-msdownload" }, want: ErrAttachmentType},
		"over the cap":               {to: to, subject: "s", att: func(a *Attachment) { a.Data = make([]byte, MaxAttachmentBytes+1) }, want: ErrAttachmentTooLarge},
		"empty":                      {to: to, subject: "s", att: func(a *Attachment) { a.Data = nil }, want: ErrAttachmentTooLarge},
	}
	for name, c := range cases {
		att := report()
		if c.att != nil {
			c.att(&att)
		}
		if err := Validate(c.to, c.subject, att); !errors.Is(err, c.want) {
			t.Errorf("%s: err = %v, want %v", name, err, c.want)
		}
	}
	if err := Validate([]string{"a@b.c, d@e.f"}, "s", report()); err == nil || strings.Contains(err.Error(), "a@b.c") {
		t.Errorf("two addresses in one: err = %v (and the address must not be in it)", err)
	}
	if err := Validate(to, "TieHere daily report 2026-10-31", report()); err != nil {
		t.Errorf("a valid report: %v", err)
	}
}

func TestTheMIMEMessageCarriesTheAttachmentIntact(t *testing.T) {
	att := report()
	raw, err := mimeWithAttachment("reports@example.com", []string{"a@example.com", "b@example.com"}, "Daily report", "Attached.\nTwo lines.", att)
	if err != nil {
		t.Fatal(err)
	}
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	mediaType, params, err := mime.ParseMediaType(msg.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/mixed" {
		t.Fatalf("content type %q (%v)", mediaType, err)
	}
	r := multipart.NewReader(msg.Body, params["boundary"])
	text, _ := r.NextPart()
	body, _ := io.ReadAll(text)
	if !strings.Contains(string(body), "Two lines.") {
		t.Errorf("body = %q", body)
	}
	file, err := r.NextPart()
	if err != nil {
		t.Fatal(err)
	}
	if file.FileName() != att.Filename || file.Header.Get("Content-Type") != xlsx {
		t.Errorf("part %q %q", file.FileName(), file.Header.Get("Content-Type"))
	}
	for _, line := range strings.Split(string(raw), "\r\n") {
		if len(line) > 998 {
			t.Fatalf("a line of %d characters (SMTP allows 998)", len(line))
		}
	}
	// multipart.Reader decodes quoted-printable only; base64 is ours to undo.
	encoded, _ := io.ReadAll(file)
	decoded, err := decodeBase64Lines(encoded)
	if err != nil || !bytes.Equal(decoded, att.Data) {
		t.Errorf("the attachment did not survive the round trip (%v)", err)
	}
}

func TestTheLoggingSenderValidatesAndSendsNothing(t *testing.T) {
	s := NewLoggingEmailSender()
	if err := s.SendWithAttachment(context.Background(), []string{"ops@example.com"}, "Daily report", "body", report()); err != nil {
		t.Fatal(err)
	}
	if err := s.SendWithAttachment(context.Background(), []string{"ops@example.com"}, "x\r\nBcc: y@z", "body", report()); !errors.Is(err, ErrHeaderInjection) {
		t.Errorf("err = %v", err)
	}
}

func TestGmailSendsTheAttachmentToEveryRecipient(t *testing.T) {
	srv := newCapturingSMTPServer(t)
	s := NewGmailSMTPEmailSender("reports@example.com", "app-password")
	s.smtpAddr = srv.addr
	to := []string{"a@example.com", "b@example.com"}
	if err := s.SendWithAttachment(context.Background(), to, "Daily report", "Attached.", report()); err != nil {
		t.Fatal(err)
	}
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if strings.Join(srv.rcpts, ",") != "a@example.com,b@example.com" {
		t.Errorf("rcpts = %v", srv.rcpts)
	}
	if !strings.Contains(srv.data, `filename="2026-10-31.xlsx"`) || !strings.Contains(srv.data, "multipart/mixed") {
		t.Errorf("data = %.300s", srv.data)
	}
}

type capturingSMTPServer struct {
	addr  string
	mu    sync.Mutex
	rcpts []string
	data  string
}

// newCapturingSMTPServer answers just enough SMTP for one transaction and
// records the recipients and the message.
func newCapturingSMTPServer(t *testing.T) *capturingSMTPServer {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	srv := &capturingSMTPServer{addr: ln.Addr().String()}
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		r := bufio.NewReader(conn)
		write := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
		write("220 test")
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			cmd := strings.ToUpper(strings.TrimSpace(line))
			switch {
			case strings.HasPrefix(cmd, "EHLO"), strings.HasPrefix(cmd, "HELO"):
				write("250-test")
				write("250 AUTH PLAIN")
			case strings.HasPrefix(cmd, "AUTH"):
				write("235 ok")
			case strings.HasPrefix(cmd, "MAIL"):
				write("250 ok")
			case strings.HasPrefix(cmd, "RCPT"):
				addr := strings.TrimSpace(line[strings.Index(line, ":")+1:])
				srv.mu.Lock()
				srv.rcpts = append(srv.rcpts, strings.Trim(addr, "<>"))
				srv.mu.Unlock()
				write("250 ok")
			case cmd == "DATA":
				write("354 go")
				var b strings.Builder
				for {
					l, err := r.ReadString('\n')
					if err != nil || l == ".\r\n" {
						break
					}
					b.WriteString(l)
				}
				srv.mu.Lock()
				srv.data = b.String()
				srv.mu.Unlock()
				write("250 queued")
			case cmd == "QUIT":
				write("221 bye")
				return
			default:
				write("250 ok")
			}
		}
	}()
	return srv
}

func decodeBase64Lines(b []byte) ([]byte, error) {
	return base64.StdEncoding.DecodeString(strings.NewReplacer("\r", "", "\n", "").Replace(string(b)))
}
