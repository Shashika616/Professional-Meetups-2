package meetup

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// CloseMeetup is the host-only "meetup is done" action. The repository's
// Close does the entire authorization/precondition check (right host,
// currently open-ish, window started) as a single UPDATE ... WHERE — no
// separate check-then-act a concurrent request could race. Zero rows updated
// surfaces as ErrNotFound; re-fetching distinguishes *why* for a useful
// message, without a second authoritative check duplicating the query.
//
// Explicitly does not touch rating eligibility — that gate is each
// participant's own feedback.happened, independent of status. Closing is an
// organizational move, not a new security gate.
func (s *service) CloseMeetup(ctx context.Context, req CloseMeetupRequest) (Meetup, error) {
	// Everyone's "meetup ended" notice is queued inside Close's own
	// transaction (§F3) — the close and the notifications about it commit
	// together. notifyMeetupClosed is shared with the auto-close sweep so
	// the manual and automatic paths can never drift on what gets sent.
	if _, err := s.meetups.Close(ctx, req.MeetupID, req.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, closed repository.Meetup) error {
			return s.queueMeetupClosed(ctx, tx, closed)
		},
	); err != nil {
		if errors.Is(err, apperror.ErrNotFound) {
			current, getErr := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
			if getErr != nil {
				return Meetup{}, getErr
			}
			switch {
			case current.HostUserID != req.HostUserID:
				return Meetup{}, fmt.Errorf("meetup: only the host can close this meetup: %w", apperror.ErrForbidden)
			case current.Status != repository.MeetupStatusOpen && current.Status != repository.MeetupStatusFull:
				return Meetup{}, fmt.Errorf("meetup: already closed or cancelled: %w", apperror.ErrConflict)
			case time.Now().Before(current.WindowStart):
				return Meetup{}, fmt.Errorf("meetup: can't close before the meetup's window has started: %w", apperror.ErrForbidden)
			}
		}
		return Meetup{}, err
	}

	s.notifyPollerWake()
	s.wakeBilling()

	// Close's own RETURNING has no host display info to join against —
	// re-fetch the fully-populated view for the response.
	full, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return Meetup{}, err
	}

	return meetupFromRepo(full, req.HostUserID), nil
}

// queueMeetupClosed queues the "meetup ended — rate your experience" push
// for the host and every accepted participant, on the transaction that
// closed the meetup.
//
// Shared by CloseMeetup's manual path and the auto-close sweep, so the two
// can never drift on what gets sent — the one behaviour §E4's checklist
// specifically calls out as needing to be identical from either direction.
//
// The participant list is read on the SAME transaction as the close. That is
// not incidental: reading it afterwards, on another connection, could
// observe a request accepted or withdrawn in between and notify a set that
// never matched the close it is describing.
func (s *service) queueMeetupClosed(ctx context.Context, tx repository.NotifyTx, m repository.Meetup) error {
	participants, err := tx.ListRequestsForMeetup(ctx, m.ID)
	if err != nil {
		return err
	}

	body := fmt.Sprintf("Your %s meetup has ended. Rate your experience!", Intent(m.Intent).DisplayName())
	data := map[string]string{"meetup_id": m.ID}

	// The host and the participants get identical copy, so they are queued
	// as one recipient set rather than a special case plus a loop.
	recipients := append([]string{m.HostUserID}, acceptedRequesters(participants)...)
	_, err = queueNotifications(ctx, tx, recipients, TypeMeetupClosed, "Meetup ended", body, data)
	return err
}

// NotifyStartingSoonSweep is one tick of the poller's starting-soon sweep.
//
// The claim and every reminder it produces are one transaction (§C2 + §F3):
// ClaimMeetupsStartingSoon sets the de-dup guard in the same statement that
// selects the rows, under FOR UPDATE SKIP LOCKED, and the notifications are
// queued before that transaction commits. A second monolith instance ticking
// at the same moment claims a disjoint set rather than re-notifying the same
// meetups, and there is no state in which a meetup is marked notified but
// its reminder was never queued.
func (s *service) NotifyStartingSoonSweep(ctx context.Context) (int, error) {
	claimed, err := s.meetups.ClaimStartingSoon(ctx, sweepBatchSize,
		func(ctx context.Context, tx repository.NotifyTx, ms []repository.Meetup) error {
			for _, m := range ms {
				participants, err := tx.ListRequestsForMeetup(ctx, m.ID)
				if err != nil {
					return err
				}
				recipients := append([]string{m.HostUserID}, acceptedRequesters(participants)...)
				if _, err := queueNotifications(ctx, tx, recipients,
					TypeMeetupStartingSoon,
					"Meetup starting soon",
					fmt.Sprintf("Your %s meetup starts soon. Review your safety checklist.", Intent(m.Intent).DisplayName()),
					map[string]string{"meetup_id": m.ID},
				); err != nil {
					return err
				}
			}
			return nil
		})
	if err != nil {
		return 0, fmt.Errorf("meetup: claim starting-soon batch: %w", err)
	}
	if len(claimed) > 0 {
		s.notifyPollerWake()
	}
	return len(claimed), nil
}

// AutoCloseSweep is one tick of the poller's auto-close sweep — the same
// claim-and-queue-in-one-transaction shape as NotifyStartingSoonSweep, and
// the same queueMeetupClosed helper CloseMeetup's manual path uses, so a
// meetup that ends on its own and one the host closes by hand produce
// byte-identical notifications.
func (s *service) AutoCloseSweep(ctx context.Context) (int, error) {
	claimed, err := s.meetups.ClaimReadyToAutoClose(ctx, sweepBatchSize,
		func(ctx context.Context, tx repository.NotifyTx, ms []repository.Meetup) error {
			for _, m := range ms {
				if err := s.queueMeetupClosed(ctx, tx, m); err != nil {
					return err
				}
			}
			return nil
		})
	if err != nil {
		return 0, fmt.Errorf("meetup: claim auto-close batch: %w", err)
	}
	if len(claimed) > 0 {
		s.notifyPollerWake()
		s.wakeBilling()
	}
	return len(claimed), nil
}

// CancelMeetup is host-only with a required reason. A meetup with confirmed
// participants can be cancelled — each is notified, and each gains a
// rating-eligibility path against the host.
func (s *service) CancelMeetup(ctx context.Context, req CancelMeetupRequest) error {
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		return fmt.Errorf("meetup: reason is required: %w", apperror.ErrInvalidInput)
	}
	if len(reason) > maxFreeTextReasonLength {
		return fmt.Errorf("meetup: reason is too long: %w", apperror.ErrInvalidInput)
	}

	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.HostUserID)
	if err != nil {
		return err
	}
	if m.HostUserID != req.HostUserID {
		return fmt.Errorf("meetup: caller does not host meetup %s: %w", req.MeetupID, apperror.ErrForbidden)
	}

	// Every accepted requester's cancellation notice is queued inside
	// Cancel's own transaction (§F3). This is the call site where that
	// matters most: a cancellation the participants are never told about is
	// people showing up to a meetup that is not happening.
	if _, err := s.meetups.Cancel(ctx, req.MeetupID, reason, req.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, cancelled repository.Meetup) error {
			participants, err := tx.ListRequestsForMeetup(ctx, cancelled.ID)
			if err != nil {
				return err
			}
			_, err = queueNotifications(ctx, tx, acceptedRequesters(participants),
				TypeMeetupCancelled,
				"Meetup cancelled",
				fmt.Sprintf("The host cancelled your %s meetup: %s", Intent(m.Intent).DisplayName(), reason),
				map[string]string{"meetup_id": m.ID},
			)
			return err
		},
	); err != nil {
		return err
	}

	s.notifyPollerWake()
	s.wakeBilling()
	return nil
}
