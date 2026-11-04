package sos

import (
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"professional-meetups-monolith/backend/internal/modules/auth/identity"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// MaxContactNameLength is the longest a contact's name, or a name in a
// message, may be (plan 2.2).
const MaxContactNameLength = 60

// sriLanka is Asia/Colombo, which has no daylight saving. Fixed rather than
// loaded, so the time in an emergency message cannot depend on a time zone
// database being present in the image.
var sriLanka = time.FixedZone("Asia/Colombo", 19800)

// LocationKind is which step of the SOS location chain a location came from
// (plan 2.2). The zero value is unknown.
type LocationKind int

const (
	LocationUnknown LocationKind = iota
	LocationGPS                  // a fresh fix from the phone
	LocationDevice               // the phone's own last known position
	LocationServer               // the rounded last known location we stored
)

// Source is the audit name of the step; "" for unknown.
func (k LocationKind) Source() string {
	switch k {
	case LocationGPS:
		return "gps"
	case LocationDevice:
		return "device_last_known"
	case LocationServer:
		return "server_last_known"
	}
	return ""
}

// AlertLocation is where the alert says the user is.
type AlertLocation struct {
	Kind       LocationKind
	Lat, Lng   float64
	CapturedAt time.Time
}

// AlertMeetup is the venue of the meetup the user is on, when there is one.
type AlertMeetup struct {
	Intent   string
	Label    string
	Lat, Lng float64
}

// AlertInput is everything an alert says. All of it is server-sourced or
// sanitised here; nothing the client sends reaches the text as free text.
type AlertInput struct {
	Name        string
	Location    AlertLocation
	Meetup      *AlertMeetup
	TriggeredAt time.Time
}

// AlertMessage builds the SOS text (plan 2.2). A fixed template, in the
// GSM-7 alphabet so an SMS stays in the cheaper encoding. With no location
// it says so outright: a contact who has just been told someone may need
// help will look for one, and silence reads as a cut-off message.
func AlertMessage(in AlertInput) string {
	name := smsText(in.Name, MaxContactNameLength)
	if name == "" {
		name = "A TieHere member"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s triggered an SOS alert through TieHere and may need assistance.\n\n", name)

	loc := in.Location
	switch loc.Kind {
	case LocationGPS:
		fmt.Fprintf(&b, "Current location\nGPS location captured at %s\nView current location on Google Maps: %s\n\n",
			capturedAt(loc.CapturedAt, in.TriggeredAt), mapsLink(loc.Lat, loc.Lng))
	case LocationDevice, LocationServer:
		line := "Location"
		if loc.Kind == LocationServer {
			line = "Approximate location"
		}
		fmt.Fprintf(&b, "Last known location\n%s captured at %s\nView last known location on Google Maps: %s\n\n",
			line, capturedAt(loc.CapturedAt, in.TriggeredAt), mapsLink(loc.Lat, loc.Lng))
	default:
		b.WriteString("Current location\nCurrent location unknown\n\n")
	}

	if m := in.Meetup; m != nil {
		title := intentTitle(m.Intent) + " meetup"
		if label := smsText(m.Label, MaxContactNameLength); label != "" {
			title += " - " + label
		}
		fmt.Fprintf(&b, "Meetup location\n%s\nView meetup venue on Google Maps: %s\n\n", title, mapsLink(m.Lat, m.Lng))
	}

	fmt.Fprintf(&b, "Triggered: %s (Sri Lanka time)", in.TriggeredAt.In(sriLanka).Format("2 January 2006, 3:04 PM"))
	return b.String()
}

// capturedAt is the time alone on the day of the alert, with the date
// otherwise.
func capturedAt(t, now time.Time) string {
	t, now = t.In(sriLanka), now.In(sriLanka)
	if t.Format(time.DateOnly) == now.Format(time.DateOnly) {
		return t.Format("3:04 PM")
	}
	return t.Format("2 January 2006, 3:04 PM")
}

// mapsLink has 5 decimals, about a metre.
func mapsLink(lat, lng float64) string {
	return fmt.Sprintf("https://maps.google.com/?q=%.5f,%.5f", lat, lng)
}

func intentTitle(intent string) string {
	switch intent {
	case "ride_share":
		return "Ride share"
	case "":
		return "Planned"
	}
	return strings.ToUpper(intent[:1]) + intent[1:]
}

// gsm7 is the GSM 03.38 basic character set, less the escape and the
// control characters. The two-byte extension characters are left out.
const gsm7 = "@£$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡" +
	"ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà\n"

// urlLike matches a link, with or without a scheme.
var urlLike = regexp.MustCompile(`(?i)(?:[a-z][a-z0-9+.-]*://\S*|www\.\S*|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|co|lk|app|link|ly|me|info|xyz|dev|site|online|shop|top|click)\b\S*)`)

var typographic = strings.NewReplacer("—", "-", "–", "-", "‘", "'", "’", "'", "“", "\"", "”", "\"", "…", "...")

// smsText makes user-controlled text safe for a message: one line, no
// links, GSM-7 only, at most max characters.
func smsText(s string, max int) string {
	s = urlLike.ReplaceAllString(typographic.Replace(s), " ")
	var b strings.Builder
	for _, r := range s {
		switch {
		case unicode.IsSpace(r) || unicode.IsControl(r):
			b.WriteByte(' ')
		case strings.ContainsRune(gsm7, r):
			b.WriteRune(r)
		}
	}
	clean := strings.Join(strings.Fields(b.String()), " ")
	if utf8.RuneCountInString(clean) > max {
		clean = strings.TrimSpace(string([]rune(clean)[:max]))
	}
	return clean
}

var e164 = regexp.MustCompile(`^\+[1-9][0-9]{7,14}$`)

// NormalizeContactPhone returns a contact's number in E.164. A local Sri
// Lankan 0XXXXXXXXX is read as +94XXXXXXXXX: the app has always accepted
// that form, and SMS cannot be sent to it as typed.
func NormalizeContactPhone(raw string) (string, error) {
	phone := identity.NormalizePhone(raw)
	if len(phone) == 10 && phone[0] == '0' {
		phone = "+94" + phone[1:]
	}
	if !e164.MatchString(phone) {
		return "", fmt.Errorf("auth: enter the number with its country code, for example +94771234567: %w", apperror.ErrInvalidInput)
	}
	return phone, nil
}

// CleanContactName checks a contact's name: 1 to 60 characters, one line,
// no links (plan 2.2). Any script is fine; a name is shown to the user, and
// never sent to anyone.
func CleanContactName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	switch {
	case name == "":
		return "", fmt.Errorf("auth: name is required: %w", apperror.ErrInvalidInput)
	case utf8.RuneCountInString(name) > MaxContactNameLength:
		return "", fmt.Errorf("auth: a name can be at most %d characters: %w", MaxContactNameLength, apperror.ErrInvalidInput)
	case strings.ContainsFunc(name, unicode.IsControl):
		return "", fmt.Errorf("auth: a name has to fit on one line: %w", apperror.ErrInvalidInput)
	case urlLike.MatchString(name):
		return "", fmt.Errorf("auth: a name cannot contain a link: %w", apperror.ErrInvalidInput)
	}
	return name, nil
}

// MeetupShareMessage builds the body each selected contact receives.
// Exported for the module's tests, same as AlertMessage.
//
// Deliberately states a WINDOW and a PLACE, not "live location". The link is
// a static map pin at the meetup's own coordinates — the app does not track
// anyone, and a message implying otherwise would be a safety promise it
// cannot keep.
func MeetupShareMessage(callerName, locationLabel string, lat, lng float64, start, end time.Time) string {
	name := smsText(callerName, MaxContactNameLength)
	if name == "" {
		name = "A TieHere member"
	}
	msg := fmt.Sprintf("%s is meeting %s - %s", name,
		start.In(sriLanka).Format("Mon 3:04 PM"), end.In(sriLanka).Format("3:04 PM"))
	if label := smsText(locationLabel, MaxContactNameLength); label != "" {
		msg += " at " + label
	}
	return msg + ". Location: " + mapsLink(lat, lng)
}
