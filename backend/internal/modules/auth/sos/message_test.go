package sos

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var triggered = time.Date(2026, 10, 30, 13, 15, 0, 0, time.UTC) // 6:45 PM in Colombo

func colombo(day, hour, minute int) time.Time {
	return time.Date(2026, 10, day, hour, minute, 0, 0, sriLanka)
}

// Plan 2.2: the message is exactly the template, for every variant.
func TestAlertMessageMatchesTheGoldenFiles(t *testing.T) {
	gps := AlertLocation{Kind: LocationGPS, Lat: 6.90123, Lng: 79.85432, CapturedAt: triggered}
	meetup := &AlertMeetup{Intent: "coffee", Label: "Colombo 07", Lat: 6.91234, Lng: 79.86543}
	for _, tc := range []struct {
		golden string
		in     AlertInput
	}{
		{"gps_with_meetup", AlertInput{Name: "Ada Perera", Location: gps, Meetup: meetup, TriggeredAt: triggered}},
		{"gps_no_meetup", AlertInput{Name: "Ada Perera", Location: gps, TriggeredAt: triggered}},
		{"device_today", AlertInput{Name: "Ada Perera", TriggeredAt: triggered, Location: AlertLocation{
			Kind: LocationDevice, Lat: 6.90123, Lng: 79.85432, CapturedAt: colombo(30, 17, 10)}}},
		{"device_yesterday", AlertInput{Name: "Ada Perera", Meetup: meetup, TriggeredAt: triggered, Location: AlertLocation{
			Kind: LocationDevice, Lat: 6.90123, Lng: 79.85432, CapturedAt: colombo(29, 23, 20)}}},
		{"server_approximate", AlertInput{Name: "Ada Perera", TriggeredAt: triggered, Location: AlertLocation{
			Kind: LocationServer, Lat: 6.901, Lng: 79.854, CapturedAt: colombo(30, 14, 30)}}},
		{"unknown_no_meetup", AlertInput{Name: "Ada Perera", TriggeredAt: triggered}},
		{"unknown_with_meetup", AlertInput{Name: "Ada Perera", Meetup: meetup, TriggeredAt: triggered}},
		// Line breaks, a link and an em dash from fields a user controls.
		{"hostile_name", AlertInput{
			Name:        "Ada\nPerera\r\nhttps://evil.example/x www.evil.example",
			Meetup:      &AlertMeetup{Intent: "lunch", Label: "Galle Face — http://x.co/y\nCall 1", Lat: 6.91234, Lng: 79.86543},
			TriggeredAt: triggered,
		}},
	} {
		t.Run(tc.golden, func(t *testing.T) {
			want, err := os.ReadFile(filepath.Join("testdata", tc.golden+".txt"))
			if err != nil {
				t.Fatal(err)
			}
			got := AlertMessage(tc.in)
			if got != strings.TrimSuffix(string(want), "\n") {
				t.Errorf("got:\n%s\nwant:\n%s", got, want)
			}
			if bad := firstNonGSM7(got); bad != 0 {
				t.Errorf("the message holds %q, outside GSM-7", bad)
			}
		})
	}
}

func firstNonGSM7(s string) rune {
	for _, r := range s {
		if !strings.ContainsRune(gsm7, r) {
			return r
		}
	}
	return 0
}

// A name in Sinhala or Tamil has no GSM-7 form. The alert still goes, and
// still says who it is about as far as it can.
func TestAlertMessageWithANameOutsideGSM7(t *testing.T) {
	got := AlertMessage(AlertInput{Name: "අදා", TriggeredAt: triggered})
	if !strings.HasPrefix(got, "A TieHere member triggered an SOS alert") {
		t.Errorf("got %q", got)
	}
	if bad := firstNonGSM7(got); bad != 0 {
		t.Errorf("the message holds %q", bad)
	}
	long := strings.Repeat("Bartholomew ", 10)
	first := strings.SplitN(AlertMessage(AlertInput{Name: long, TriggeredAt: triggered}), " triggered", 2)[0]
	if len(first) > MaxContactNameLength {
		t.Errorf("a %d-character name reached the message", len(first))
	}
}

func TestMeetupShareMessageIsGSM7AndInColomboTime(t *testing.T) {
	start := time.Date(2026, 10, 30, 13, 0, 0, 0, time.UTC)
	got := MeetupShareMessage("Ada\nPerera https://x.co", "Galle Face — 1", 6.9, 79.8, start, start.Add(time.Hour))
	want := "Ada Perera is meeting Fri 6:30 PM - 7:30 PM at Galle Face - 1. Location: https://maps.google.com/?q=6.90000,79.80000"
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
	if bad := firstNonGSM7(got); bad != 0 {
		t.Errorf("the message holds %q", bad)
	}
}

func TestContactPhoneNormalisation(t *testing.T) {
	for in, want := range map[string]string{
		"+94 77 123 4567": "+94771234567",
		"077-123-4567":    "+94771234567",
		"(077) 123 4567":  "+94771234567",
		"+1 415 555 2671": "+14155552671",
	} {
		got, err := NormalizeContactPhone(in)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "12345", "771234567", "+0771234567", "+1234567", "+1234567890123456", "abc"} {
		if got, err := NormalizeContactPhone(in); err == nil {
			t.Errorf("%q was accepted as %q", in, got)
		}
	}
}

func TestContactNameRules(t *testing.T) {
	for _, ok := range []string{"Amma", "Dr. K. Silva", "අම්මා", strings.Repeat("a", 60)} {
		if _, err := CleanContactName(ok); err != nil {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "   ", strings.Repeat("a", 61), "Amma\nDad", "Amma\rDad", "see https://x.co", "www.x.co", "go to evil.com now"} {
		if _, err := CleanContactName(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}
