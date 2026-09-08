// Package notification delivers push notifications to already-resolved FCM
// device tokens. Ported from the sibling repo's
// services/notification-dispatch/internal/notifications (docs/plans/
// 03-hardening-pass.md §E1), which this module replaces.
//
// # NO DATABASE, NO SCHEMA
//
// Same as the service it replaces. It receives tokens ALREADY RESOLVED,
// because it cannot resolve them itself: meetup owns meetup.device_tokens
// (ADR-001 §3) and does the lookup inside the transaction that queues the
// notification. The one table this module reads — meetup.notification_outbox
// — it reads through a repository the meetup module owns and exposes, never
// by reaching into another module's SQL.
//
// # DELIVERY IS DURABLE, AND AT-LEAST-ONCE
//
// Notifications arrive here from a Postgres outbox, not the event bus. See
// ADR-001's "Correction (2026-09-04, durable notification delivery)" for the
// reasoning; the short version is that this is the one topic whose loss has
// no self-healing path, so it is the one topic that gets durability
// machinery.
//
// The consequence to be aware of when reading this code: if the process dies
// after SendToTokens succeeds but before the outbox row is marked processed,
// the row is claimed again and the user receives the SAME NOTIFICATION
// TWICE. That is accepted deliberately, not overlooked — a duplicate "your
// request was accepted" is a minor annoyance, while the alternative
// (at-most-once) is the lost-notification bug this whole mechanism exists to
// fix. No idempotency key is added, and its absence is a decision. See
// internal/platform/outbox's package doc, and internal/eventbus's, for the
// two halves of this system's durability posture stated side by side.
package notification

import "context"

// Sender sends one push notification to every token in tokens.
//
// Unlike the meetup module's own former Sender (which was user-id-shaped,
// because resolving "which devices does this user have" is meetup's job),
// this layer receives tokens already resolved. An empty tokens slice is not
// an error — there is simply nothing to send to.
type Sender interface {
	SendToTokens(ctx context.Context, tokens []string, title, body string, data map[string]string) error
}
