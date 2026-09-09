package meetup

import (
	"context"
	"time"

	"professional-meetups-monolith/backend/internal/modules/notification"
)

// notificationHistoryLimit caps one page of the in-app list. A week of
// notifications for one person is realistically a handful; the cap exists so
// a pathological account cannot ask for an unbounded read, not because
// anyone is expected to hit it.
const notificationHistoryLimit = 200

// UserNotification is one notification this user was sent.
type UserNotification struct {
	ID        string
	Title     string
	Body      string
	Type      string
	MeetupID  string
	CreatedAt time.Time
	Delivered bool
}

// ListNotifications returns what was sent to userID inside the retention
// window, newest first.
//
// # WHY THE WINDOW IS THE RETENTION CONSTANT, NOT A NUMBER OF ITS OWN
//
// The rows this reads are the outbox rows, and the retention job deletes a
// delivered row once it is older than notification.ProcessedRetention.
// Reusing that same constant here means the list can never promise history
// that is already being swept — a separate "show 7 days" literal would be
// free to drift from whatever retention actually keeps, and the first
// symptom would be notifications vanishing mid-scroll.
//
// It also means there is no cleanup to write for this feature: the job that
// already trims the outbox is what bounds this list.
func (s *service) ListNotifications(ctx context.Context, userID string) ([]UserNotification, error) {
	since := time.Now().Add(-notification.ProcessedRetention)

	rows, err := s.outbox.ListForUser(ctx, userID, since, notificationHistoryLimit)
	if err != nil {
		return nil, err
	}

	out := make([]UserNotification, 0, len(rows))
	for _, row := range rows {
		out = append(out, UserNotification{
			ID:    row.ID,
			Title: row.Title,
			Body:  row.Body,
			// Both come from the same `data` payload the push carries, so
			// the in-app row can deep-link exactly where the tapped banner
			// would have.
			Type:      row.Data["type"],
			MeetupID:  row.Data["meetup_id"],
			CreatedAt: row.CreatedAt,
			Delivered: row.Delivered,
		})
	}
	return out, nil
}
