package email

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/textproto"
	"regexp"
	"strings"
)

// Attachment is one file attached to an email (plan 29F: the daily
// analytics report). Every configured sender implements
// AttachmentSender; Validate runs before any of them touches the network.
type Attachment struct {
	Filename    string
	ContentType string
	Data        []byte
}

// MaxAttachmentBytes caps one attachment. Below both providers' limits
// (Gmail 25 MB, Resend 40 MB per email) once base64 has grown it by a
// third, and far above a day's report (tens of KB).
const MaxAttachmentBytes = 10 << 20

// AllowedAttachmentTypes are the content types an attachment may have. A
// short list on purpose: this is for reports, not arbitrary files.
var AllowedAttachmentTypes = map[string]bool{
	"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": true, // .xlsx
	"text/csv":        true,
	"application/pdf": true,
}

// safeFilename is what a filename may look like: it ends up in a MIME
// header, so no quotes, slashes, spaces or control characters.
var safeFilename = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)

// AttachmentSender sends one email with one attachment to each recipient.
type AttachmentSender interface {
	SendWithAttachment(ctx context.Context, to []string, subject, body string, att Attachment) error
}

// Errors Validate returns.
var (
	ErrAttachmentTooLarge = errors.New("email: attachment is over the size cap")
	ErrAttachmentType     = errors.New("email: attachment content type is not allowed")
	ErrAttachmentName     = errors.New("email: attachment filename is not allowed")
	ErrHeaderInjection    = errors.New("email: a header value contains a line break")
	ErrNoRecipients       = errors.New("email: no recipients")
)

// Validate checks an attachment email before it is sent: recipients and
// subject free of line breaks (header injection), a safe filename, an
// allowed content type, and the size cap.
func Validate(to []string, subject string, att Attachment) error {
	if len(to) == 0 {
		return ErrNoRecipients
	}
	for _, addr := range append([]string{subject}, to...) {
		if strings.ContainsAny(addr, "\r\n") {
			return ErrHeaderInjection
		}
	}
	for _, addr := range to {
		if !strings.Contains(addr, "@") || strings.ContainsAny(addr, " ,;<>\"") {
			return fmt.Errorf("email: %q is not a single address", redact(addr))
		}
	}
	if !safeFilename.MatchString(att.Filename) {
		return ErrAttachmentName
	}
	if !AllowedAttachmentTypes[att.ContentType] {
		return ErrAttachmentType
	}
	if len(att.Data) == 0 || len(att.Data) > MaxAttachmentBytes {
		return ErrAttachmentTooLarge
	}
	return nil
}

// redact keeps an address out of error text and logs: its domain only.
func redact(addr string) string {
	if i := strings.LastIndexByte(addr, '@'); i >= 0 {
		return "…" + addr[i:]
	}
	return "…"
}

// mimeWithAttachment builds a multipart/mixed message with a plain-text body
// and one base64 attachment, lines wrapped at 76 characters (RFC 2045).
func mimeWithAttachment(from string, to []string, subject, body string, att Attachment) ([]byte, error) {
	var b bytes.Buffer
	w := multipart.NewWriter(&b)
	fmt.Fprintf(&b, "From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=%q\r\n\r\n",
		from, strings.Join(to, ", "), mime.QEncoding.Encode("utf-8", subject), w.Boundary())

	text, err := w.CreatePart(textproto.MIMEHeader{
		"Content-Type":              {"text/plain; charset=utf-8"},
		"Content-Transfer-Encoding": {"8bit"},
	})
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(text, strings.ReplaceAll(body, "\n", "\r\n")); err != nil {
		return nil, err
	}

	part, err := w.CreatePart(textproto.MIMEHeader{
		"Content-Type":              {att.ContentType},
		"Content-Transfer-Encoding": {"base64"},
		"Content-Disposition":       {fmt.Sprintf("attachment; filename=%q", att.Filename)},
	})
	if err != nil {
		return nil, err
	}
	encoded := base64.StdEncoding.EncodeToString(att.Data)
	for len(encoded) > 76 {
		if _, err := io.WriteString(part, encoded[:76]+"\r\n"); err != nil {
			return nil, err
		}
		encoded = encoded[76:]
	}
	if _, err := io.WriteString(part, encoded+"\r\n"); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
