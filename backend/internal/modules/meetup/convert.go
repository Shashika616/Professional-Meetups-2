package meetup

import (
	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

// meetupFromRepo converts a repository.Meetup to the module's own Meetup,
// computing IsHostedByMe relative to viewerID — never trusted from the
// client, always derived server-side from the caller's verified id.
//
// Every optional field is populated in full here, and LockedForViewer stays
// false; redactForViewer nulls them afterwards at the two call sites that
// carry a viewer trust level to compare against. ListMyMeetups,
// ListActiveMeetups and CreateMeetup don't carry one and have nothing to
// redact — by construction they only ever return meetups the viewer already
// belongs to.
func meetupFromRepo(m repository.Meetup, viewerID string) Meetup {
	windowStart := m.WindowStart
	windowEnd := m.WindowEnd
	lat := m.LocationLat
	lng := m.LocationLng
	label := m.LocationLabel
	hostName := m.HostFullName
	hostPhoto := m.HostProfilePhotoURL

	out := Meetup{
		ID:                    m.ID,
		HostUserID:            m.HostUserID,
		HostFullName:          &hostName,
		HostProfilePhotoURL:   &hostPhoto,
		HostTrustLevel:        m.HostTrustLevel,
		HostRatingAverage:     m.HostRatingAverage,
		HostRatingCount:       m.HostRatingCount,
		Intent:                Intent(m.Intent),
		WindowStart:           &windowStart,
		WindowEnd:             &windowEnd,
		LocationLat:           &lat,
		LocationLng:           &lng,
		LocationLabel:         &label,
		Capacity:              m.Capacity,
		AcceptedCount:         m.AcceptedCount,
		Status:                Status(m.Status),
		CreatedAt:             m.CreatedAt,
		CancelledAt:           m.CancelledAt,
		CancellationReason:    m.CancellationReason,
		ClosedAt:              m.ClosedAt,
		IsHostedByMe:          m.HostUserID == viewerID,
		MyRequestAutoRejected: m.MyRequestAutoRejected,
		MyRequestID:           m.MyRequestID,
	}
	if m.MyRequestStatus != nil {
		status := RequestStatus(*m.MyRequestStatus)
		out.MyRequestStatus = &status
	}
	return out
}

func meetupsFromRepo(meetups []repository.Meetup, viewerID string) []Meetup {
	out := make([]Meetup, 0, len(meetups))
	for _, m := range meetups {
		out = append(out, meetupFromRepo(m, viewerID))
	}
	return out
}

// visibilityFloor is the flat trust level at which a viewer sees meetups in
// full. ADR-002 §5 (canonical: ADR-033 §6) decoupled VISIBILITY from the
// join/host gates entirely — below this line is the guest tier and nothing
// else, regardless of the meetup's intent.
//
// This is why it is a bare constant rather than a per-intent lookup: the
// whole point of the change is that visibility no longer varies by intent.
const visibilityFloor = 1

// redactForViewer applies guest-tier redaction in place.
//
// # WHAT THIS USED TO DO, AND WHAT CHANGED (ADR-002 §5)
//
// This function already existed — the port carried the source's ADR-028
// redaction over in Phase 2. It keyed off `viewerTrustLevel >=
// requiredTrustLevel(intent)`, i.e. the same per-intent number the join gate
// used, and nulled host name, host photo, BOTH coordinates, the location
// label and the whole time window. Levels 0 and 1 were indistinguishable:
// both were fully redacted for an ordinary intent, since both are below 2.
//
// ADR-002 narrows it in two independent ways:
//
//  1. WHO is redacted. The trigger is now a flat `viewerTrustLevel >= 1`,
//     completely independent of the intent's join/host numbers. A Level 1
//     user — anyone who has completed any real signup — now sees every
//     meetup in full, even one they cannot yet join. Only guests are
//     redacted. That is the entire behavioural point: make a guest's read
//     access visibly worse than a real account's, so there is a concrete
//     reason to sign up, without punishing people who already have.
//  2. WHAT is redacted. Location (label and coordinates) and the
//     accepted-count/capacity now stay VISIBLE to guests. A guest is meant
//     to see that real meetups are happening near them — that is the whole
//     draw — while the host's identity and the exact time stay behind the
//     signup wall.
//
// LockedForViewer stays true for the guest tier, unchanged: the card still
// renders as locked and the join button still refuses.
//
// # WHAT DID NOT CHANGE
//
// The host/accepted-participant exception is NOT here and was not touched —
// it lives at GetMeetup's call site (service.go), where IsParticipant is
// checked before this is called at all. That placement is deliberate and is
// explained there; ADR-002 flags it as easy to break by accident, so it has
// its own regression test.
//
// # WHY THE FIELD SET IS NOT COARSENED
//
// Redacted fields are nulled outright, never blurred or rounded server-side.
// A coarsened value is still a value: "within 2km of here" or "some time
// Tuesday afternoon" leaks most of what the real field would. The blur is a
// client-side rendering choice over an absent field, not a server-side
// approximation of a present one.
func redactForViewer(m *Meetup, viewerTrustLevel int) {
	if viewerTrustLevel >= visibilityFloor {
		return
	}
	m.LockedForViewer = true
	m.HostFullName = nil
	m.HostProfilePhotoURL = nil
	m.WindowStart = nil
	m.WindowEnd = nil
	// LocationLat/LocationLng/LocationLabel and AcceptedCount/Capacity are
	// deliberately left populated — see the doc comment above. This is the
	// one place the pre-ADR-002 behaviour was loosened rather than tightened,
	// so it is called out at the point of the omission, not just above it.
}

func requestFromRepo(r repository.MeetupRequest) MeetupRequest {
	return MeetupRequest{
		ID:                       r.ID,
		MeetupID:                 r.MeetupID,
		RequesterID:              r.RequesterID,
		RequesterFullName:        r.RequesterFullName,
		RequesterProfilePhotoURL: r.RequesterProfilePhotoURL,
		RequesterTrustLevel:      r.RequesterTrustLevel,
		RequesterRatingAverage:   r.RequesterRatingAverage,
		RequesterRatingCount:     r.RequesterRatingCount,
		Status:                   RequestStatus(r.Status),
		AutoRejected:             r.AutoRejected,
		CreatedAt:                r.CreatedAt,
		ResolvedAt:               r.ResolvedAt,
		WithdrawalNote:           r.WithdrawalNote,
		CheckedInAt:              r.CheckedInAt,
		DeclinedAt:               r.DeclinedAt,
		DeclineReason:            r.DeclineReason,
	}
}

func requestsFromRepo(requests []repository.MeetupRequest) []MeetupRequest {
	out := make([]MeetupRequest, 0, len(requests))
	for _, r := range requests {
		out = append(out, requestFromRepo(r))
	}
	return out
}

func safetyStateFromRepo(s repository.SafetyState) SafetyState {
	return SafetyState{
		MeetupID:          s.MeetupID,
		ChecklistAckAt:    s.ChecklistAckAt,
		LiveLocationOptIn: s.LiveLocationOptIn,
		CheckedInAt:       s.CheckedInAt,
		DeclinedAt:        s.DeclinedAt,
		DeclineReason:     s.DeclineReason,
	}
}

func ratableParticipantsFromRepo(participants []repository.RatableParticipant) []RatableParticipant {
	out := make([]RatableParticipant, 0, len(participants))
	for _, p := range participants {
		out = append(out, RatableParticipant{
			UserID:          p.UserID,
			FullName:        p.FullName,
			ProfilePhotoURL: p.ProfilePhotoURL,
			TrustLevel:      p.TrustLevel,
			AlreadyRated:    p.AlreadyRated,
			ContextNote:     p.ContextNote,
		})
	}
	return out
}
