package repository

import (
	"context"
	"fmt"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

func (r *postgresMeetupRepository) ListOpen(
	ctx context.Context, filter OpenMeetupFilter, viewerID string, viewerLat, viewerLng float64, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	viewer, err := parseUUID(viewerID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid viewer id %q: %w", viewerID, apperror.ErrInvalidInput)
	}

	// A nil Intent becomes a NULL bind, which the query reads as "every
	// intent" — see its WHERE clause. Building the sqlc null wrapper here
	// rather than in the service keeps pgtype/sqlc types out of the module.
	intentArg := sqlcgen.NullMeetupIntentType{}
	if filter.Intent != nil {
		intentArg = sqlcgen.NullMeetupIntentType{
			MeetupIntentType: sqlcgen.MeetupIntentType(*filter.Intent),
			Valid:            true,
		}
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultPageSize
	} else if limit > maxPageSize {
		limit = maxPageSize
	}
	// Fetch one extra row to know whether there's a next page, without a
	// separate count query.
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListOpenMeetupsFirstPage(ctx, sqlcgen.ListOpenMeetupsFirstPageParams{
			Intent:      intentArg,
			WithinDays:  filter.WithinDays,
			RequesterID: viewer,
			PageLimit:   fetchLimit,
			ViewerLat:   viewerLat,
			ViewerLng:   viewerLng,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list open meetups: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
				ID:                  row.ID.String(),
				HostUserID:          row.HostUserID.String(),
				HostFullName:        row.HostFullName,
				HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:      int(row.HostTrustLevel),
				HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
				HostRatingCount:     int(row.HostRatingCount),
				Intent:              Intent(row.Intent),
				WindowStart:         timestamptzOrZero(row.WindowStart),
				WindowEnd:           timestamptzOrZero(row.WindowEnd),
				LocationLat:         row.LocationLat,
				LocationLng:         row.LocationLng,
				LocationLabel:       row.LocationLabel,
				Capacity:            int(row.Capacity),
				AcceptedCount:       int(row.AcceptedCount),
				Status:              MeetupStatus(row.Status),
				CreatedAt:           timestamptzOrZero(row.CreatedAt),
				CancelledAt:         timePtrOrNil(row.CancelledAt),
				CancellationReason:  stringPtrOrNil(row.CancellationReason),
				ClosedAt:            timePtrOrNil(row.ClosedAt),
				MyRequestStatus:     requestStatusPtrOrNil(row.MyRequestStatus),
			})
		}
	} else {
		rows, err := r.q.ListOpenMeetupsAfterCursor(ctx, sqlcgen.ListOpenMeetupsAfterCursorParams{
			Intent:          intentArg,
			WithinDays:      filter.WithinDays,
			RequesterID:     viewer,
			PageLimit:       fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
			ViewerLat:       viewerLat,
			ViewerLng:       viewerLng,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list open meetups after cursor: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
				ID:                  row.ID.String(),
				HostUserID:          row.HostUserID.String(),
				HostFullName:        row.HostFullName,
				HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:      int(row.HostTrustLevel),
				HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
				HostRatingCount:     int(row.HostRatingCount),
				Intent:              Intent(row.Intent),
				WindowStart:         timestamptzOrZero(row.WindowStart),
				WindowEnd:           timestamptzOrZero(row.WindowEnd),
				LocationLat:         row.LocationLat,
				LocationLng:         row.LocationLng,
				LocationLabel:       row.LocationLabel,
				Capacity:            int(row.Capacity),
				AcceptedCount:       int(row.AcceptedCount),
				Status:              MeetupStatus(row.Status),
				CreatedAt:           timestamptzOrZero(row.CreatedAt),
				CancelledAt:         timePtrOrNil(row.CancelledAt),
				CancellationReason:  stringPtrOrNil(row.CancellationReason),
				ClosedAt:            timePtrOrNil(row.ClosedAt),
				MyRequestStatus:     requestStatusPtrOrNil(row.MyRequestStatus),
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}

	return meetups, next, nil
}

func (r *postgresMeetupRepository) ListByHost(
	ctx context.Context, hostID string, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	host, err := parseUUID(hostID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid host id %q: %w", hostID, apperror.ErrInvalidInput)
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultMyMeetupsPageSize
	} else if limit > maxMyMeetupsPageSize {
		limit = maxMyMeetupsPageSize
	}
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListMeetupsByHostFirstPage(ctx, sqlcgen.ListMeetupsByHostFirstPageParams{
			HostUserID: host,
			Limit:      fetchLimit,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups by host: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
				ID:                  row.ID.String(),
				HostUserID:          row.HostUserID.String(),
				HostFullName:        row.HostFullName,
				HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:      int(row.HostTrustLevel),
				HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
				HostRatingCount:     int(row.HostRatingCount),
				Intent:              Intent(row.Intent),
				WindowStart:         timestamptzOrZero(row.WindowStart),
				WindowEnd:           timestamptzOrZero(row.WindowEnd),
				LocationLat:         row.LocationLat,
				LocationLng:         row.LocationLng,
				LocationLabel:       row.LocationLabel,
				Capacity:            int(row.Capacity),
				AcceptedCount:       int(row.AcceptedCount),
				Status:              MeetupStatus(row.Status),
				CreatedAt:           timestamptzOrZero(row.CreatedAt),
				CancelledAt:         timePtrOrNil(row.CancelledAt),
				CancellationReason:  stringPtrOrNil(row.CancellationReason),
				ClosedAt:            timePtrOrNil(row.ClosedAt),
			})
		}
	} else {
		rows, err := r.q.ListMeetupsByHostAfterCursor(ctx, sqlcgen.ListMeetupsByHostAfterCursorParams{
			HostUserID:      host,
			Limit:           fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups by host after cursor: %w", err)
		}
		for _, row := range rows {
			meetups = append(meetups, Meetup{
				ID:                  row.ID.String(),
				HostUserID:          row.HostUserID.String(),
				HostFullName:        row.HostFullName,
				HostProfilePhotoURL: textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:      int(row.HostTrustLevel),
				HostRatingAverage:   numericToFloat64(row.HostRatingAverage),
				HostRatingCount:     int(row.HostRatingCount),
				Intent:              Intent(row.Intent),
				WindowStart:         timestamptzOrZero(row.WindowStart),
				WindowEnd:           timestamptzOrZero(row.WindowEnd),
				LocationLat:         row.LocationLat,
				LocationLng:         row.LocationLng,
				LocationLabel:       row.LocationLabel,
				Capacity:            int(row.Capacity),
				AcceptedCount:       int(row.AcceptedCount),
				Status:              MeetupStatus(row.Status),
				CreatedAt:           timestamptzOrZero(row.CreatedAt),
				CancelledAt:         timePtrOrNil(row.CancelledAt),
				CancellationReason:  stringPtrOrNil(row.CancellationReason),
				ClosedAt:            timePtrOrNil(row.ClosedAt),
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}
	return meetups, next, nil
}

func (r *postgresMeetupRepository) ListRequestedByUser(
	ctx context.Context, userID string, cursor *Cursor, pageSize int,
) ([]Meetup, *Cursor, error) {
	requester, err := parseUUID(userID)
	if err != nil {
		return nil, nil, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	limit := int32(pageSize)
	if limit <= 0 {
		limit = defaultMyMeetupsPageSize
	} else if limit > maxMyMeetupsPageSize {
		limit = maxMyMeetupsPageSize
	}
	fetchLimit := limit + 1

	var meetups []Meetup
	if cursor == nil {
		rows, err := r.q.ListMeetupsRequestedByUserFirstPage(ctx, sqlcgen.ListMeetupsRequestedByUserFirstPageParams{
			RequesterID: requester,
			Limit:       fetchLimit,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups requested by user: %w", err)
		}
		for _, row := range rows {
			status := MeetupRequestStatus(row.MyRequestStatus)
			meetups = append(meetups, Meetup{
				ID:                    row.ID.String(),
				HostUserID:            row.HostUserID.String(),
				HostFullName:          row.HostFullName,
				HostProfilePhotoURL:   textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:        int(row.HostTrustLevel),
				HostRatingAverage:     numericToFloat64(row.HostRatingAverage),
				HostRatingCount:       int(row.HostRatingCount),
				Intent:                Intent(row.Intent),
				WindowStart:           timestamptzOrZero(row.WindowStart),
				WindowEnd:             timestamptzOrZero(row.WindowEnd),
				LocationLat:           row.LocationLat,
				LocationLng:           row.LocationLng,
				LocationLabel:         row.LocationLabel,
				Capacity:              int(row.Capacity),
				AcceptedCount:         int(row.AcceptedCount),
				Status:                MeetupStatus(row.Status),
				CreatedAt:             timestamptzOrZero(row.CreatedAt),
				CancelledAt:           timePtrOrNil(row.CancelledAt),
				CancellationReason:    stringPtrOrNil(row.CancellationReason),
				ClosedAt:              timePtrOrNil(row.ClosedAt),
				MyRequestStatus:       &status,
				MyRequestAutoRejected: row.MyRequestAutoRejected,
			})
		}
	} else {
		rows, err := r.q.ListMeetupsRequestedByUserAfterCursor(ctx, sqlcgen.ListMeetupsRequestedByUserAfterCursorParams{
			RequesterID:     requester,
			Limit:           fetchLimit,
			CursorCreatedAt: toTimestamptz(cursor.CreatedAt),
			CursorID:        mustParseUUID(cursor.ID),
		})
		if err != nil {
			return nil, nil, fmt.Errorf("repository: list meetups requested by user after cursor: %w", err)
		}
		for _, row := range rows {
			status := MeetupRequestStatus(row.MyRequestStatus)
			meetups = append(meetups, Meetup{
				ID:                    row.ID.String(),
				HostUserID:            row.HostUserID.String(),
				HostFullName:          row.HostFullName,
				HostProfilePhotoURL:   textOrEmpty(row.HostProfilePhotoUrl),
				HostTrustLevel:        int(row.HostTrustLevel),
				HostRatingAverage:     numericToFloat64(row.HostRatingAverage),
				HostRatingCount:       int(row.HostRatingCount),
				Intent:                Intent(row.Intent),
				WindowStart:           timestamptzOrZero(row.WindowStart),
				WindowEnd:             timestamptzOrZero(row.WindowEnd),
				LocationLat:           row.LocationLat,
				LocationLng:           row.LocationLng,
				LocationLabel:         row.LocationLabel,
				Capacity:              int(row.Capacity),
				AcceptedCount:         int(row.AcceptedCount),
				Status:                MeetupStatus(row.Status),
				CreatedAt:             timestamptzOrZero(row.CreatedAt),
				CancelledAt:           timePtrOrNil(row.CancelledAt),
				CancellationReason:    stringPtrOrNil(row.CancellationReason),
				ClosedAt:              timePtrOrNil(row.ClosedAt),
				MyRequestStatus:       &status,
				MyRequestAutoRejected: row.MyRequestAutoRejected,
			})
		}
	}

	var next *Cursor
	if len(meetups) > int(limit) {
		last := meetups[limit-1]
		next = &Cursor{CreatedAt: last.CreatedAt, ID: last.ID}
		meetups = meetups[:limit]
	}
	return meetups, next, nil
}
