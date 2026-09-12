package meetup

import (
	"context"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// recentMeetupsOnProfile is how many of a member's meetups their public
// profile shows.
const recentMeetupsOnProfile = 5

// MemberActivity is what the public profile shows of a member's history,
// as one particular viewer may see it.
type MemberActivity struct {
	RecentMeetups []MemberMeetup
}

// MemberMeetup is one meetup on a member's profile: what it was, the
// member's role in it, how many came, how it was rated overall, and the
// written comments.
type MemberMeetup struct {
	ID               string
	Intent           Intent
	Status           Status
	WindowStart      time.Time
	WindowEnd        time.Time
	LocationLabel    string
	Hosted           bool
	ParticipantCount int
	OverallAverage   float64
	ReviewCount      int
	// ViewerWasIn — the viewer was host or accepted on this meetup, so the
	// comment authors below are named. Otherwise they are anonymous.
	ViewerWasIn bool
	Comments    []MemberMeetupComment
}

// MemberMeetupComment is one review note on a meetup. AuthorName is empty
// when the viewer was not on that meetup — the same rule that hides
// participant identities from outsiders on a live meetup (see
// ListMeetupParticipants) applied to who said what about a past one.
type MemberMeetupComment struct {
	AuthorName string
	Note       string
	WrittenAt  time.Time
}

// GetMemberActivity is the gate AND the content behind another member's
// public profile.
//
// # WHO MAY OPEN WHOM
//
// A member's profile is visible to a viewer who shares (or shared) a meetup
// with them as host or accepted participant, or if the member hosts one —
// a host is public by design, since a would-be joiner must be able to judge
// them first. Anyone else gets ErrForbidden, so the profile endpoint cannot
// be used as a directory by guessing ids. The rule lives in
// repository/queries/member.sql (CanViewMemberProfile); this is the one
// place it is enforced.
func (s *service) GetMemberActivity(ctx context.Context, viewerID, targetID string) (MemberActivity, error) {
	ok, err := s.meetups.CanViewMemberProfile(ctx, viewerID, targetID)
	if err != nil {
		return MemberActivity{}, err
	}
	if !ok {
		return MemberActivity{}, fmt.Errorf("meetup: you can see a member's profile once you share a meetup with them: %w", apperror.ErrForbidden)
	}

	rows, err := s.meetups.ListRecentMeetupsForMember(ctx, viewerID, targetID, recentMeetupsOnProfile)
	if err != nil {
		return MemberActivity{}, err
	}
	ids := make([]string, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	comments, err := s.meetups.ListReviewComments(ctx, ids)
	if err != nil {
		return MemberActivity{}, err
	}
	byMeetup := make(map[string][]repository.MeetupReviewComment, len(rows))
	for _, c := range comments {
		byMeetup[c.MeetupID] = append(byMeetup[c.MeetupID], c)
	}

	out := MemberActivity{RecentMeetups: make([]MemberMeetup, 0, len(rows))}
	for _, r := range rows {
		mm := MemberMeetup{
			ID:               r.ID,
			Intent:           Intent(r.Intent),
			Status:           Status(r.Status),
			WindowStart:      r.WindowStart,
			WindowEnd:        r.WindowEnd,
			LocationLabel:    r.LocationLabel,
			Hosted:           r.TargetIsHost,
			ParticipantCount: r.ParticipantCount,
			OverallAverage:   r.OverallAverage,
			ReviewCount:      r.ReviewCount,
			ViewerWasIn:      r.ViewerWasIn,
			Comments:         make([]MemberMeetupComment, 0, len(byMeetup[r.ID])),
		}
		for _, c := range byMeetup[r.ID] {
			name := ""
			if r.ViewerWasIn {
				name = c.AuthorName
			}
			mm.Comments = append(mm.Comments, MemberMeetupComment{
				AuthorName: name,
				Note:       c.Note,
				WrittenAt:  c.WrittenAt,
			})
		}
		out.RecentMeetups = append(out.RecentMeetups, mm)
	}
	return out, nil
}
