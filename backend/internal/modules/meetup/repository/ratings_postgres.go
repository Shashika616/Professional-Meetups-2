package repository

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// pgCheckViolation is Postgres's error code for a CHECK constraint
// violation (23514) — meetup_user_ratings' self-rating guard
// (CHECK(rater_user_id <> rated_user_id)) is the only one this repository
// expects to hit in practice (ADR-015).
const pgCheckViolation = "23514"

type postgresRatingRepository struct {
	// pool (not just *sqlcgen.Queries) — Submit needs a transaction spanning
	// the rating insert and the aggregate read, so the aggregate the event
	// carries is computed from the same committed state the rating landed
	// in. In the source that transaction also covered the outbox row; here
	// the event goes out on the bus after the commit (ADR-001 §4).
	pool   *pgxpool.Pool
	q      *sqlcgen.Queries
	bus    eventbus.Bus
	logger *slog.Logger
}

// NewRatingRepository constructs a RatingRepository backed by pool,
// publishing its rating-updated events on bus.
func NewRatingRepository(pool *pgxpool.Pool, bus eventbus.Bus, logger *slog.Logger) RatingRepository {
	if logger == nil {
		logger = slog.Default()
	}
	return &postgresRatingRepository{pool: pool, q: sqlcgen.New(pool), bus: bus, logger: logger}
}

func (r *postgresRatingRepository) IsParticipant(ctx context.Context, meetupID, userID string) (bool, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	ok, err := r.q.IsMeetupParticipant(ctx, sqlcgen.IsMeetupParticipantParams{MeetupID: meetup, UserID: user})
	if err != nil {
		return false, fmt.Errorf("repository: check meetup participant: %w", err)
	}
	return ok, nil
}

func (r *postgresRatingRepository) HasConfirmedHappened(ctx context.Context, meetupID, userID string) (bool, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	user, err := parseUUID(userID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	ok, err := r.q.HasConfirmedMeetupHappened(ctx, sqlcgen.HasConfirmedMeetupHappenedParams{MeetupID: meetup, UserID: user})
	if err != nil {
		return false, fmt.Errorf("repository: check confirmed attendance: %w", err)
	}
	return ok, nil
}

func (r *postgresRatingRepository) ListRatable(ctx context.Context, meetupID, viewerID string) ([]RatableParticipant, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}

	rows, err := r.q.ListRatableParticipants(ctx, sqlcgen.ListRatableParticipantsParams{MeetupID: meetup, ViewerID: viewer})
	if err != nil {
		return nil, fmt.Errorf("repository: list ratable participants: %w", err)
	}

	participants := make([]RatableParticipant, 0, len(rows))
	for _, row := range rows {
		participants = append(participants, RatableParticipant{
			UserID:          row.UserID.String(),
			FullName:        row.FullName,
			ProfilePhotoURL: textOrEmpty(row.ProfilePhotoUrl),
			TrustLevel:      int(row.TrustLevel),
			AlreadyRated:    row.AlreadyRated,
			ContextNote:     stringPtrOrNil(row.ContextNote),
		})
	}
	return participants, nil
}

func (r *postgresRatingRepository) Submit(ctx context.Context, meetupID, raterID, ratedID string, score int) error {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	rater, err := parseUUID(raterID)
	if err != nil {
		return fmt.Errorf("repository: invalid rater id %q: %w", raterID, apperror.ErrInvalidInput)
	}
	rated, err := parseUUID(ratedID)
	if err != nil {
		return fmt.Errorf("repository: invalid rated id %q: %w", ratedID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("repository: begin submit rating transaction: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	q := r.q.WithTx(tx)

	if _, err := q.CreateMeetupRating(ctx, sqlcgen.CreateMeetupRatingParams{
		MeetupID:    meetup,
		RaterUserID: rater,
		RatedUserID: rated,
		Score:       int16(score),
		// Explicitly empty, never nil: the column is NOT NULL and the INSERT
		// names it, so the DEFAULT '{}' never applies. This path is the
		// out-of-band single rating (cancelled-meetup host, withdrawn
		// requester) — it has no trait picker behind it.
		Traits: []string{},
	}); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			switch pgErr.Code {
			case pgUniqueViolation:
				return fmt.Errorf("repository: already rated this participant for this meetup: %w", apperror.ErrConflict)
			case pgCheckViolation:
				return fmt.Errorf("repository: invalid rating: %w", apperror.ErrInvalidInput)
			}
		}
		return fmt.Errorf("repository: create meetup rating: %w", err)
	}

	aggregate, err := q.ComputeUserRatingAggregate(ctx, rated)
	if err != nil {
		return fmt.Errorf("repository: compute user rating aggregate: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("repository: commit submit rating transaction: %w: %w", apperror.ErrInternal, err)
	}

	// rating-updated, published after the commit (ADR-001 §4). The aggregate
	// it carries was computed inside the transaction above, so it reflects
	// exactly the state that committed — the auth module's consumer applies
	// it to auth.users' cached rating columns, guarded on OccurredAt.
	if err := r.bus.Publish(ctx, eventbus.TopicRatingUpdated, eventbus.RatingUpdatedPayload{
		UserID:        ratedID,
		RatingAverage: numericToFloat64(aggregate.RatingAverage),
		RatingCount:   int(aggregate.RatingCount),
		OccurredAt:    time.Now().UTC(),
	}); err != nil {
		r.logger.Error("publish rating-updated", "rated_user_id", ratedID, "error", err)
	}
	return nil
}

func (r *postgresRatingRepository) IsEligibleForCancellationRating(ctx context.Context, meetupID, raterID, ratedID string) (bool, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	rater, err := parseUUID(raterID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid rater id %q: %w", raterID, apperror.ErrInvalidInput)
	}
	rated, err := parseUUID(ratedID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid rated id %q: %w", ratedID, apperror.ErrInvalidInput)
	}

	ok, err := r.q.IsEligibleForCancellationRating(ctx, sqlcgen.IsEligibleForCancellationRatingParams{
		MeetupID: meetup, RaterID: rater, RatedID: rated,
	})
	if err != nil {
		return false, fmt.Errorf("repository: check cancellation rating eligibility: %w", err)
	}
	return ok, nil
}

func (r *postgresRatingRepository) IsEligibleForWithdrawalRating(ctx context.Context, meetupID, raterID, ratedID string) (bool, error) {
	meetup, err := parseUUID(meetupID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	rater, err := parseUUID(raterID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid rater id %q: %w", raterID, apperror.ErrInvalidInput)
	}
	rated, err := parseUUID(ratedID)
	if err != nil {
		return false, fmt.Errorf("repository: invalid rated id %q: %w", ratedID, apperror.ErrInvalidInput)
	}

	ok, err := r.q.IsEligibleForWithdrawalRating(ctx, sqlcgen.IsEligibleForWithdrawalRatingParams{
		MeetupID: meetup, RaterID: rater, RatedID: rated,
	})
	if err != nil {
		return false, fmt.Errorf("repository: check withdrawal rating eligibility: %w", err)
	}
	return ok, nil
}
