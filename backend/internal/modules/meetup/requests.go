package meetup

import (
	"context"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

func (s *service) RequestToJoin(ctx context.Context, req RequestToJoinRequest) (MeetupRequest, error) {
	m, err := s.meetups.GetByID(ctx, req.MeetupID, req.RequesterID)
	if err != nil {
		return MeetupRequest{}, err
	}

	if m.HostUserID == req.RequesterID {
		return MeetupRequest{}, fmt.Errorf("meetup: cannot request to join your own meetup: %w", apperror.ErrForbidden)
	}
	// The JOIN bar (ADR-002 §4) — unchanged at Level 2 for ordinary intents.
	if err := checkTrustLevel(Intent(m.Intent), req.RequesterTrustLevel,
		requiredTrustLevelToJoin(Intent(m.Intent)), "joining"); err != nil {
		return MeetupRequest{}, err
	}
	if m.Status != repository.MeetupStatusOpen {
		return MeetupRequest{}, fmt.Errorf("meetup: meetup %s is not open: %w", req.MeetupID, apperror.ErrConflict)
	}

	// The host's notification is composed and queued INSIDE Create's own
	// transaction (§F3), so the request row and the notification of it are a
	// single atomic fact: there is no longer a window in which the request
	// exists but the host will never hear about it.
	//
	// The requester's display name comes from a read on that same
	// transaction — reading it afterwards, on another connection, would be
	// a subtler version of the same race this whole change removes.
	created, err := s.requests.Create(ctx, req.MeetupID, req.RequesterID, m.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, created repository.MeetupRequest) error {
			full, err := tx.GetRequestByID(ctx, created.ID)
			if err != nil {
				return err
			}
			return queueNotification(ctx, tx, m.HostUserID,
				TypeJoinRequest,
				"New join request",
				fmt.Sprintf("%s wants to join your %s meetup", full.RequesterFullName, m.Intent),
				map[string]string{"meetup_id": m.ID, "request_id": created.ID},
			)
		})
	if err != nil {
		return MeetupRequest{}, err
	}
	s.notifyPollerWake()

	// Create's return value has no requester display info — GetByID
	// re-fetches the joined view for the response.
	full, err := s.requests.GetByID(ctx, created.ID)
	if err != nil {
		return MeetupRequest{}, err
	}

	return requestFromRepo(full), nil
}

// WithdrawRequest withdraws a pending or already-accepted request, with an
// optional note. Notifies the meetup's host and unlocks a rating-eligibility
// path letting the host rate this requester once.
//
// Ownership is checked twice on purpose: here in Go, and again in the
// UPDATE's own `WHERE ... requester_id = $3` clause. The SQL scoping is the
// defense-in-depth half — the Go check gives the caller a precise error, the
// SQL guarantees a mismatched id can never touch someone else's row even if
// this check were ever bypassed or refactored away.
func (s *service) WithdrawRequest(ctx context.Context, req WithdrawRequestRequest) error {
	existing, err := s.requests.GetByID(ctx, req.RequestID)
	if err != nil {
		return err
	}
	if existing.RequesterID != req.RequesterID {
		return fmt.Errorf("meetup: caller did not make request %s: %w", req.RequestID, apperror.ErrForbidden)
	}
	if len(req.Note) > maxFreeTextReasonLength {
		return fmt.Errorf("meetup: note is too long: %w", apperror.ErrInvalidInput)
	}

	// host_user_id isn't on a request row, so the meetup is fetched BEFORE
	// the write rather than inside the notification callback: the callback
	// runs on the write's transaction and this read doesn't need to, and
	// resolving the host up front means a lookup failure fails the request
	// cleanly instead of rolling back a withdrawal that had already
	// succeeded. The viewer id is irrelevant to this lookup (it only
	// computes MyRequestStatus, which this call site never reads), so the
	// requester's own id is a harmless placeholder.
	m, err := s.meetups.GetByID(ctx, existing.MeetupID, req.RequesterID)
	if err != nil {
		return err
	}

	// Two different things share this entry point, told apart by what the
	// host has done so far.
	//
	// PENDING → a CANCELLATION. The host was told someone asked and has not
	// answered; the requester changing their mind before that is nobody's
	// business but theirs. The row is deleted, no notification is queued,
	// and the requester may ask again later.
	//
	// ACCEPTED → a WITHDRAWAL (ADR-020 §4). The host planned around this
	// person; they are told who backed out, the row stays as 'withdrawn',
	// and the host may rate the withdrawal.
	if existing.Status == repository.RequestStatusPending {
		return s.requests.CancelPending(ctx, req.RequestID, req.RequesterID)
	}

	_, err = s.requests.Withdraw(ctx, req.RequestID, req.Note, req.RequesterID,
		func(ctx context.Context, tx repository.NotifyTx, withdrawn repository.MeetupRequest) error {
			// Named, not "a requester". Withdraw's returned row carries no
			// display name (the same gap Create has), so this re-reads the
			// joined view on the write's own transaction exactly as
			// RequestToJoin does. A host with several accepted participants
			// could not act on an anonymous "someone pulled out" — they
			// could not tell whether the meetup still had enough people, or
			// who to follow up with.
			full, err := tx.GetRequestByID(ctx, withdrawn.ID)
			if err != nil {
				return err
			}
			return queueNotification(ctx, tx, m.HostUserID,
				TypeRequestWithdrawn,
				"Request withdrawn",
				fmt.Sprintf("%s withdrew from your %s meetup", full.RequesterFullName, m.Intent),
				map[string]string{"meetup_id": m.ID, "request_id": withdrawn.ID},
			)
		})
	if err != nil {
		return err
	}

	s.notifyPollerWake()
	return nil
}

// RespondToRequest is the host's accept/reject decision. Same two-layer
// ownership story as WithdrawRequest: the Go check below, plus the
// `meetup_id IN (SELECT id FROM meetup.meetups WHERE host_user_id = $2)`
// subquery inside both underlying UPDATEs.
func (s *service) RespondToRequest(ctx context.Context, req RespondToRequestRequest) (MeetupRequest, error) {
	existing, err := s.requests.GetByID(ctx, req.RequestID)
	if err != nil {
		return MeetupRequest{}, err
	}

	m, err := s.meetups.GetByID(ctx, existing.MeetupID, req.HostUserID)
	if err != nil {
		return MeetupRequest{}, err
	}
	if m.HostUserID != req.HostUserID {
		return MeetupRequest{}, fmt.Errorf("meetup: caller does not host meetup %s: %w", existing.MeetupID, apperror.ErrForbidden)
	}

	if req.Accept {
		return s.acceptRequest(ctx, req.RequestID, m)
	}
	return s.rejectRequest(ctx, req.RequestID, m)
}

func (s *service) acceptRequest(ctx context.Context, requestID string, m repository.Meetup) (MeetupRequest, error) {
	// All four notifications this decision produces — the acceptance, the
	// safety-checklist follow-up, and one "meetup is full" per requester
	// auto-rejected by the accept that filled the meetup — are queued inside
	// Accept's own transaction. The accept, the auto-rejections, and every
	// notification about them commit together or not at all (§F3).
	accepted, _, autoRejected, err := s.requests.Accept(ctx, requestID, m.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, accepted repository.MeetupRequest, autoRejected []repository.MeetupRequest) error {
			if err := queueNotification(ctx, tx, accepted.RequesterID,
				TypeRequestAccepted,
				"Request accepted",
				fmt.Sprintf("The host accepted your request to join their %s meetup", m.Intent),
				map[string]string{"meetup_id": m.ID, "request_id": accepted.ID},
			); err != nil {
				return err
			}

			if err := queueNotification(ctx, tx, accepted.RequesterID,
				TypeSafetyChecklist,
				"Review your safety checklist",
				fmt.Sprintf("Review the safety checklist for your %s meetup", m.Intent),
				map[string]string{"meetup_id": m.ID},
			); err != nil {
				return err
			}

			for _, rejected := range autoRejected {
				if err := queueNotification(ctx, tx, rejected.RequesterID,
					TypeMeetupFull,
					"Meetup is full",
					fmt.Sprintf("This %s meetup reached capacity before your request was accepted", m.Intent),
					map[string]string{"meetup_id": m.ID, "request_id": rejected.ID},
				); err != nil {
					return err
				}
			}
			return nil
		})
	if err != nil {
		return MeetupRequest{}, err
	}
	_ = autoRejected
	s.notifyPollerWake()

	// Every successful accept gives the accepted requester their own Safety
	// Gate row, scoped to that specific requester. Idempotent (ON CONFLICT DO
	// NOTHING), so calling it on every accept is simpler than tracking "was
	// this the first" and costs nothing. Logged, not propagated — the row
	// matters, but a transient failure shouldn't undo a committed accept.
	if err := s.safetyState.EnsureExists(ctx, m.ID, accepted.RequesterID); err != nil {
		s.logger.Error("ensure safety state after accepted request", "error", err)
	}

	full, err := s.requests.GetByID(ctx, accepted.ID)
	if err != nil {
		return MeetupRequest{}, err
	}
	return requestFromRepo(full), nil
}

func (s *service) rejectRequest(ctx context.Context, requestID string, m repository.Meetup) (MeetupRequest, error) {
	rejected, err := s.requests.Reject(ctx, requestID, m.HostUserID,
		func(ctx context.Context, tx repository.NotifyTx, rejected repository.MeetupRequest) error {
			return queueNotification(ctx, tx, rejected.RequesterID,
				TypeRequestDeclined,
				"Request declined",
				fmt.Sprintf("The host declined your request to join their %s meetup", m.Intent),
				map[string]string{"meetup_id": m.ID, "request_id": rejected.ID},
			)
		})
	if err != nil {
		return MeetupRequest{}, err
	}
	s.notifyPollerWake()

	full, err := s.requests.GetByID(ctx, rejected.ID)
	if err != nil {
		return MeetupRequest{}, err
	}
	return requestFromRepo(full), nil
}
