package meetup

import (
	"context"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

// participantIdentityFloor is the trust level at which a viewer may see WHO
// is on a meetup.
//
// # WHY IT IS 2 AND NOT visibilityFloor's 1
//
// visibilityFloor (convert.go) governs seeing the MEETUP: its host, its
// time, where it is. This governs seeing the ATTENDEES, which is a strictly
// stronger disclosure — a list of named professionals who will be in a known
// place at a known time. Level 2 is the level at which someone has verified
// a phone, a personal email, a legal name and a LinkedIn (ADR-002 §4); it is
// also the level required to JOIN. Somebody who cannot join has no reason to
// need the guest list, and letting them read it would make the app a
// directory that anyone can scrape by signing up.
const participantIdentityFloor = 2

// MeetupParticipant is one person on a meetup, as a given viewer may see
// them. Below participantIdentityFloor, the identifying fields are absent —
// see ListMeetupParticipants.
type MeetupParticipant struct {
	UserID          string
	IsHost          bool
	FullName        string
	ProfilePhotoURL string
	TrustLevel      int
}

// MeetupParticipants is a meetup's attendee list as one viewer may see it.
type MeetupParticipants struct {
	Participants []MeetupParticipant
	// Redacted says the identities were withheld, so the client can render
	// the placeholder treatment deliberately rather than inferring it from
	// empty strings that might equally mean "cache not synced".
	Redacted bool
	// TotalCount is the real number of people, redacted or not — a viewer
	// below the floor is still told HOW MANY are coming, which is the part
	// that makes a meetup look worth joining.
	TotalCount int
}

// ListMeetupParticipants returns who is on a meetup, redacted for viewers
// below participantIdentityFloor.
//
// # THE REDACTION IS SERVER-SIDE, AND THAT IS THE WHOLE POINT
//
// The obvious implementation sends every name and lets the client blur the
// ones it should not show. That is not a privacy control, it is a picture of
// one: the names are on the wire, in the response, one proxy or one patched
// client away from being read. So a viewer below the floor is sent rows with
// no id, no name and no photo — the blur is a rendering choice over fields
// that genuinely are not there.
//
// The USER ID goes too, not just the name. An id is a stable handle: keep it
// and a guest can enumerate a meetup's attendees, correlate the same id
// across several meetups, and rebuild the social graph the redaction was
// meant to withhold — without ever learning a name.
//
// What survives is the count and the shape of the list: how many people, and
// which one is the host. That is deliberate, and mirrors what ADR-002 §5
// already decided for meetup cards — a guest should see that real people are
// really coming, because that is the reason to sign up. They just cannot see
// who.
func (s *service) ListMeetupParticipants(ctx context.Context, req ListMeetupParticipantsRequest) (MeetupParticipants, error) {
	// Fails closed on a meetup that does not exist, and keeps this endpoint
	// from becoming an id-probe that answers differently for real and
	// invented meetups.
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.ViewerID)
	if err != nil {
		return MeetupParticipants{}, err
	}

	rows, err := s.meetups.ListParticipants(ctx, req.MeetupID)
	if err != nil {
		return MeetupParticipants{}, err
	}

	// Identities are for the people IN the meetup: its host, and anyone the
	// host has accepted. Everyone else — whatever their trust level — gets
	// the count, the shape, and the host, and nothing about the rest. The
	// trust floor still applies on top: a below-floor viewer who somehow
	// held an accepted request would still not see the list.
	inMeetup := m.HostUserID == req.ViewerID ||
		(m.MyRequestStatus != nil && *m.MyRequestStatus == repository.RequestStatusAccepted)
	out := MeetupParticipants{
		Participants: make([]MeetupParticipant, 0, len(rows)),
		TotalCount:   len(rows),
		Redacted:     !inMeetup || req.ViewerTrustLevel < participantIdentityFloor,
	}
	// The host stays named in a redacted list for anyone who can see the
	// meetup in full (visibilityFloor): a would-be joiner has to be able to
	// judge who they are asking, and the host's profile is open to them
	// anyway (see GetMemberActivity). A guest below that floor does not see
	// who hosts on the card either, so they do not see it here.
	hostNamed := req.ViewerTrustLevel >= visibilityFloor
	for _, row := range rows {
		// Everyone except a host the viewer is allowed to see by name.
		namedHost := row.IsHost && hostNamed
		if out.Redacted && !namedHost {
			out.Participants = append(out.Participants, MeetupParticipant{IsHost: row.IsHost})
			continue
		}
		out.Participants = append(out.Participants, MeetupParticipant{
			UserID:          row.UserID,
			IsHost:          row.IsHost,
			FullName:        row.FullName,
			ProfilePhotoURL: row.ProfilePhotoURL,
			TrustLevel:      row.TrustLevel,
		})
	}
	return out, nil
}
