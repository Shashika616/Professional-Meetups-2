package meetup_test

import (
	"context"
	"errors"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// memberFixture: a host, one accepted guest, one still-pending requester,
// and an outsider who has nothing to do with the meetup. Every rule in
// member.go and the participants redaction is about which of these four
// may see what of the others.
type memberFixture struct {
	host, accepted, pending, outsider string
	meetupID                          string
}

func newMemberFixture(t *testing.T, h *harness) memberFixture {
	t.Helper()
	ctx := context.Background()
	f := memberFixture{
		host:     newUserID(t, h),
		accepted: newUserID(t, h),
		pending:  newUserID(t, h),
		outsider: newUserID(t, h),
	}
	seedDisplay(t, h, f.host, "Host Person")
	seedDisplay(t, h, f.accepted, "Accepted Person")
	seedDisplay(t, h, f.pending, "Pending Person")
	seedDisplay(t, h, f.outsider, "Outsider Person")

	m := h.createMeetup(t, f.host, meetup.IntentCoffee, colomboLat, colomboLng)
	f.meetupID = m.ID
	r, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: f.accepted, RequesterTrustLevel: 2,
	})
	if err != nil {
		t.Fatalf("RequestToJoin(accepted): %v", err)
	}
	if _, err := h.svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
		RequestID: r.ID, HostUserID: f.host, Accept: true,
	}); err != nil {
		t.Fatalf("accept: %v", err)
	}
	if _, err := h.svc.RequestToJoin(ctx, meetup.RequestToJoinRequest{
		MeetupID: m.ID, RequesterID: f.pending, RequesterTrustLevel: 2,
	}); err != nil {
		t.Fatalf("RequestToJoin(pending): %v", err)
	}
	return f
}

// The participants list is for the people IN the meetup. An outsider —
// even at a trust level that could join — gets the count, the host, and
// blank rows for everyone else. This is the rule change from "any Level 2
// viewer sees everyone": the old test above this one pinned that, and now
// pins the opposite.
func TestListMeetupParticipants_OutsidersSeeOnlyTheHost_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)

	for _, viewer := range []struct {
		role string
		id   string
	}{
		{"outsider", f.outsider},
		{"pending requester", f.pending},
	} {
		got, err := h.svc.ListMeetupParticipants(ctx, meetup.ListMeetupParticipantsRequest{
			MeetupID: f.meetupID, ViewerID: viewer.id, ViewerTrustLevel: 3,
		})
		if err != nil {
			t.Fatalf("%s: %v", viewer.role, err)
		}
		if !got.Redacted {
			t.Errorf("%s: Redacted = false, want true — they are not on the meetup", viewer.role)
		}
		if got.TotalCount != 2 {
			t.Errorf("%s: TotalCount = %d, want 2", viewer.role, got.TotalCount)
		}
		var hostNamed, guestBlank bool
		for _, p := range got.Participants {
			if p.IsHost {
				hostNamed = p.FullName == "Host Person" && p.UserID == f.host
			} else {
				guestBlank = p.FullName == "" && p.UserID == "" && p.ProfilePhotoURL == ""
			}
		}
		if !hostNamed {
			t.Errorf("%s: the host must stay named — a joiner has to be able to judge who they are asking", viewer.role)
		}
		if !guestBlank {
			t.Errorf("%s: an accepted participant's identity leaked to someone not on the meetup: %+v", viewer.role, got.Participants)
		}
	}

	for _, viewer := range []struct {
		role string
		id   string
	}{
		{"host", f.host},
		{"accepted participant", f.accepted},
	} {
		got, err := h.svc.ListMeetupParticipants(ctx, meetup.ListMeetupParticipantsRequest{
			MeetupID: f.meetupID, ViewerID: viewer.id, ViewerTrustLevel: 2,
		})
		if err != nil {
			t.Fatalf("%s: %v", viewer.role, err)
		}
		if got.Redacted {
			t.Errorf("%s: Redacted = true, want the real list — they are on the meetup", viewer.role)
		}
		named := 0
		for _, p := range got.Participants {
			if p.FullName != "" && p.UserID != "" {
				named++
			}
		}
		if named != 2 {
			t.Errorf("%s: %d named of 2 — everyone on the meetup sees everyone", viewer.role, named)
		}
	}
}

// Who may open whose profile. Hosts are public; otherwise you need a shared
// meetup as host/accepted. Pending is not enough.
func TestGetMemberActivity_Gate_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)

	cases := []struct {
		name           string
		viewer, target string
		allowed        bool
	}{
		{"outsider → host", f.outsider, f.host, true},
		{"pending → host", f.pending, f.host, true},
		{"accepted → host", f.accepted, f.host, true},
		{"host → accepted", f.host, f.accepted, true},
		{"accepted → self", f.accepted, f.accepted, true},
		{"outsider → accepted", f.outsider, f.accepted, false},
		{"pending → accepted", f.pending, f.accepted, false},
		{"host → pending", f.host, f.pending, false},
		{"accepted → outsider", f.accepted, f.outsider, false},
	}
	for _, c := range cases {
		_, err := h.svc.GetMemberActivity(ctx, c.viewer, c.target)
		if c.allowed && err != nil {
			t.Errorf("%s: want allowed, got %v", c.name, err)
		}
		if !c.allowed && !errors.Is(err, apperror.ErrForbidden) {
			t.Errorf("%s: want ErrForbidden, got %v", c.name, err)
		}
	}
}

// The recent-meetups feed: role, aggregate, and comment authorship named
// only for a viewer who was on that meetup.
func TestGetMemberActivity_RecentMeetupsAndComments_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)

	// End the meetup and have both people review it with a note.
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
		f.meetupID,
	); err != nil {
		t.Fatalf("end meetup: %v", err)
	}
	hostNote, guestNote := "Great chat, would host again.", "Lovely spot and good company."
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.host, OverallScore: 5, Notes: &hostNote,
		Participants: []meetup.ReviewParticipantInput{{UserID: f.accepted, Score: 5}},
	}); err != nil {
		t.Fatalf("host review: %v", err)
	}
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.accepted, OverallScore: 3, Notes: &guestNote,
		Participants: []meetup.ReviewParticipantInput{{UserID: f.host, Score: 4}},
	}); err != nil {
		t.Fatalf("guest review: %v", err)
	}

	// An outsider looking at the host: the meetup is listed, the aggregate
	// is real, the comments are there — but nobody is named.
	got, err := h.svc.GetMemberActivity(ctx, f.outsider, f.host)
	if err != nil {
		t.Fatalf("outsider → host: %v", err)
	}
	if len(got.RecentMeetups) != 1 {
		t.Fatalf("recent = %d, want 1", len(got.RecentMeetups))
	}
	mm := got.RecentMeetups[0]
	if !mm.Hosted || mm.ParticipantCount != 2 || mm.ReviewCount != 2 || mm.OverallAverage != 4 {
		t.Errorf("host's meetup = hosted:%v people:%d reviews:%d avg:%v, want hosted, 2, 2, 4", mm.Hosted, mm.ParticipantCount, mm.ReviewCount, mm.OverallAverage)
	}
	if mm.ViewerWasIn {
		t.Error("ViewerWasIn = true for an outsider")
	}
	if len(mm.Comments) != 2 {
		t.Fatalf("comments = %d, want 2", len(mm.Comments))
	}
	for _, c := range mm.Comments {
		if c.AuthorName != "" {
			t.Errorf("outsider saw a comment author: %q — names are for people who were there", c.AuthorName)
		}
		if c.Note != hostNote && c.Note != guestNote {
			t.Errorf("unexpected note %q", c.Note)
		}
	}

	// The accepted guest looking at the host: same meetup, now with names,
	// and from the guest's side it was joined, not hosted, when looking at
	// themselves.
	got, err = h.svc.GetMemberActivity(ctx, f.accepted, f.host)
	if err != nil {
		t.Fatalf("accepted → host: %v", err)
	}
	mm = got.RecentMeetups[0]
	if !mm.ViewerWasIn {
		t.Error("ViewerWasIn = false for an accepted participant")
	}
	names := map[string]bool{}
	for _, c := range mm.Comments {
		names[c.AuthorName] = true
	}
	if !names["Host Person"] || !names["Accepted Person"] {
		t.Errorf("a participant should see who wrote what, got %v", names)
	}

	self, err := h.svc.GetMemberActivity(ctx, f.accepted, f.accepted)
	if err != nil {
		t.Fatalf("self: %v", err)
	}
	if len(self.RecentMeetups) != 1 || self.RecentMeetups[0].Hosted {
		t.Errorf("the guest's own feed should list the meetup as joined, got %+v", self.RecentMeetups)
	}
}
