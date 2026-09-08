package repository

import "time"

// Topic names for events this service produces — kebab-case, this
// project's existing Pub/Sub convention. Defined here (not in
// internal/events) because only this package's write methods produce
// them now (ADR-018's outbox pattern); internal/events' role is limited to
// the relay (drains outbox_events, publishes to real Pub/Sub) and the
// consumer (subscribes to auth's events) — putting these here avoids that
// package needing to import this one just for a type it doesn't otherwise
// depend on, and avoids the reverse import this package needs (for the
// consumer's user_display_cache upsert) turning into a cycle.
const (
	TopicRequestCreated  = "meetup-request-created"
	TopicRequestAccepted = "meetup-request-accepted"
	TopicRequestRejected = "meetup-request-rejected"
)

// requestEventPayload is deliberately minimal — IDs and the fact of the
// transition only, no meetup location/timing or requester name, consistent
// with the data-minimization principle applied throughout this project
// (ADR-003, ADR-011). Unchanged in shape from before ADR-018 — only how it
// reaches Pub/Sub changed (the outbox), not what it carries. Still zero
// real consumers anywhere (an already-tracked, separate gap this slice
// doesn't build) — kept local rather than promoted to shared/events for
// that reason.
type requestEventPayload struct {
	RequestID    string    `json:"request_id"`
	MeetupID     string    `json:"meetup_id"`
	RequesterID  string    `json:"requester_id"`
	HostUserID   string    `json:"host_user_id"`
	AutoRejected bool      `json:"auto_rejected,omitempty"`
	OccurredAt   time.Time `json:"occurred_at"`
}
