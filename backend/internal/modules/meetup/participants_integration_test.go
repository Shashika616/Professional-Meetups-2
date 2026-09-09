package meetup_test

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
)

// The attendee list is a stronger disclosure than the meetup itself: named
// professionals, in a known place, at a known time. These tests pin who may
// read it.
func TestListMeetupParticipants_RedactsBelowLevelTwo_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}

	onlooker := newUserID(t, h)

	for _, level := range []int{0, 1} {
		got, err := h.svc.ListMeetupParticipants(ctx, meetup.ListMeetupParticipantsRequest{
			MeetupID: m.ID, ViewerID: onlooker, ViewerTrustLevel: level,
		})
		if err != nil {
			t.Fatalf("ListMeetupParticipants(level %d): %v", level, err)
		}
		if !got.Redacted {
			t.Errorf("level %d: Redacted = false, want true", level)
		}
		// They still learn that real people are really coming — that is the
		// reason to sign up (ADR-002 §5).
		if got.TotalCount != 2 || len(got.Participants) != 2 {
			t.Errorf("level %d: saw %d of %d, want both counted", level, len(got.Participants), got.TotalCount)
		}
		hosts := 0
		for _, p := range got.Participants {
			// Blurring on the client is not a privacy control if the names
			// are on the wire. Nothing identifying may leave the server.
			if p.FullName != "" || p.ProfilePhotoURL != "" {
				t.Errorf("level %d: identity leaked: %+v", level, p)
			}
			// The id goes too: it is a stable handle that would let a guest
			// correlate the same person across meetups without ever
			// learning a name.
			if p.UserID != "" {
				t.Errorf("level %d: user id leaked (%q) — the graph is rebuildable from ids alone", level, p.UserID)
			}
			if p.IsHost {
				hosts++
			}
		}
		if hosts != 1 {
			t.Errorf("level %d: %d hosts flagged, want exactly 1 — the shape of the list survives redaction", level, hosts)
		}
	}

	// Level 2 is the join bar, and the level at which the guest list opens.
	got, err := h.svc.ListMeetupParticipants(ctx, meetup.ListMeetupParticipantsRequest{
		MeetupID: m.ID, ViewerID: onlooker, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListMeetupParticipants(level 2): %v", err)
	}
	if got.Redacted {
		t.Fatal("level 2: Redacted = true, want the real list")
	}
	byName := map[string]meetup.MeetupParticipant{}
	for _, p := range got.Participants {
		byName[p.FullName] = p
	}
	if _, ok := byName["Host Person"]; !ok {
		t.Errorf("level 2 saw %+v, want the host named", got.Participants)
	}
	if _, ok := byName["Guest Person"]; !ok {
		t.Errorf("level 2 saw %+v, want the accepted participant named", got.Participants)
	}
	if !byName["Host Person"].IsHost || byName["Guest Person"].IsHost {
		t.Error("the host flag is on the wrong person")
	}
	// Host first, so the list reads the same way every time.
	if !got.Participants[0].IsHost {
		t.Error("the host is not first")
	}
}

// Only the host and ACCEPTED requesters. A pending request is not an
// attendee, and publishing one would tell everyone who had applied.
func TestListMeetupParticipants_ExcludesUnacceptedRequests_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	pending := newUserID(t, h)
	rejected := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, pending, "Pending Person")
	seedDisplay(t, h, rejected, "Rejected Person")

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: pending, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin(pending): %v", err)
	}
	rr, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: rejected, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin(rejected): %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: rr.ID, HostUserID: host, Accept: false,
	}); err != nil {
		t.Fatalf("reject: %v", err)
	}

	got, err := h.svc.ListMeetupParticipants(ctx, meetup.ListMeetupParticipantsRequest{
		MeetupID: m.ID, ViewerID: host, ViewerTrustLevel: 3,
	})
	if err != nil {
		t.Fatalf("ListMeetupParticipants: %v", err)
	}
	if len(got.Participants) != 1 || !got.Participants[0].IsHost {
		t.Errorf("saw %+v, want the host alone — a pending or rejected requester is not an attendee", got.Participants)
	}
}

// ListRatableParticipants redacts trust level, and ONLY trust level — the
// deliberate asymmetry with ListMeetupParticipants (gap #25). The viewer
// here already met these people; withholding their names would break the
// rating screen without protecting anyone.
func TestListRatableParticipants_RedactsOnlyTrustLevel_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	guest := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, guest, "Guest Person")

	m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: guest, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	backdateMeetup(t, h, m.ID)
	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: m.ID, UserID: host, Happened: true,
	}); err != nil {
		t.Fatalf("SubmitMeetupFeedback: %v", err)
	}

	// seedDisplay writes trust level 4, so a non-zero value is genuinely
	// available to leak.
	for _, level := range []int{0, 1} {
		got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
			MeetupID: m.ID, ViewerID: host, ViewerTrustLevel: level,
		})
		if err != nil {
			t.Fatalf("ListRatableParticipants(level %d): %v", level, err)
		}
		if len(got) != 1 {
			t.Fatalf("level %d: saw %d participant(s), want 1", level, len(got))
		}
		if got[0].TrustLevel != 0 {
			t.Errorf("level %d: trust level %d leaked, want 0", level, got[0].TrustLevel)
		}
		// The half that must NOT be redacted — there is no way to rate
		// someone you cannot identify.
		if got[0].FullName != "Guest Person" {
			t.Errorf("level %d: full name = %q, want it kept — the rating UI picks people by name", level, got[0].FullName)
		}
		if got[0].UserID == "" {
			t.Errorf("level %d: user id was blanked — the rating write is addressed by it", level)
		}
	}

	got, err := h.svc.ListRatableParticipants(ctx, meetup.ListRatableParticipantsRequest{
		MeetupID: m.ID, ViewerID: host, ViewerTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("ListRatableParticipants(at floor): %v", err)
	}
	if len(got) != 1 || got[0].TrustLevel != 4 {
		t.Errorf("at the identity floor the real trust level must come through, got %+v", got)
	}
}
