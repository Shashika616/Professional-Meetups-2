package sos

import (
	"strings"
	"testing"
)

// AlertMessage is what a trusted contact actually receives, so its exact
// wording is worth pinning — including the case tracker #78 added, where
// there is no location to give.
//
// It is a fixed template (#80): no argument carries client text. The test
// that used to pass a context string here is gone because the parameter is,
// and that is the point — there is no longer a way to put words or links
// into an SOS someone else receives.
func TestAlertMessage(t *testing.T) {
	lat, lng := 6.9271, 79.8612

	t.Run("with a location", func(t *testing.T) {
		got := AlertMessage("Ada Lovelace", &lat, &lng)
		want := "Ada Lovelace may need help. " +
			"Location: https://maps.google.com/?q=6.927100,79.861200"
		if got != want {
			t.Errorf("AlertMessage() = %q, want %q", got, want)
		}
	})

	// The #78 case. A contact told someone may need help will look for a
	// location; omitting the line entirely reads as a truncated message,
	// while saying it is unavailable tells them this one has to be
	// answered by calling the person.
	t.Run("without a location", func(t *testing.T) {
		got := AlertMessage("Ada Lovelace", nil, nil)
		want := "Ada Lovelace may need help. Location unavailable."
		if got != want {
			t.Errorf("AlertMessage() = %q, want %q", got, want)
		}
		if strings.Contains(got, "maps.google.com") {
			t.Errorf("AlertMessage() = %q, want no maps link", got)
		}
	})

	t.Run("half a location is no location", func(t *testing.T) {
		if got := AlertMessage("Ada", &lat, nil); got != "Ada may need help. Location unavailable." {
			t.Errorf("AlertMessage() with only a latitude = %q, want the unavailable form", got)
		}
	})
}

// The invitation is the only SMS a new contact ever gets unprompted, so its
// content is pinned too: who is asking, what agreeing means, and the link.
func TestInviteMessage(t *testing.T) {
	got := InviteMessage("Ada Lovelace", "https://example.run.app/c/tok")
	for _, want := range []string{"Ada Lovelace", "emergency contact", "https://example.run.app/c/tok", "24 hours", "Ignore this to decline"} {
		if !strings.Contains(got, want) {
			t.Errorf("InviteMessage() = %q, missing %q", got, want)
		}
	}
	// One GSM segment for a typical name and the real link length, so an
	// invitation costs one SMS, not two.
	typical := InviteMessage("Shashika Fernando",
		"https://meetups-backend-k7eklebcwq-el.a.run.app/c/AAAAAAAAAAAAAAAAAAAAAA")
	if len(typical) > 160 {
		t.Logf("typical invitation is %d characters (over one 160-character segment)", len(typical))
	}
}
