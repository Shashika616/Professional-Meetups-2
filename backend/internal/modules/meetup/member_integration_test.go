package meetup_test

import (
	"context"
	"errors"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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

// Who may open whose profile. Hosts are public; a host may also open anyone
// who asked to join a meetup they host, pending included, because that is
// the decision the host is being asked to make. Otherwise you need a shared
// meetup as host/accepted, and a pending requester still sees nobody.
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
		// The host is deciding whether to let this person in, so the host
		// can read them before accepting. The app's request card opens
		// exactly this profile.
		{"host → pending", f.host, f.pending, true},

		{"outsider → accepted", f.outsider, f.accepted, false},
		{"accepted → outsider", f.accepted, f.outsider, false},
		// The clause above runs in the host's direction ONLY. A pending
		// requester gains nothing from having asked: not the other people
		// on the meetup, and not each other.
		{"pending → accepted", f.pending, f.accepted, false},
		{"accepted → pending", f.accepted, f.pending, false},
		{"outsider → pending", f.outsider, f.pending, false},
	}
	for _, c := range cases {
		_, err := h.svc.GetMemberActivity(ctx, c.viewer, 2, c.target)
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
func TestGetMemberActivity_HostMeetupsAndAnonymousReviews_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)

	// End the meetup and have both people review it with a note.
	start := time.Date(2026, 9, 1, 15, 0, 0, 0, time.UTC) // 20:30 in Colombo
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = $2, window_end = now() - interval '1 hour' WHERE id = $1`,
		f.meetupID, start,
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

	// Everyone sees exactly the same thing, including the person who wrote
	// the review and the host it is about.
	var first meetup.MemberActivity
	for i, viewer := range []string{f.outsider, f.accepted, f.host} {
		got, err := h.svc.GetMemberActivity(ctx, viewer, 2, f.host)
		if err != nil {
			t.Fatalf("viewer %d: %v", i, err)
		}
		if i == 0 {
			first = got
			continue
		}
		if !reflect.DeepEqual(got, first) {
			t.Errorf("viewer %d sees %+v, the outsider %+v", i, got, first)
		}
	}

	if len(first.RecentMeetups) != 1 {
		t.Fatalf("recent = %d, want 1", len(first.RecentMeetups))
	}
	mm := first.RecentMeetups[0]
	if mm.ParticipantCount != 2 || mm.ReviewCount != 1 || mm.OverallAverage != 3 {
		t.Errorf("meetup = people:%d reviews:%d avg:%v, want 2, 1, 3: the host's own review does not count", mm.ParticipantCount, mm.ReviewCount, mm.OverallAverage)
	}
	wantDay := time.Date(2026, 9, 1, 6, 30, 0, 0, time.UTC) // noon in Colombo
	if !mm.Day.Equal(wantDay) {
		t.Errorf("Day = %s, want %s: the hour must not leave the server", mm.Day.UTC(), wantDay)
	}

	if len(first.Reviews) != 1 {
		t.Fatalf("reviews = %+v, want the participant's only", first.Reviews)
	}
	r := first.Reviews[0]
	if r.Score != 3 || r.Text != guestNote || !regexp.MustCompile(`^\d{4}-\d{2}$`).MatchString(r.Month) {
		t.Errorf("review = %+v", r)
	}

	// A member who only joined lists no meetups and has no reviews.
	joined, err := h.svc.GetMemberActivity(ctx, f.accepted, 2, f.accepted)
	if err != nil {
		t.Fatalf("self: %v", err)
	}
	if len(joined.RecentMeetups) != 0 || len(joined.Reviews) != 0 {
		t.Errorf("a member who only joined shows %+v", joined)
	}
}

// Plan 2.3: an old review longer than the limit is still cut on the way out.
func TestGetMemberActivity_ClampsReviewText_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)
	long := strings.Repeat("අ", 600) // three bytes each: characters, not bytes
	if _, err := h.pool.Exec(ctx, `
		INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, overall_score, notes, review_completed_at)
		VALUES ($1, $2, true, 4, $3, now())`, f.meetupID, f.accepted, long); err != nil {
		t.Fatalf("seed: %v", err)
	}
	got, err := h.svc.GetMemberActivity(ctx, f.outsider, 2, f.host)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Reviews) != 1 || utf8.RuneCountInString(got.Reviews[0].Text) != 500 {
		t.Fatalf("reviews = %d, want one of 500 characters", len(got.Reviews))
	}
}

// #90. The safety questionnaire and the public review shared one notes
// column, so a private "did you feel safe?" note could be published on the
// meetup for other people to read — directly, and again when its author
// later finished the review without writing a note of their own.
func TestGetMemberActivity_NeverPublishesASafetyNote_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
		f.meetupID,
	); err != nil {
		t.Fatalf("end meetup: %v", err)
	}

	private := "He made me uncomfortable; I left early."
	no := false
	if err := h.svc.SubmitMeetupFeedback(ctx, meetup.SubmitMeetupFeedbackRequest{
		MeetupID: f.meetupID, UserID: f.accepted, Happened: true, FeltSafe: &no, Notes: &private,
	}); err != nil {
		t.Fatalf("safety feedback: %v", err)
	}

	assertNotPublished := func(stage string) {
		t.Helper()
		got, err := h.svc.GetMemberActivity(ctx, f.outsider, 2, f.host)
		if err != nil {
			t.Fatalf("%s: GetMemberActivity: %v", stage, err)
		}
		for _, r := range got.Reviews {
			if r.Text == private {
				t.Errorf("%s: a private safety note was shown publicly", stage)
			}
		}
	}

	// 1. Before any review is completed.
	assertNotPublished("before the review")

	// 2. After the same person completes the review without a note.
	if err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.accepted, OverallScore: 2,
		Participants: []meetup.ReviewParticipantInput{{UserID: f.host, Score: 2}},
	}); err != nil {
		t.Fatalf("review: %v", err)
	}
	assertNotPublished("after a review with no note")
}

// #103 (review N1-B1): a profile listed a member's next open or full
// meetups, with times and places, to anyone allowed to open it. Only
// meetups that have ended are listed now.
func TestGetMemberActivity_NeverListsAnUpcomingMeetup_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)
	got, err := h.svc.GetMemberActivity(ctx, f.accepted, 2, f.host)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.RecentMeetups) != 0 {
		t.Errorf("an upcoming meetup was listed on the profile: %+v", got.RecentMeetups)
	}
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
		f.meetupID); err != nil {
		t.Fatal(err)
	}
	got, err = h.svc.GetMemberActivity(ctx, f.accepted, 2, f.host)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.RecentMeetups) != 1 {
		t.Errorf("the ended meetup is not listed: %d", len(got.RecentMeetups))
	}
}

// #103: a guest (Level 0) sees no one's meetups, name or photo but their
// own, wherever names are hidden from guests today.
func TestGetMemberActivity_HidesOthersFromAGuest_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
		f.meetupID); err != nil {
		t.Fatal(err)
	}
	got, err := h.svc.GetMemberActivity(ctx, f.outsider, 0, f.host)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.RecentMeetups) != 0 || !got.IdentityHidden {
		t.Errorf("a guest got %d meetups, identity hidden %v; want none and hidden", len(got.RecentMeetups), got.IdentityHidden)
	}
	self, err := h.svc.GetMemberActivity(ctx, f.host, 0, f.host)
	if err != nil {
		t.Fatal(err)
	}
	if self.IdentityHidden || len(self.RecentMeetups) != 1 {
		t.Errorf("a member's own profile was hidden from them: %+v", self)
	}
}

// Plan 30B (review N1-B7): the 14-day review window was enforced only by
// which reviews Home offered; the submit paths took a review or rating
// months later. Both refuse once the window has passed.
func TestReviewsAndRatingsCloseAfterFourteenDays_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	f := newMemberFixture(t, h)
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.meetups SET window_start = now() - interval '15 days 3 hours', window_end = now() - interval '15 days' WHERE id = $1`,
		f.meetupID); err != nil {
		t.Fatal(err)
	}
	err := h.svc.SubmitMeetupReview(ctx, meetup.SubmitMeetupReviewRequest{
		MeetupID: f.meetupID, RaterID: f.accepted, OverallScore: 4,
		Participants: []meetup.ReviewParticipantInput{{UserID: f.host, Score: 4}},
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("a review 15 days after: %v, want conflict", err)
	}
	err = h.svc.SubmitRating(ctx, meetup.SubmitRatingRequest{
		MeetupID: f.meetupID, RaterUserID: f.accepted, RatedUserID: f.host, Score: 4,
	})
	if !isSentinel(err, apperror.ErrConflict) {
		t.Errorf("a rating 15 days after: %v, want conflict", err)
	}
}
