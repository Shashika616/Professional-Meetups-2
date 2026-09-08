package auth

import (
	"context"
	"time"
)

// ApplyRatingUpdate is the auth module's half of the rating-updated flow —
// the subscriber side of what the meetup module publishes whenever
// SubmitRating recomputes someone's aggregate.
//
// WHY IT EXISTS ONLY NOW: Phase 1 ported the repository method
// (UserRepository.UpsertRatingCache, with its ordering guard) because it is
// part of the auth schema's own contract, but deliberately did not add this
// service method or wire a Subscribe call — nothing published the event yet,
// and a handler subscribed to a topic with no publisher is a dangling
// subscription that looks wired but can never fire. cmd/monolith's comment
// said as much and named this as Phase 2's job. Phase 2 is where the
// publisher arrives, so this is where the consumer does.
//
// auth.users.rating_average/rating_count are a read-only CACHE here: the
// meetup module owns the ratings themselves and computes the aggregate from
// its own meetup_user_ratings table. No RPC in this module ever writes these
// columns — this consumer is their only writer (ADR-001 §3: the caches are
// kept, and kept event-fed, rather than collapsed into a cross-schema join).
//
// occurredAt is the EVENT's own timestamp, never time.Now(): it is what the
// repository's ordering guard compares against the stored rating_updated_at,
// so a redelivered or out-of-order event silently no-ops instead of
// regressing a newer aggregate. `applied` reports whether the guard let this
// one through — returned for logging, not as an error, because a skipped
// stale event is correct behavior, not a failure.
func (s *service) ApplyRatingUpdate(ctx context.Context, userID string, ratingAverage float64, ratingCount int, occurredAt time.Time) (applied bool, err error) {
	return s.users.UpsertRatingCache(ctx, userID, ratingAverage, ratingCount, occurredAt)
}

// ApplyMeetupsCompletedUpdate is the auth module's half of the
// meetups-completed flow, and the exact counterpart of ApplyRatingUpdate
// above — same ownership story, same ordering guard, same reason for
// existing at all.
//
// auth.users.meetups_completed is a read-only CACHE: the meetup module owns
// the meetups and the accepted requests the figure is computed from, and
// recomputes it whenever a meetup completes. This consumer is the column's
// only writer.
//
// meetupsCompleted is an ABSOLUTE total rather than an increment. A "+1"
// event would be indistinguishable on redelivery from a second completed
// meetup, and would inflate the number every time the bus retried; an
// absolute value re-applies harmlessly. occurredAt is the EVENT's timestamp,
// never time.Now(), because it is what the repository's guard compares
// against the stored meetups_completed_updated_at. `applied` reports whether
// the guard let it through — for logging, not as an error, since dropping a
// stale event is the correct outcome.
func (s *service) ApplyMeetupsCompletedUpdate(ctx context.Context, userID string, meetupsCompleted int, occurredAt time.Time) (applied bool, err error) {
	return s.users.UpsertMeetupsCompletedCache(ctx, userID, meetupsCompleted, occurredAt)
}
