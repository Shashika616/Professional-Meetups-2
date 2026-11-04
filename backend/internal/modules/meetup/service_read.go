package meetup

import (
	"context"
	"fmt"
	"sort"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/geo"
)

func (s *service) GetMeetup(ctx context.Context, req GetMeetupRequest) (Meetup, error) {
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return Meetup{}, err
	}
	out := meetupFromRepo(m, req.UserID)

	// Closes the redaction bypass ListOpenMeetups' own locked card leaves
	// open: that deliberately keeps meetup_id visible (the join button needs
	// a target), so without redaction here a caller could read the id off
	// their own locked browse response and fetch full data for it directly.
	//
	// The participation exception is applied here at the call site rather
	// than inside redactForViewer: unlike ListMyMeetups/ListActiveMeetups,
	// which only ever return meetups the viewer already belongs to, this is
	// reachable for any meetup id. A host or accepted participant must never
	// have their own meetup's data redacted from themselves.
	//
	// ADR-002 §5 makes this MOOT for the guest tier specifically — a Level 0
	// account can never legitimately host or join anything, so it can never
	// satisfy IsParticipant — but the exception is retained unchanged and
	// still load-bearing for Level 2/3 users: if an intent's required level
	// is ever raised again after a meetup under it already exists (exactly
	// what ADR-002 just did to hosting), someone who legitimately joined at
	// the old threshold would otherwise lose sight of their own meetup.
	//
	// A pending (not yet accepted) request does NOT satisfy this,
	// deliberately — someone who has merely expressed interest is not a
	// participant and should see the same locked view as any other stranger.
	isParticipant, err := s.ratings.IsParticipant(ctx, req.MeetupID, req.UserID)
	if err != nil {
		// Fails closed: a transient error checking participation must not
		// accidentally skip redaction.
		s.logger.Error("check meetup participant for GetMeetup redaction", "error", err)
		isParticipant = false
	}
	if !isParticipant {
		redactForViewer(&out, req.ViewerTrustLevel)
		s.withholdCoordinates(ctx, &out, m, req)
	}
	return out, nil
}

// withholdCoordinates removes a meetup's exact coordinates from someone who
// is not on it, unless they are a member whose recent location is within
// the browse radius (plan 30B, 3.3, #108). For a "use my current location"
// meetup the coordinates are where the host was standing, and before this
// any caller anywhere could read them by id. A guest never gets them. The
// place label stays: it is what the host chose to publish.
func (s *service) withholdCoordinates(ctx context.Context, out *Meetup, m repository.Meetup, req GetMeetupRequest) {
	if req.ViewerTrustLevel >= visibilityFloor {
		within, known, err := s.userLocations.WithinBrowseRadius(ctx, req.UserID, m.LocationLat, m.LocationLng)
		if err != nil {
			// Fails closed, like the participation check above.
			s.logger.Error("check viewer distance for GetMeetup", "error", err)
		} else if known && within {
			return
		}
	}
	out.LocationLat, out.LocationLng = nil, nil
}

// maxWithinDays caps how far out a "starting within N days" filter may reach.
// Not a security boundary — an unrestricted list is still available by passing
// 0 — just a guard against a client sending a nonsense interval that Postgres
// would then have to reason about. A year is far past any real use.
const maxWithinDays = 365

func (s *service) ListOpenMeetups(ctx context.Context, req ListOpenMeetupsRequest) (ListOpenMeetupsResult, error) {
	// A nil intent is the "All" case and is valid; a non-nil one must still
	// name a real intent. Validated here rather than left to the database's
	// enum cast so the caller gets ErrInvalidInput rather than a 500.
	if req.Intent != nil && !validIntent(*req.Intent) {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: unrecognized intent: %w", apperror.ErrInvalidInput)
	}
	if req.WithinDays < 0 || req.WithinDays > maxWithinDays {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: within_days must be between 0 and %d: %w", maxWithinDays, apperror.ErrInvalidInput)
	}

	cursor, err := decodeCursor(req.Cursor)
	if err != nil {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: invalid cursor: %w", apperror.ErrInvalidInput)
	}

	// Viewer coordinates flow into the ST_DWithin filter — validated rather
	// than passed through unchecked.
	if err := geo.ValidateLatLng(req.ViewerLat, req.ViewerLng); err != nil {
		return ListOpenMeetupsResult{}, fmt.Errorf("meetup: %v: %w", err, apperror.ErrInvalidInput)
	}

	filter := repository.OpenMeetupFilter{WithinDays: req.WithinDays}
	if req.Intent != nil {
		intent := repository.Intent(*req.Intent)
		filter.Intent = &intent
	}

	meetups, next, err := s.meetups.ListOpen(ctx, filter, req.UserID, req.ViewerLat, req.ViewerLng, cursor, req.PageSize)
	if err != nil {
		return ListOpenMeetupsResult{}, err
	}

	// Redaction against the viewer's own gateway-sourced trust level. No
	// longer per-intent (ADR-002 §5): visibility is a flat Level 0 vs. 1+
	// question now, so every meetup in the page gets the same treatment and
	// the loop is only here because the field-nulling is per-struct.
	out := meetupsFromRepo(meetups, req.UserID)
	for i := range out {
		redactForViewer(&out[i], req.ViewerTrustLevel)
	}

	return ListOpenMeetupsResult{Meetups: out, NextCursor: encodeCursor(next)}, nil
}

func (s *service) ListMyMeetups(ctx context.Context, req ListMyMeetupsRequest) (ListMyMeetupsResult, error) {
	// Hosted and requested paginate independently — unrelated sets, separate
	// cursors.
	hostedCursor, err := decodeCursor(req.HostedCursor)
	if err != nil {
		return ListMyMeetupsResult{}, fmt.Errorf("meetup: invalid hosted_cursor: %w", apperror.ErrInvalidInput)
	}
	requestedCursor, err := decodeCursor(req.RequestedCursor)
	if err != nil {
		return ListMyMeetupsResult{}, fmt.Errorf("meetup: invalid requested_cursor: %w", apperror.ErrInvalidInput)
	}

	hosted, hostedNext, err := s.meetups.ListByHost(ctx, req.UserID, hostedCursor, 0)
	if err != nil {
		return ListMyMeetupsResult{}, err
	}
	requested, requestedNext, err := s.meetups.ListRequestedByUser(ctx, req.UserID, requestedCursor, 0)
	if err != nil {
		return ListMyMeetupsResult{}, err
	}

	return ListMyMeetupsResult{
		Hosted:              meetupsFromRepo(hosted, req.UserID),
		Requested:           meetupsFromRepo(requested, req.UserID),
		HostedNextCursor:    encodeCursor(hostedNext),
		HostedHasMore:       hostedNext != nil,
		RequestedNextCursor: encodeCursor(requestedNext),
		RequestedHasMore:    requestedNext != nil,
	}, nil
}

// ListActiveMeetups merges "I'm host" and "I'm an accepted participant" into
// one server-sorted (soonest window_start first) list, scoped to
// status IN ('open','full') AND window_end >= now(). Reuses the same two
// repository calls ListMyMeetups makes rather than a new combined query —
// the decision of what counts as active stays entirely server-side (the
// filter below); only the merge-and-sort happens in Go.
func (s *service) ListActiveMeetups(ctx context.Context, userID string) ([]Meetup, error) {
	hosted, _, err := s.meetups.ListByHost(ctx, userID, nil, 0)
	if err != nil {
		return nil, err
	}
	requested, _, err := s.meetups.ListRequestedByUser(ctx, userID, nil, 0)
	if err != nil {
		return nil, err
	}

	now := time.Now()

	// Meetups whose window has ended and that this user still owes a review
	// on. They stay on Home so the review prompt survives long enough to be
	// used — it used to appear the moment the window passed and vanish on
	// the very next refresh, because the filter below dropped anything whose
	// window had ended. Bounded by reviewWindow so an ignored review does
	// not sit here forever.
	awaitingIDs, err := s.feedback.IDsAwaitingReview(ctx, userID, now.Add(-reviewWindow))
	if err != nil {
		return nil, err
	}
	awaiting := make(map[string]bool, len(awaitingIDs))
	for _, id := range awaitingIDs {
		awaiting[id] = true
	}

	// Live: still open/full and not yet over. Awaiting: over, unreviewed,
	// and inside the window. A cancelled meetup is neither — there is
	// nothing to attend and nothing to review.
	//
	// The same LIVE definition is written in SQL by FindScheduleConflict
	// (meetups.sql), and its narrower BROWSABLE form ('open' only) by
	// ListOpenMeetupsFirstPage/AfterCursor. A change here must be made
	// there too.
	isLive := func(m repository.Meetup) bool {
		return (m.Status == repository.MeetupStatusOpen || m.Status == repository.MeetupStatusFull) &&
			m.WindowEnd.After(now)
	}
	include := func(m repository.Meetup) bool {
		return isLive(m) || awaiting[m.ID]
	}

	seen := make(map[string]bool)
	var active []repository.Meetup
	for _, m := range hosted {
		if !include(m) || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		active = append(active, m)
	}
	for _, m := range requested {
		if !include(m) || seen[m.ID] {
			continue
		}
		// Only an accepted request counts as "I'm active in this meetup" — a
		// pending/rejected/withdrawn one doesn't belong on the dashboard.
		if m.MyRequestStatus == nil || *m.MyRequestStatus != repository.RequestStatusAccepted {
			continue
		}
		seen[m.ID] = true
		active = append(active, m)
	}

	// Live meetups first, soonest-first among them, so the card the user
	// swipes to first is always the one that is next — a newly created
	// meetup takes the front of the deck ahead of anything merely waiting to
	// be reviewed. Reviews follow, most recently finished first, which is
	// the order someone would actually want to write them in.
	sort.SliceStable(active, func(i, j int) bool {
		a, b := active[i], active[j]
		aLive, bLive := isLive(a), isLive(b)
		if aLive != bLive {
			return aLive
		}
		if aLive {
			return a.WindowStart.Before(b.WindowStart)
		}
		return a.WindowEnd.After(b.WindowEnd)
	})

	return meetupsFromRepo(active, userID), nil
}

func (s *service) ListMeetupRequests(ctx context.Context, req ListMeetupRequestsRequest) ([]MeetupRequest, error) {
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return nil, err
	}
	if m.HostUserID != req.HostUserID {
		return nil, fmt.Errorf("meetup: caller does not host meetup %s: %w", req.MeetupID, apperror.ErrForbidden)
	}

	requests, err := s.requests.ListForMeetup(ctx, req.MeetupID)
	if err != nil {
		return nil, err
	}
	return requestsFromRepo(requests), nil
}
