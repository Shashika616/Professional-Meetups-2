package meetup

import (
	"context"
	"errors"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// NearbyNotifyPayload is what HandleMeetupCreated needs off the
// meetup-created event. A struct of its own rather than taking the bus's
// payload type directly, so the module's interface doesn't expose the
// eventbus package — cmd/monolith does that translation in one place, the
// same way internal/grpcapi translates protobuf.
type NearbyNotifyPayload struct {
	MeetupID    string
	HostUserID  string
	Intent      string
	LocationLat float64
	LocationLng float64
}

// HandleMeetupCreated is the nearby-notify fan-out: everyone with a
// non-stale cached location within 50 km of the new meetup, excluding the
// host, gets one push.
//
// Per-recipient failures are already log-and-continue by construction — the
// batch sender skips recipients with no registered device rather than
// failing, and a publish error returns without touching the ones already
// sent. The bus itself also logs and swallows a handler error, so a failure
// here can never fail the CreateMeetup that triggered it.
func (s *service) HandleMeetupCreated(ctx context.Context, payload NearbyNotifyPayload) error {
	// Counted after the insert, so the meetup that triggered this is
	// included: the first nearbyNotifyMaxPerHostPerDay notify, later ones
	// do not.
	created, err := s.meetups.CountCreatedByHostSince(ctx, payload.HostUserID, time.Now().Add(-24*time.Hour))
	if err != nil {
		return fmt.Errorf("meetup: count host's meetups for nearby notify: %w", err)
	}
	if created > nearbyNotifyMaxPerHostPerDay {
		s.logger.Info("nearby-notify skipped: host over daily fan-out cap",
			"meetup_id", payload.MeetupID, "created_today", created)
		return nil
	}

	nearby, err := s.userLocations.ListWithinRadius(ctx, payload.LocationLat, payload.LocationLng, time.Now().Add(-nearbyNotifyStaleness))
	if err != nil {
		return fmt.Errorf("meetup: list nearby users for meetup-created notify: %w", err)
	}

	recipients := make([]string, 0, len(nearby))
	for _, u := range nearby {
		// The host already knows about their own meetup.
		if u.UserID == payload.HostUserID {
			continue
		}
		recipients = append(recipients, u.UserID)
	}
	if len(recipients) == 0 {
		return nil
	}

	// The one publisher with no business write of its own to be atomic with:
	// this runs as an event handler, after CreateMeetup has already
	// committed. It still queues through the outbox rather than sending
	// directly, so the fan-out gets the same retry, backoff and dead-letter
	// treatment as every other notification — and its own transaction means
	// a fan-out can never be half-queued.
	var notified int
	if err := s.outbox.WithinTx(ctx, func(ctx context.Context, tx repository.NotifyTx) error {
		var err error
		notified, err = queueNotifications(ctx, tx, recipients,
			TypeMeetupNearby,
			"New meetup nearby",
			fmt.Sprintf("A new %s meetup was just scheduled near you", Intent(payload.Intent).DisplayName()),
			map[string]string{"meetup_id": payload.MeetupID},
		)
		return err
	}); err != nil {
		return fmt.Errorf("meetup: notify nearby users: %w", err)
	}
	s.notifyPollerWake()
	s.logger.Info("nearby-notify fan-out", "meetup_id", payload.MeetupID, "candidates", len(recipients), "notified", notified)
	return nil
}

func (s *service) CheckAccountDeletable(ctx context.Context, userID string) error {
	c, err := s.meetups.ActiveCommitments(ctx, userID)
	if err != nil {
		return err
	}
	if !c.Any() {
		return nil
	}
	return fmt.Errorf("%s: %w", describeCommitments(c), apperror.ErrConflict)
}

// describeCommitments is the sentence the app shows when deletion is refused.
// It names what is outstanding and what to do about it, because "you cannot
// delete your account" with neither is a dead end, and App Store 5.1.1(v)
// does not allow deletion to be a dead end. Every branch ends in the step
// that unblocks it.
func describeCommitments(c repository.ActiveCommitments) string {
	switch {
	case c.Hosting > 0 && c.Accepted+c.Pending > 0:
		return "You have meetups coming up. Attend them, or cancel the ones you are hosting and withdraw your requests, then delete your account"
	case c.Hosting > 1:
		return "You are hosting meetups that have not happened yet. Attend them, or cancel them, then delete your account"
	case c.Hosting == 1:
		return "You are hosting a meetup that has not happened yet. Attend it, or cancel it, then delete your account"
	case c.Accepted > 0 && c.Pending > 0:
		return "You are joining meetups and have requests waiting. Attend or cancel them, and withdraw your requests, then delete your account"
	case c.Accepted > 1:
		return "You are joining meetups that have not happened yet. Attend them, or cancel them, then delete your account"
	case c.Accepted == 1:
		return "You are joining a meetup that has not happened yet. Attend it, or cancel it, then delete your account"
	case c.Pending > 1:
		return "You have requests to join meetups that are still open. Withdraw them, then delete your account"
	default:
		return "You have a request to join a meetup that is still open. Withdraw it, then delete your account"
	}
}

// deletedHostCancelReason is what attendees see, in the push and in the
// cancellation banner, when a meetup is cancelled because its host deleted
// their account. It has to read naturally after "The host cancelled your X
// meetup: ", which is how the ordinary cancel push frames any reason.
const deletedHostCancelReason = "Their account has been closed."

func (s *service) HandleUserDeleted(ctx context.Context, p eventbus.UserDeletedPayload) error {
	// Meetups they still host come first, and go through the ordinary cancel
	// path, so the people attending are told. The gateway refuses deletion
	// while any exist, so this is normally empty: it is for the one created
	// in the gap between that check and the delete.
	ids, err := s.meetups.ListLiveHostedMeetupIDs(ctx, p.UserID)
	if err != nil {
		return err
	}
	for _, id := range ids {
		err := s.CancelMeetup(ctx, CancelMeetupRequest{
			MeetupID:   id,
			HostUserID: p.UserID,
			Reason:     deletedHostCancelReason,
		})
		// Already cancelled, ended or gone between the list and here, which
		// on a retried delivery is the expected case. Anything else is a real
		// failure and goes back to the outbox to retry.
		if err != nil && !errors.Is(err, apperror.ErrConflict) && !errors.Is(err, apperror.ErrNotFound) {
			return err
		}
	}
	return s.meetups.PurgeUser(ctx, p.UserID)
}

// SweepStaleUserLocations deletes cached locations older than 30 days
// (plan 30B, 3.3).
func (s *service) SweepStaleUserLocations(ctx context.Context) (int, error) {
	if s.retention == nil {
		return 0, nil
	}
	n, err := s.retention.DeleteStaleUserLocations(ctx)
	return int(n), err
}

// SweepOldMeetupCoordinates reduces the coordinates of meetups that ended
// more than 180 days ago to about 1 km (D4).
func (s *service) SweepOldMeetupCoordinates(ctx context.Context) (int, error) {
	if s.retention == nil {
		return 0, nil
	}
	n, err := s.retention.CoarsenOldMeetupCoordinates(ctx)
	return int(n), err
}
