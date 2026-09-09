package meetup

import (
	"context"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

// This file is how the meetup module asks for a push notification.
//
// # WHAT REPLACED WHAT, AND WHY (§E2/§F3)
//
// Phase 2 had a `Sender` interface with a bus-publishing implementation:
// each call site resolved the recipient's device tokens and published
// push-notification-requested on the in-process event bus. Nothing consumed
// that topic (the notification module was Phase 4), so every one of those
// publishes was a documented no-op — the notifications this system has been
// composing correctly since Phase 2 have never once been delivered.
//
// Two things changed together. Delivery now exists (internal/modules/
// notification), and the delivery MECHANISM is no longer the bus: these rows
// go into meetup.notification_outbox, written in the same transaction as the
// business write that implies them. See ADR-001's "Correction (2026-09-04,
// durable notification delivery)" for why this one topic gets durability
// machinery that ADR-001 §4 deliberately denies every other topic — briefly:
// every other event feeds an idempotent cache that self-heals, and a lost
// "the host accepted your request" is simply gone forever.
//
// The helpers below are plain functions rather than an injectable Sender
// interface. That is a deliberate simplification: the interface existed so
// tests could substitute a recorder, but the substitution point moved. What
// gets faked now is the SENDER at the far end of the outbox
// (notification.Sender), which is a truer seam — a test using it exercises
// the real enqueue, the real claim, and the real poller, instead of asserting
// that a mock was called.

// queueNotification queues one push for a single user, resolving their
// device tokens on the same transaction as the write that triggered it.
//
// A user with no registered device is a silent no-op, not an error — the
// same treatment the source gives it. They simply have nowhere to receive a
// push; that is not a failure of the accept/reject/cancel that caused it,
// and failing the business write over it would be absurd.
// notificationType is required for the same reason as in
// queueNotifications — see that function's comment.
func queueNotification(ctx context.Context, tx repository.NotifyTx, userID, notificationType, title, body string, data map[string]string) error {
	tokens, err := tx.DeviceTokensForUser(ctx, userID)
	if err != nil {
		return fmt.Errorf("meetup: resolve device tokens: %w", err)
	}
	if len(tokens) == 0 {
		return nil
	}
	withType := make(map[string]string, len(data)+1)
	for k, v := range data {
		withType[k] = v
	}
	withType["type"] = notificationType
	return tx.Enqueue(ctx, repository.OutboxRow{
		FCMTokens: tokens,
		Title:     title,
		Body:      body,
		Data:      withType,
		// The recipient, so the in-app list can show this later. Known here
		// already — it is the same id whose tokens were just resolved.
		UserID: userID,
	})
}

// queueNotifications is the fan-out form: ONE device-token query for every
// recipient rather than the 1+N the per-user shape would produce, which
// matters here because this path can address up to 500 people (the
// nearby-notify cap). Returns how many recipients actually had a device to
// queue for.
//
// One outbox row per recipient rather than one row addressing every token:
// a row is the unit of retry and of dead-lettering, so per-recipient rows
// mean one unreachable person cannot drag the rest of a fan-out into a retry
// loop with them.
// Notification types, carried in every push's data payload as `type`.
//
// # WHY THESE EXIST
//
// The client switches on this to decide what to refresh and what to say when
// a push arrives while the app is OPEN — FCM shows no system banner in the
// foreground, so the app has to render something itself, and it cannot do
// that from a title string it would have to pattern-match.
//
// Nothing sent a `type` before this. The client's foreground handler read
// `data['type']`, got an empty string on every message, and its
// `== "meetup_closed"` branch could never be true — so a user with the app
// open got no banner, no in-app notice, AND no refresh.
//
// TypeMeetupClosed keeps that exact spelling because the client already
// shipped expecting it.
const (
	TypeJoinRequest        = "join_request"
	TypeRequestWithdrawn   = "request_withdrawn"
	TypeRequestAccepted    = "request_accepted"
	TypeRequestDeclined    = "request_declined"
	TypeSafetyChecklist    = "safety_checklist"
	TypeMeetupStartingSoon = "meetup_starting_soon"
	TypeMeetupClosed       = "meetup_closed"
	TypeMeetupCancelled    = "meetup_cancelled"
	TypeMeetupNearby       = "meetup_nearby"
	// Distinct from TypeRequestDeclined: nobody turned this requester down,
	// the meetup filled up first. The client says different things about
	// the two, so the wire has to tell them apart.
	TypeMeetupFull = "meetup_full"
	// To the HOST, when a participant declines the safety checklist.
	TypeParticipantDeclined = "participant_declined"
)

// queueNotifications writes one outbox row per recipient that has a device
// registered.
//
// notificationType is a REQUIRED parameter rather than another key the
// caller remembers to put in `data`, so a new notification cannot ship
// without one — which is exactly how every existing notification ended up
// typeless.
func queueNotifications(ctx context.Context, tx repository.NotifyTx, recipients []string, notificationType, title, body string, data map[string]string) (int, error) {
	if len(recipients) == 0 {
		return 0, nil
	}

	// Copied rather than mutated: several call sites build one map and hand
	// it to two queueNotifications calls, and writing through would leak one
	// call's type into the other.
	withType := make(map[string]string, len(data)+1)
	for k, v := range data {
		withType[k] = v
	}
	withType["type"] = notificationType
	data = withType

	tokensByUser, err := tx.DeviceTokensForUsers(ctx, recipients)
	if err != nil {
		return 0, fmt.Errorf("meetup: resolve device tokens: %w", err)
	}

	rows := make([]repository.OutboxRow, 0, len(recipients))
	for _, userID := range recipients {
		tokens := tokensByUser[userID]
		if len(tokens) == 0 {
			continue
		}
		rows = append(rows, repository.OutboxRow{
			FCMTokens: tokens,
			Title:     title,
			Body:      body,
			Data:      data,
			UserID:    userID,
		})
	}
	if len(rows) == 0 {
		return 0, nil
	}
	if err := tx.Enqueue(ctx, rows...); err != nil {
		return 0, err
	}
	return len(rows), nil
}

// acceptedRequesters extracts the accepted participants from a meetup's full
// request list — the recipient set for "meetup cancelled", "meetup ended"
// and "meetup starting soon".
func acceptedRequesters(requests []repository.MeetupRequest) []string {
	out := make([]string, 0, len(requests))
	for _, r := range requests {
		if r.Status == repository.RequestStatusAccepted {
			out = append(out, r.RequesterID)
		}
	}
	return out
}
