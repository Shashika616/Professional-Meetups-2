// Topic names and event payload shapes, ported verbatim (same constants,
// same struct fields, same JSON tags) from
// ../Professional-Meetups/backend/shared/events/payloads.go. Kept in the
// eventbus package rather than a package of their own: there is no second
// process to share them with any more, and one import for "the bus plus the
// things you put on it" is the simpler shape here.
//
// These stop being JSON-serialized wire payloads (nothing crosses a process
// boundary now, ADR-001 §4/§7) but keep their original job of pinning down a
// stable shape between publisher and subscriber code — and their JSON tags,
// unchanged, so that re-extracting a module back onto a real broker later
// doesn't silently rename every field on the wire.
//
// Note the redundancy between each payload's own OccurredAt field and
// Event.OccurredAt: both are kept deliberately. Event.OccurredAt is the
// bus's own stamp (bus.go), the payload field is what the sibling repo's
// consumers actually compare in their ordering guards, and dropping either
// would mean rewriting one side of that pattern for no gain.
package eventbus

import "time"

// Topic names — kebab-case, this project's existing Pub/Sub convention.
const (
	TopicUserOnboarded      = "user-onboarded"
	TopicUserProfileUpdated = "user-profile-updated"
	TopicRatingUpdated      = "rating-updated"

	// TopicMeetupsCompletedUpdated — published by the meetup module every
	// time a meetup completes, once per participant, carrying that
	// participant's recomputed total. Consumed by the auth module into
	// users.meetups_completed. Exactly the rating-updated arrangement, for
	// exactly the same reason: the count is derived from the meetup
	// schema's own tables, and the profile read must not reach across into
	// them.
	TopicMeetupsCompletedUpdated = "meetups-completed-updated"

	// TopicUserLocationUpdated (ADR-021 §4) — published by the auth module
	// every time UpdateLastKnownLocation succeeds; consumed by
	// the meetup module into its own user_location_cache. auth's only new
	// responsibility for this feature — no population-wide query, no
	// push-send, ever, on the auth side.
	TopicUserLocationUpdated = "user-location-updated"

	// TopicMeetupCreated (ADR-021 §1) — published by the meetup module on
	// every CreateMeetup; consumed by the meetup module's own
	// nearby-notification handler (a same-service, different-subscription
	// consumer, same shape as its existing ones — not cross-service).
	TopicMeetupCreated = "meetup-created"

	// TopicSubscriptionActivated/TopicSubscriptionDeactivated (ADR-031,
	// Slice B) — published by the billing module, consumed by
	// the meetup module into subscription_cache.
	TopicSubscriptionActivated   = "subscription-activated"
	TopicSubscriptionDeactivated = "subscription-deactivated"
)

// UserOnboardedPayload is published once, by the auth module, at account
// creation.
//
// Carries FullName/ProfilePhotoURL as of ADR-017's addendum — this event
// had zero consumers before this slice, so its original "deliberately
// minimal, no name/photo" shape was a proactive data-minimization stance,
// not one informed by any actual consumer's needs. Its first real
// consumer (the meetup module's user_display_cache, internal/events/
// consumer.go) needs a complete row the moment an account is created, not
// just from the next user-profile-updated — and both fields are already
// non-sensitive, already-shown-on-every-meetup-card data, not new
// exposure. Still no email/phone/legal name/etc. — the minimization
// principle applies to those, not to what was already public display info.
type UserOnboardedPayload struct {
	UserID          string    `json:"user_id"`
	FullName        string    `json:"full_name"`
	ProfilePhotoURL string    `json:"profile_photo_url"`
	TrustLevel      int       `json:"trust_level"`
	OccurredAt      time.Time `json:"occurred_at"`
}

// UserProfileUpdatedPayload is published by the auth module whenever a
// name/photo/trust-level field changes (ADR-017's addendum, Step 5) —
// exactly what the meetup module's user_display_cache needs, nothing more.
// OccurredAt is what the consumer's ordering guard compares against the
// cache row's stored updated_at (ADR-018 Decision 2) — it is the event's
// own timestamp, not the time the consumer happens to process it.
type UserProfileUpdatedPayload struct {
	UserID          string    `json:"user_id"`
	FullName        string    `json:"full_name"`
	ProfilePhotoURL string    `json:"profile_photo_url"`
	TrustLevel      int       `json:"trust_level"`
	OccurredAt      time.Time `json:"occurred_at"`
}

// RatingUpdatedPayload is published by the meetup module whenever
// SubmitRating recomputes a user's aggregate (ADR-017's addendum, Step
// 5b) — the auth module consumes this into its now-cache-only
// rating_average/rating_count columns.
type RatingUpdatedPayload struct {
	UserID        string    `json:"user_id"`
	RatingAverage float64   `json:"rating_average"`
	RatingCount   int       `json:"rating_count"`
	OccurredAt    time.Time `json:"occurred_at"`
}

// MeetupsCompletedUpdatedPayload is published by the meetup module for each
// participant of a meetup that just completed — the host and every accepted
// requester.
//
// MeetupsCompleted is an ABSOLUTE total, not a delta, and that is the whole
// design: the consumer's guarded UPDATE can then re-apply the same event any
// number of times without inflating the figure, which a "+1" could not. It
// is computed inside the same transaction that completed the meetup, so it
// reflects exactly the state that committed.
//
// OccurredAt is what the consumer's ordering guard compares against the
// stored meetups_completed_updated_at (ADR-018 Decision 2) — the event's own
// timestamp, not the time it happens to be processed.
type MeetupsCompletedUpdatedPayload struct {
	UserID           string    `json:"user_id"`
	MeetupsCompleted int       `json:"meetups_completed"`
	OccurredAt       time.Time `json:"occurred_at"`
}

// REMOVED: TopicPushNotificationRequested / PushNotificationRequestedPayload.
//
// Push notifications no longer travel on this bus at all. They are written
// into meetup.notification_outbox in the same transaction as the business
// write that implies them, and delivered by internal/platform/outbox's poller
// (ADR-001's "Correction (2026-09-04, durable notification delivery)",
// docs/plans/03-hardening-pass.md §F).
//
// The topic and payload are deleted rather than left defined-but-unused, on
// purpose: a topic constant that still exists is an invitation to publish to
// it, and a publish to this one would now be silently lost — no subscriber,
// no outbox row, no delivery, no error. Removing the name is what makes that
// mistake fail at compile time instead of at runtime, in a system where the
// whole point of the change was that these notifications must not be lost.
//
// Every OTHER topic in this file is unchanged: still this bus, still
// synchronous, still ADR-001 §4's accepted trade-off as originally reasoned.
// See internal/eventbus/bus.go's package doc for why this one topic was the
// exception.

// UserLocationUpdatedPayload is published by the auth module every time
// UpdateLastKnownLocation succeeds (ADR-021 §4) — the meetup module consumes
// this into user_location_cache, an idempotent order-guarded upsert (same
// shape as UserProfileUpdatedPayload's consumer), keyed and compared on
// OccurredAt exactly like every other consumer in this codebase.
type UserLocationUpdatedPayload struct {
	UserID     string    `json:"user_id"`
	Lat        float64   `json:"lat"`
	Lng        float64   `json:"lng"`
	OccurredAt time.Time `json:"occurred_at"`
}

// MeetupCreatedPayload is published by the meetup module on every
// CreateMeetup (ADR-021 §1) — the event ADR-008's addendum flagged as
// missing since before any "notify about nearby meetups" feature could
// exist. Consumed by the meetup module's own nearby-notification handler
// (a same-service consumer on a separate subscription, not cross-service —
// this type still lives here for consistency with every other
// bus-published payload in this file, not because another service
// consumes it).
type MeetupCreatedPayload struct {
	MeetupID    string    `json:"meetup_id"`
	HostUserID  string    `json:"host_user_id"`
	Intent      string    `json:"intent"`
	LocationLat float64   `json:"location_lat"`
	LocationLng float64   `json:"location_lng"`
	WindowStart time.Time `json:"window_start"`
	OccurredAt  time.Time `json:"occurred_at"`
}

// SubscriptionActivatedPayload/SubscriptionDeactivatedPayload (ADR-031,
// Slice B) — published by the billing module whenever a subscription enters
// or leaves an entitled state (active/grace_period vs. everything else,
// repository.Status.IsEntitled's own definition of the line). Consumed by
// the meetup module into its own subscription_cache read model (mirroring
// user_display_cache's shape/idempotent-upsert-with-timestamp-guard
// pattern) — the whole point being that Slice E's future paid-tier gating
// reads a local cache, never calls the billing module synchronously
// per-request (ADR-031 §2 step 5).
type SubscriptionActivatedPayload struct {
	UserID     string    `json:"user_id"`
	Tier       string    `json:"tier"`
	OccurredAt time.Time `json:"occurred_at"`
}

type SubscriptionDeactivatedPayload struct {
	UserID     string    `json:"user_id"`
	Tier       string    `json:"tier"`
	Status     string    `json:"status"`
	OccurredAt time.Time `json:"occurred_at"`
}
