package meetup

import (
	"context"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// How much of a host's history a profile shows.
const (
	recentMeetupsOnProfile = 5
	reviewsOnProfile       = 20
	minReviewsForAverage   = 3
)

// colombo is the app's one time zone. A profile's dates and months are
// Sri Lankan ones whatever the server's zone is.
var colombo = time.FixedZone("Asia/Colombo", 5*60*60+30*60)

// MemberActivity is what a public profile shows of a member's history. It
// is the same for every viewer who may see it.
type MemberActivity struct {
	RecentMeetups []MemberMeetup
	Reviews       []MemberReview
	// IdentityHidden: the viewer is a guest looking at someone else, so the
	// member's name and photo are not shown either (#103).
	IdentityHidden bool
}

// MemberMeetup is one finished meetup a member hosted: what it was, the
// day, the area, how many came and how it was rated. Day is noon in Colombo
// on that date, so the hour of the meetup never leaves the server and the
// date reads the same on a phone in any nearby zone.
type MemberMeetup struct {
	Intent           Intent
	Status           Status
	Day              time.Time
	LocationLabel    string
	ParticipantCount int
	OverallAverage   float64
	ReviewCount      int
}

// MemberReview is one anonymous review: a score, the text and a month, for
// every viewer (plan 2.3). There is deliberately no field that could name
// the author or point to a meetup. A meetup of three would give the writer
// away, so reviews are not attached to meetups at all.
type MemberReview struct {
	Score int
	Text  string
	Month string // YYYY-MM
}

// GetMemberActivity is the gate AND the content behind another member's
// public profile.
//
// # WHO MAY OPEN WHOM
//
// A member's profile is visible to a viewer who shares (or shared) a meetup
// with them as host or accepted participant, or if the member hosts one —
// a host is public by design, since a would-be joiner must be able to judge
// them first. A host also sees everyone who asked to join a meetup they
// host, pending included: the host cannot be asked to decide on a stranger
// without being allowed to look at them first. That one runs in the host's
// direction only, so a pending requester still sees nothing of the other
// people on the meetup until they are accepted.
//
// Anyone else gets ErrForbidden, so the profile endpoint cannot be used as
// a directory by guessing ids. The rule lives in
// repository/queries/member.sql (CanViewMemberProfile), with the reasoning
// for each clause; this is the one place it is enforced.
//
// # WHAT A GUEST SEES (#103)
//
// A guest (below visibilityFloor) is not shown who hosts a meetup on its
// card, so a profile cannot tell them either: they get no meetups, and
// IdentityHidden asks the gateway to leave out the name and photo. Their
// own profile is always theirs to see.
//
// # WHAT ANYONE ELSE SEES (plan 2.3)
//
// A host's finished meetups and the anonymous reviews of them. A member who
// only joined shows their count and rating, which the gateway reads from
// the profile; no meetup of theirs is listed here.
func (s *service) GetMemberActivity(ctx context.Context, viewerID string, viewerTrustLevel int, targetID string) (MemberActivity, error) {
	ok, err := s.meetups.CanViewMemberProfile(ctx, viewerID, targetID)
	if err != nil {
		return MemberActivity{}, err
	}
	if !ok {
		return MemberActivity{}, fmt.Errorf("meetup: you can see a member's profile once you share a meetup with them: %w", apperror.ErrForbidden)
	}
	if viewerID != targetID && viewerTrustLevel < visibilityFloor {
		return MemberActivity{RecentMeetups: []MemberMeetup{}, Reviews: []MemberReview{}, IdentityHidden: true}, nil
	}

	rows, err := s.meetups.ListRecentMeetupsForMember(ctx, targetID, recentMeetupsOnProfile)
	if err != nil {
		return MemberActivity{}, err
	}
	reviews, err := s.meetups.ListHostReviews(ctx, targetID, reviewsOnProfile)
	if err != nil {
		return MemberActivity{}, err
	}

	out := MemberActivity{
		RecentMeetups: make([]MemberMeetup, 0, len(rows)),
		Reviews:       make([]MemberReview, 0, len(reviews)),
	}
	for _, r := range rows {
		// With one or two reviews the average is close to someone's own score.
		if r.ReviewCount < minReviewsForAverage {
			r.OverallAverage, r.ReviewCount = 0, 0
		}
		out.RecentMeetups = append(out.RecentMeetups, MemberMeetup{
			Intent:           Intent(r.Intent),
			Status:           Status(r.Status),
			Day:              dayOnly(r.WindowStart),
			LocationLabel:    r.LocationLabel,
			ParticipantCount: r.ParticipantCount,
			OverallAverage:   r.OverallAverage,
			ReviewCount:      r.ReviewCount,
		})
	}
	for _, r := range reviews {
		out.Reviews = append(out.Reviews, MemberReview{
			Score: r.Score,
			Text:  clampText(r.Text, maxFreeTextReasonLength),
			Month: r.WrittenAt.In(colombo).Format("2006-01"),
		})
	}
	return out, nil
}

// dayOnly is noon in Colombo on t's Colombo date.
func dayOnly(t time.Time) time.Time {
	y, m, d := t.In(colombo).Date()
	return time.Date(y, m, d, 12, 0, 0, 0, colombo)
}

// clampText cuts s to at most limit characters. New reviews are limited when
// written; this holds the limit for ones written before it.
func clampText(s string, limit int) string {
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	return string(runes[:limit])
}
