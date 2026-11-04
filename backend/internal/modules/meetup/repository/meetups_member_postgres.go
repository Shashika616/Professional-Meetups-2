package repository

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

func (r *postgresMeetupRepository) CanViewMemberProfile(ctx context.Context, viewerID, targetID string) (bool, error) {
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}
	target, err := parseUUID(targetID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid member id %q: %w", targetID, apperror.ErrInvalidInput)
	}
	ok, err := r.q.CanViewMemberProfile(ctx, sqlcgen.CanViewMemberProfileParams{ViewerID: viewer, TargetID: target})
	if err != nil {
		return false, fmt.Errorf("repository: can view member profile: %w", err)
	}
	return ok.Valid && ok.Bool, nil
}

func (r *postgresMeetupRepository) ListRecentMeetupsForMember(ctx context.Context, targetID string, limit int) ([]RecentMemberMeetup, error) {
	target, err := parseUUID(targetID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid member id %q: %w", targetID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListRecentMeetupsForMember(ctx, sqlcgen.ListRecentMeetupsForMemberParams{
		TargetID: target, PageLimit: int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("repository: list recent meetups for member: %w", err)
	}
	out := make([]RecentMemberMeetup, 0, len(rows))
	for _, row := range rows {
		out = append(out, RecentMemberMeetup{
			Intent:           Intent(row.Intent),
			Status:           MeetupStatus(row.Status),
			WindowStart:      row.WindowStart.Time,
			LocationLabel:    row.LocationLabel,
			ParticipantCount: int(row.ParticipantCount),
			OverallAverage:   row.OverallAverage,
			ReviewCount:      int(row.ReviewCount),
		})
	}
	return out, nil
}

func (r *postgresMeetupRepository) ListHostReviews(ctx context.Context, targetID string, limit int) ([]HostReview, error) {
	target, err := parseUUID(targetID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid member id %q: %w", targetID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListHostReviews(ctx, sqlcgen.ListHostReviewsParams{TargetID: target, PageLimit: int32(limit)})
	if err != nil {
		return nil, fmt.Errorf("repository: list host reviews: %w", err)
	}
	out := make([]HostReview, 0, len(rows))
	for _, row := range rows {
		out = append(out, HostReview{
			Score:     int(row.Score),
			Text:      row.Notes.String,
			WrittenAt: row.ReviewCompletedAt.Time,
		})
	}
	return out, nil
}

func (r *postgresMeetupRepository) ActiveCommitments(ctx context.Context, userID string) (ActiveCommitments, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return ActiveCommitments{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	row, err := r.q.CountActiveCommitments(ctx, parsed)
	if err != nil {
		return ActiveCommitments{}, fmt.Errorf("repository: count active commitments: %w", err)
	}
	return ActiveCommitments{
		Hosting:  int(row.HostingCount),
		Accepted: int(row.AcceptedCount),
		Pending:  int(row.PendingCount),
	}, nil
}

// PurgeUser removes this schema's copy of a deleted account.
//
// # THE RULE: ONLY WHAT THIS ACCOUNT OWNS
//
// A row is deleted only if the deleted person owns it or wrote it, and never
// because it merely mentions them. Their join requests, which contacts they
// shared each meetup with, their safety-checklist and check-in state, the
// meetup write-ups they authored, their device tokens, every push sent to
// them, and the three caches
// this module keeps of auth-owned data about them (display name and photo,
// last-known location, subscription tier). The display cache matters most:
// it is the one place in this schema holding a name and a photograph.
//
// Kept, because each belongs to somebody else, but ANONYMISED:
//
//   - Ratings, in both directions. A rating is written by its rater and is
//     part of the rated member's reputation; deleting one would change
//     somebody else's average. The deleted person's id on each row is
//     replaced by a fresh random one, per row, so the row survives but no
//     longer points at them, and cannot be joined back to them via the
//     30-day backups either (anonymised, not merely pseudonymised).
//   - Meetups they HOSTED. meetup_requests, safety_state, meetup_feedback and
//     meetup_user_ratings all cascade from meetup.meetups, so deleting a past
//     meetup would take every other attendee's history of it with it. The
//     meetup stays; its host_user_id is anonymised the same way. Live ones
//     are cancelled first (see HandleUserDeleted), never deleted.
//
// It does not matter that most trusted contacts are not users of this app,
// or that there may be nothing at all to delete: every statement is keyed on
// this one account and deletes zero or more rows, and zero is not an error.
// That is also what makes a retry after any failure safe.
func (r *postgresMeetupRepository) PurgeUser(ctx context.Context, userID string) error {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	// One transaction, so the purge is all-or-nothing within this schema: a
	// failure half way cannot leave the display cache (the name and the
	// photograph) behind while the rest is gone. Short by construction —
	// eight indexed single-user deletes, no scans, no user input in the
	// predicates — so it holds row locks briefly and never blocks another
	// user's work. See migration 0014 for the indexes that keep it that way.
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("repository: begin purge transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := r.q.WithTx(tx)

	// Take this user's schedule lock and re-check, INSIDE the transaction.
	//
	// LockUserSchedule is the lock every create and join request for this
	// user already takes, so holding it makes the re-check below exact:
	// anything committed before we got the lock is seen, and anything after
	// waits for us. It is a per-user advisory lock, so it serialises only
	// this one person and blocks nobody else.
	if err := q.LockUserSchedule(ctx, userID); err != nil {
		return fmt.Errorf("repository: lock schedule for purge: %w", err)
	}
	commitments, err := q.CountActiveCommitments(ctx, parsed)
	if err != nil {
		return fmt.Errorf("repository: recheck commitments: %w", err)
	}
	// Only HOSTED meetups stop the purge. The user's own requests, pending or
	// accepted, are simply deleted below. A live meetup they host cannot be:
	// other people are attending it, and it must be cancelled (which notifies
	// them) rather than left without a host. The handler cancels those before
	// calling this, so one here means it was created in the gap. Returning an
	// error rolls this back and lets the outbox retry; the next attempt's
	// cancel step picks it up. The process converges; it never gives up.
	if commitments.HostingCount > 0 {
		return fmt.Errorf("repository: purge found %d live hosted meetup(s) created after the cancel step; will retry", commitments.HostingCount)
	}

	// # LOCK ORDER: meetups BEFORE meetup_requests
	//
	// Every other transaction that touches both takes the meetup row first
	// and the request rows second (Accept's SELECT ... FOR UPDATE then its
	// accept/auto-reject writes; Cancel's UPDATE then its pending-request
	// writes). This one used to go the other way, which is the shape a
	// deadlock is made of: two transactions holding one of the pair and
	// each waiting for the other's.
	//
	// It was not actually reachable, for a reason that has nothing to do
	// with locking: a cycle needs this purge to hold a request row that an
	// Accept wants AND to want a meetup row that the same Accept holds,
	// which means one person being both the host of a meetup and a
	// requester on it. RequestToJoin refuses that (meetup: cannot request
	// to join your own meetup) and there is no FK or CHECK behind it — the
	// tables deliberately have no cross-row constraints — so the safety of
	// this purge rested entirely on a guard in an unrelated service
	// method, with nothing anywhere saying so.
	//
	// These twelve statements are independent: each is one table, keyed on
	// this one user id, and none reads what another wrote. So the order is
	// free, and spending it on agreeing with everything else costs nothing
	// and removes the cycle by construction rather than by coincidence.
	// Keep anything added here on the same side of that line.
	steps := []struct {
		name string
		run  func(context.Context, uuid.UUID) error
	}{
		// Anonymised, not deleted: each row is part of another member's
		// record. See the queries for why a fresh id per row.
		{"meetups they hosted (anonymise host)", q.AnonymiseHostOfMeetups},
		{"requests", q.DeleteUserRequests},
		{"safety shares", q.DeleteUserSafetyShares},
		{"safety state", q.DeleteUserSafetyState},
		{"feedback", q.DeleteUserFeedback},
		{"device tokens", q.DeleteUserDeviceTokens},
		// notification_outbox.user_id is nullable (0009 added it to an existing
		// table), so the generated query takes a pgtype.UUID.
		{"notifications sent to them", func(ctx context.Context, id uuid.UUID) error {
			return q.DeleteUserNotifications(ctx, pgtype.UUID{Bytes: id, Valid: true})
		}},
		{"display cache", q.DeleteUserDisplayCache},
		{"location cache", q.DeleteUserLocationCache},
		{"subscription cache", q.DeleteUserSubscriptionCache},
		// Anonymised for the same reason as the meetups above.
		{"ratings they gave (anonymise)", q.AnonymiseRatingsGivenByUser},
		{"ratings about them (anonymise)", q.AnonymiseRatingsAboutUser},
	}
	for _, step := range steps {
		if err := step.run(ctx, parsed); err != nil {
			return fmt.Errorf("repository: purge user %s: %w", step.name, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("repository: commit purge: %w: %w", apperror.ErrInternal, err)
	}
	return nil
}

func (r *postgresMeetupRepository) ListLiveHostedMeetupIDs(ctx context.Context, userID string) ([]string, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rows, err := r.q.ListLiveHostedMeetupIDs(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list live hosted meetups: %w", err)
	}
	ids := make([]string, 0, len(rows))
	for _, id := range rows {
		ids = append(ids, id.String())
	}
	return ids, nil
}
