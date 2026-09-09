package meetup

import (
	"context"
	"fmt"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// requireParticipant is the Safety Gate's authorization check: the caller
// must be this meetup's host or an accepted requester on it. Every one of
// the five Safety Gate methods calls it before reading or mutating
// anything — without it, any authenticated user could read or forge another
// meetup's safety state just by guessing its id (meetup ids are not secret;
// they appear throughout the app).
//
// MECHANISM — worth being precise, because it differs slightly from the
// source. The source's equivalent infers participation from the existence of
// a safety_state row for (meetup_id, user_id), on the reasoning that a row
// is only ever created for the host (at creation) and for accepted
// requesters (at accept-time), so "no row" means "never a participant".
// That is sound, and it is what its own ADR chose deliberately.
//
// This port instead asks the question directly, via the same
// `IsParticipant` query the ratings code uses (host OR accepted requester,
// straight from meetups/meetup_requests). Same authorization outcome, and
// the phase plan asks for this shape specifically — but it is also strictly
// more robust: it derives participation from the authoritative tables rather
// than from a side-table row's presence, so a genuine participant whose row
// was somehow never created is not silently denied access to their own
// meetup's safety flow. EnsureExists is still called at both source call
// sites, so the row exists to read and write.
//
// "Not a participant" is Forbidden, not NotFound: the caller did not fail to
// find a real resource, they were never allowed to look.
func (s *service) requireParticipant(ctx context.Context, meetupID, userID string) error {
	isParticipant, err := s.ratings.IsParticipant(ctx, meetupID, userID)
	if err != nil {
		return err
	}
	if !isParticipant {
		return fmt.Errorf("meetup: caller is not a participant of meetup %s: %w", meetupID, apperror.ErrForbidden)
	}
	return nil
}

// GetSafetyState returns only the caller's own row — it was never meant to
// expose every participant's status to everyone. A host's visibility into
// other participants' check-in status goes through the request list instead.
func (s *service) GetSafetyState(ctx context.Context, req SafetyStateRequest) (SafetyState, error) {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}
	state, err := s.safetyState.Get(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}

	out := safetyStateFromRepo(state)

	// Who already knows about this meetup. Read on every safety-state fetch
	// so reopening the screen shows what was actually done, rather than
	// offering to share again as if nothing had happened.
	shared, err := s.safetyState.ListShareContactIDs(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}
	out.SharedWithContactIDs = shared

	return out, nil
}

func (s *service) AcknowledgeSafetyChecklist(ctx context.Context, req SafetyStateRequest) (SafetyState, error) {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}
	state, err := s.safetyState.AcknowledgeChecklist(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromRepo(state), nil
}

func (s *service) SetLiveLocationOptIn(ctx context.Context, req SetLiveLocationOptInRequest) (SafetyState, error) {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}
	state, err := s.safetyState.SetLiveLocationOptIn(ctx, req.MeetupID, req.UserID, req.OptIn)
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromRepo(state), nil
}

// CheckIn enforces the step order server-side (checklist before check-in),
// not just relying on the client's screen sequencing — a client that skips
// straight to check-in (a bug, or a modified client) must not bypass the
// checklist. Also rejects if the caller already declined: check-in and
// decline are mutually exclusive terminal states.
func (s *service) CheckIn(ctx context.Context, req SafetyStateRequest) (SafetyState, error) {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}

	current, err := s.safetyState.Get(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}
	if current.ChecklistAckAt == nil {
		return SafetyState{}, fmt.Errorf("meetup: safety checklist must be acknowledged before check-in: %w", apperror.ErrConflict)
	}
	if current.DeclinedAt != nil {
		return SafetyState{}, fmt.Errorf("meetup: cannot check in after declining: %w", apperror.ErrConflict)
	}

	state, err := s.safetyState.CheckIn(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}
	return safetyStateFromRepo(state), nil
}

// DeclineCheckIn lets a participant decline at the checklist/check-in stage
// instead of silently not checking in, with a required reason. Mutually
// exclusive with CheckIn. Notifies the host on success — unless the decliner
// IS the host, since notifying yourself about your own action is noise.
func (s *service) DeclineCheckIn(ctx context.Context, req DeclineCheckInRequest) (SafetyState, error) {
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		return SafetyState{}, fmt.Errorf("meetup: reason is required: %w", apperror.ErrInvalidInput)
	}
	if len(reason) > maxFreeTextReasonLength {
		return SafetyState{}, fmt.Errorf("meetup: reason is too long: %w", apperror.ErrInvalidInput)
	}

	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}

	current, err := s.safetyState.Get(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}
	if current.CheckedInAt != nil {
		return SafetyState{}, fmt.Errorf("meetup: cannot decline after already checking in: %w", apperror.ErrConflict)
	}

	// host_user_id isn't on the safety row — fetch the meetup BEFORE the
	// write so the host is known when the notification is composed inside
	// Decline's own transaction (§F3). Same harmless-placeholder viewer id
	// as WithdrawRequest's own lookup: only MyRequestStatus depends on it,
	// and this call site never reads that.
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}

	state, err := s.safetyState.Decline(ctx, req.MeetupID, req.UserID, reason,
		func(ctx context.Context, tx repository.NotifyTx, _ repository.SafetyState) error {
			// A host declining their own meetup's checklist has nobody to
			// notify — telling them about themselves is noise.
			if m.HostUserID == req.UserID {
				return nil
			}
			return queueNotification(ctx, tx, m.HostUserID,
				TypeParticipantDeclined,
				"Participant declined",
				fmt.Sprintf("A participant declined the safety checklist for your %s meetup: %s", m.Intent, reason),
				map[string]string{"meetup_id": m.ID},
			)
		})
	if err != nil {
		return SafetyState{}, err
	}

	s.notifyPollerWake()
	return safetyStateFromRepo(state), nil
}

// SubmitMeetupFeedback records the post-meetup questions.
//
// FeltSafe/ProfileAccurate/WouldMeetAgain are only meaningful when the
// meetup actually happened — a "didn't happen" report must never be misread
// as "happened but felt unsafe", so they are dropped in that case rather
// than written as real negative answers. Notes is never gated on Happened: a
// note is meaningful either way (e.g. "never showed up").
//
// # WHY THE TWO GUARDS BELOW
//
// This call had neither, and it is not a low-stakes write: a row here with
// Happened=true is precisely what HasConfirmedHappened reads, which is
// SubmitRating's first eligibility branch. So "I attended this" was the
// unguarded door to "I may now rate everyone on it".
//
//   - Participation: without it any authenticated user could file feedback
//     on a meetup they had nothing to do with. SubmitRating's own
//     IsParticipant check kept that from becoming a rating, but a stranger
//     writing safety feedback on someone else's meetup is its own problem.
//   - The window having started: a meetup scheduled for next week has not
//     happened, and no honest answer to "how did it go?" exists yet.
//     Without this a participant could mark a future meetup as attended and
//     rate people they had not met. WindowStart, not WindowEnd, so someone
//     can report a no-show without waiting out the full window.
func (s *service) SubmitMeetupFeedback(ctx context.Context, req SubmitMeetupFeedbackRequest) error {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return err
	}
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return err
	}
	if time.Now().Before(m.WindowStart) {
		return fmt.Errorf("meetup: %s has not started yet: %w", req.MeetupID, apperror.ErrConflict)
	}

	var feltSafe, profileAccurate, wouldMeetAgain *bool
	if req.Happened {
		feltSafe = req.FeltSafe
		profileAccurate = req.ProfileAccurate
		wouldMeetAgain = req.WouldMeetAgain
	}
	return s.feedback.Upsert(ctx, req.MeetupID, req.UserID, req.Happened, feltSafe, profileAccurate, wouldMeetAgain, req.Notes)
}

// ShareWithContacts tells the caller's chosen trusted contacts where and
// when this meetup is, then records who was told.
//
// # WHAT THIS REPLACES
//
// SetLiveLocationOptIn wrote a boolean nothing read. The switch said the
// app was sharing the user's location and the app shared it with nobody —
// a safety feature that only appeared to work, which is worse than not
// offering one.
//
// # WHY THE FACTS ARE READ HERE AND NOT ACCEPTED FROM THE CLIENT
//
// The window, label and coordinates come off the meetup row inside this
// call. A client supplies only which of ITS OWN contacts to tell, so the
// worst a modified client can do is notify its own trusted contacts about a
// meetup it genuinely participates in. It cannot compose the message, and
// it cannot reach anyone else's contacts (the auth module intersects the
// ids against the caller's own list).
//
// The record is written only for contacts that were actually notified, and
// AFTER the send: a row here means "this person was told", so writing it
// for a failed send would show the user a reassurance that is not true.
func (s *service) ShareWithContacts(ctx context.Context, req ShareWithContactsRequest) (SafetyState, error) {
	if err := s.requireParticipant(ctx, req.MeetupID, req.UserID); err != nil {
		return SafetyState{}, err
	}
	if len(req.ContactIDs) == 0 {
		return SafetyState{}, fmt.Errorf("meetup: pick at least one trusted contact: %w", apperror.ErrInvalidInput)
	}
	if s.contactNotifier == nil {
		// Explicit, not silent. The old switch's whole failure was telling
		// the user something happened when nothing did.
		return SafetyState{}, fmt.Errorf("meetup: contact sharing is not configured: %w", apperror.ErrInternal)
	}

	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.UserID)
	if err != nil {
		return SafetyState{}, err
	}

	notified, err := s.contactNotifier.NotifyMeetupShare(ctx, req.UserID, ContactShare{
		ContactIDs:    req.ContactIDs,
		LocationLabel: m.LocationLabel,
		Latitude:      m.LocationLat,
		Longitude:     m.LocationLng,
		WindowStart:   m.WindowStart,
		WindowEnd:     m.WindowEnd,
	})
	if err != nil {
		return SafetyState{}, err
	}
	if notified == 0 {
		return SafetyState{}, fmt.Errorf("meetup: could not reach any of those contacts: %w", apperror.ErrInternal)
	}

	// Recorded per contact so a later "share with one more" adds to the set
	// rather than replacing it.
	for _, contactID := range req.ContactIDs {
		if err := s.safetyState.RecordShare(ctx, req.MeetupID, req.UserID, contactID); err != nil {
			// The message already went out; failing the whole call here
			// would tell the user nothing happened when it did. Logged and
			// carried on, and the read below reports what actually stuck.
			s.logger.Error("record safety share", "meetup_id", req.MeetupID, "error", err)
		}
	}

	return s.GetSafetyState(ctx, SafetyStateRequest{MeetupID: req.MeetupID, UserID: req.UserID})
}
