package repository

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// OutboxRow is one queued push notification: recipients already resolved to
// device tokens, plus the exact copy to deliver.
//
// TOKENS, NOT A USER ID, deliberately. The notification module owns no
// database (same as the source's notification-dispatch service) and cannot
// answer "which devices does this user have" — so the publisher resolves
// them, and resolves them INSIDE the same transaction as the business write,
// which also means the token set is the one that existed at the moment the
// business fact became true.
type OutboxRow struct {
	FCMTokens []string
	Title     string
	Body      string
	Data      map[string]string
	// UserID is the RECIPIENT — carried alongside the resolved tokens purely
	// so the in-app notification list can ask "what was sent to me"
	// (migration 0009). Delivery never reads it. Empty for a row with no
	// single recipient.
	UserID string
}

// NotifyTx is the transaction-scoped surface handed to a notification
// callback. Every method on it runs on the SAME transaction as the business
// write that triggered it (§F3).
//
// # WHY THIS SHAPE EXISTS AT ALL
//
// docs/plans/03-hardening-pass.md §F3 asserts that the outbox insert can be
// made atomic with the business write "entirely inside the notifications.Sender
// implementation", with no change to the call sites in requests.go/service.go.
// That is not achievable as written, and the reason is structural rather than
// a matter of effort: the Sender interface is invoked AFTER the business
// write's repository method has already returned, and that method opens,
// commits and closes its own transaction internally. By the time a Sender is
// called there is no open transaction left to join — the write is durably
// committed, and anything the Sender does is a second, separate transaction
// with exactly the crash window §F exists to close. See the completion
// report's §F notes for the full write-up.
//
// So the callback runs at the only point where atomicity is available: inside
// the write's own transaction, after the write and before the commit. The
// business logic still composes every notification (titles, bodies and the
// decision of who gets one stay in the service layer, where they belong);
// what moved is only WHEN that composition runs.
//
// Reads are exposed here too, not just the enqueue, because composing a
// notification needs facts — the participant list, the recipients' device
// tokens — and reading them on a different connection would reintroduce the
// same race in a subtler form: a participant list read after the commit can
// disagree with the one the write acted on.
type NotifyTx interface {
	// GetRequestByID returns the joined view (including the requester's
	// cached display name), which is what notification bodies are written
	// from.
	GetRequestByID(ctx context.Context, id string) (MeetupRequest, error)
	// ListRequestsForMeetup returns every request on a meetup, any status —
	// callers filter for accepted participants themselves.
	ListRequestsForMeetup(ctx context.Context, meetupID string) ([]MeetupRequest, error)
	// DeviceTokensForUser resolves one user's registered FCM tokens. An
	// empty result is normal (a user with no device registered) and is not
	// an error.
	DeviceTokensForUser(ctx context.Context, userID string) ([]string, error)
	// DeviceTokensForUsers is the batched form — one query for a whole
	// fan-out's recipients rather than the 1+N the per-user shape produces.
	DeviceTokensForUsers(ctx context.Context, userIDs []string) (map[string][]string, error)
	// Enqueue writes rows to meetup.notification_outbox. Rows with no
	// tokens are skipped rather than queued: a notification with nowhere to
	// go is a no-op, not a delivery failure to retry.
	Enqueue(ctx context.Context, rows ...OutboxRow) error
}

// Notification callbacks, one shape per business write, each receiving the
// facts that write produced. All are optional: a nil callback enqueues
// nothing, which is what non-notifying callers (and most tests) pass.
type (
	// NotifyRequest covers the writes that produce a single request row.
	NotifyRequest func(ctx context.Context, tx NotifyTx, req MeetupRequest) error
	// NotifyAccept additionally carries the requests auto-rejected because
	// the accept filled the meetup — they each need their own notification.
	NotifyAccept func(ctx context.Context, tx NotifyTx, accepted MeetupRequest, autoRejected []MeetupRequest) error
	// NotifyMeetup covers the writes that produce a single meetup row.
	NotifyMeetup func(ctx context.Context, tx NotifyTx, m Meetup) error
	// NotifyMeetups covers the poller's batch claims (§C2), where one
	// transaction claims several meetups at once.
	NotifyMeetups func(ctx context.Context, tx NotifyTx, ms []Meetup) error
	// NotifySafetyState covers the Safety Gate's decline.
	NotifySafetyState func(ctx context.Context, tx NotifyTx, st SafetyState) error
)

// notifyTx implements NotifyTx over a transaction-bound *sqlcgen.Queries.
type notifyTx struct{ q *sqlcgen.Queries }

func (n notifyTx) GetRequestByID(ctx context.Context, id string) (MeetupRequest, error) {
	parsed, err := parseUUID(id)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: invalid request id %q: %w", id, apperror.ErrInvalidInput)
	}
	row, err := n.q.GetMeetupRequestWithRequesterInfoByID(ctx, parsed)
	if err != nil {
		return MeetupRequest{}, fmt.Errorf("repository: get request for notification: %w", err)
	}
	return meetupRequestWithRequesterFromRow(row), nil
}

func (n notifyTx) ListRequestsForMeetup(ctx context.Context, meetupID string) ([]MeetupRequest, error) {
	parsed, err := parseUUID(meetupID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid meetup id %q: %w", meetupID, apperror.ErrInvalidInput)
	}
	rows, err := n.q.ListRequestsForMeetup(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list requests for notification: %w", err)
	}
	out := make([]MeetupRequest, 0, len(rows))
	for _, row := range rows {
		out = append(out, meetupRequestForMeetupFromRow(row))
	}
	return out, nil
}

func (n notifyTx) DeviceTokensForUser(ctx context.Context, userID string) ([]string, error) {
	parsed, err := parseUUID(userID)
	if err != nil {
		return nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}
	rows, err := n.q.ListDeviceTokensForUser(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list device tokens for notification: %w", err)
	}
	tokens := make([]string, 0, len(rows))
	for _, row := range rows {
		tokens = append(tokens, row.FcmToken)
	}
	return tokens, nil
}

func (n notifyTx) DeviceTokensForUsers(ctx context.Context, userIDs []string) (map[string][]string, error) {
	if len(userIDs) == 0 {
		return map[string][]string{}, nil
	}
	parsed, err := parseUUIDs(userIDs)
	if err != nil {
		return nil, err
	}
	rows, err := n.q.ListDeviceTokensForUsers(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("repository: list device tokens for notification: %w", err)
	}
	out := make(map[string][]string, len(userIDs))
	for _, row := range rows {
		id := row.UserID.String()
		out[id] = append(out[id], row.FcmToken)
	}
	return out, nil
}

func (n notifyTx) Enqueue(ctx context.Context, rows ...OutboxRow) error {
	for _, row := range rows {
		// No recipients means there is nothing to deliver. Queuing it anyway
		// would create a row the poller claims, "delivers" to nobody, and
		// marks processed — pure churn, and it would inflate every delivery
		// metric with non-events.
		if len(row.FCMTokens) == 0 {
			continue
		}

		data := row.Data
		if data == nil {
			data = map[string]string{}
		}
		encoded, err := json.Marshal(data)
		if err != nil {
			return fmt.Errorf("repository: encode notification data: %w", err)
		}

		var userID pgtype.UUID
		if row.UserID != "" {
			parsed, err := parseUUID(row.UserID)
			if err != nil {
				return fmt.Errorf("repository: invalid notification recipient %q: %w", row.UserID, apperror.ErrInvalidInput)
			}
			userID = pgtype.UUID{Bytes: parsed, Valid: true}
		}

		if err := n.q.EnqueueNotification(ctx, sqlcgen.EnqueueNotificationParams{
			FcmTokens: row.FCMTokens,
			Title:     row.Title,
			Body:      row.Body,
			Data:      encoded,
			UserID:    userID,
		}); err != nil {
			return fmt.Errorf("repository: enqueue notification: %w", err)
		}
	}
	return nil
}
