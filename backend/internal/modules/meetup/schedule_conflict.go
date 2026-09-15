package meetup

import (
	"context"
	"fmt"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// ScheduleConflictError is the one-meetup-at-a-time rule (2026-09-15)
// failing: the caller asked to host or join a meetup in a window they are
// already committed to. It wraps apperror.ErrConflict, so every existing
// errors.Is(err, ErrConflict) path still classifies it as a 409, and
// carries the meetup in the way so the boundary can tell the client which
// one — the app shows it and offers to cancel it or wait, rather than
// leaving the person to hunt for it on Home.
//
// "Committed" means hosting, or holding a pending or accepted request. A
// pending request counts on purpose: if it did not, two hosts accepting
// two overlapping requests would be what created the double booking, and
// neither host could have known. Counting the request keeps the rule
// enforceable at the two places the person acts (host, join) and nowhere
// else.
type ScheduleConflictError struct {
	// Conflict is the earliest overlapping commitment, as the caller sees
	// it (IsHostedByMe / MyRequestStatus populated).
	Conflict Meetup
}

func (e *ScheduleConflictError) Error() string {
	return fmt.Sprintf("meetup: %s: %v", e.message(), apperror.ErrConflict)
}

func (e *ScheduleConflictError) Unwrap() error { return apperror.ErrConflict }

// message is the sentence the gateway's UserMessage keeps for a client that
// does not read the structured detail.
func (e *ScheduleConflictError) message() string {
	if e.Conflict.IsHostedByMe {
		return "you are already hosting a meetup at that time; cancel it or wait until it ends"
	}
	return "you already have a meetup at that time; cancel your request or wait until it ends"
}

// scheduleGuard is the shared guard behind CreateMeetup and RequestToJoin.
// It runs inside the write's transaction, under the actor's schedule lock
// (repository.ScheduleGuard), so the check and the write cannot be split
// by a concurrent call. excludeID is the meetup being joined, so the
// caller's own standing request on it (the requests table's concern) is
// not mistaken for a clash with itself.
func scheduleGuard(userID string, windowStart, windowEnd time.Time, excludeID string) repository.ScheduleGuard {
	return func(ctx context.Context, tx repository.ScheduleTx) error {
		conflict, found, err := tx.FindScheduleConflict(ctx, userID, windowStart, windowEnd, excludeID)
		if err != nil {
			return err
		}
		if !found {
			return nil
		}
		return &ScheduleConflictError{Conflict: meetupFromRepo(conflict, userID)}
	}
}
