package repository

import (
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// textOrEmpty converts a nullable Postgres text column to a plain Go
// string, treating NULL as "" — this repository's domain types stay
// pgtype-free so internal/service/ never needs to import pgx.
func textOrEmpty(t pgtype.Text) string {
	if !t.Valid {
		return ""
	}
	return t.String
}

// timestamptzOrZero converts a Postgres timestamptz to time.Time. Only used
// for columns that are NOT NULL in the schema, where sqlc still generates
// pgtype.Timestamptz rather than time.Time.
func timestamptzOrZero(ts pgtype.Timestamptz) time.Time {
	return ts.Time
}

func toTimestamptz(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

// timePtrOrNil converts a nullable Postgres timestamptz to *time.Time.
func timePtrOrNil(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}

// boolPtrOrNull converts a *bool to a nullable Postgres bool column.
func boolPtrOrNull(b *bool) pgtype.Bool {
	if b == nil {
		return pgtype.Bool{}
	}
	return pgtype.Bool{Bool: *b, Valid: true}
}

// textOrNull converts a plain Go string to a nullable Postgres text
// column, treating "" as NULL — used where the domain type is a plain
// string (not *string), e.g. user_display_cache.profile_photo_url.
func textOrNull(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

// stringPtrOrNull converts a *string to a nullable Postgres text column —
// meetup_feedback.notes (ADR-016), same optional-free-text shape as
// feltSafe/profileAccurate/wouldMeetAgain's boolean counterparts.
func stringPtrOrNull(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}

// stringPtrOrNil converts a nullable Postgres text column to *string — the
// inverse of stringPtrOrNull, for read paths.
func stringPtrOrNil(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

// requestStatusPtrOrNil converts sqlc's nullable enum wrapper to
// *MeetupRequestStatus.
func requestStatusPtrOrNil(s sqlcgen.NullMeetupMeetupRequestStatus) *MeetupRequestStatus {
	if !s.Valid {
		return nil
	}
	status := MeetupRequestStatus(s.MeetupMeetupRequestStatus)
	return &status
}

func parseUUID(id string) (uuid.UUID, error) {
	return uuid.Parse(id)
}

// parseUUIDs parses a batch, failing on the first bad id rather than
// silently dropping it — a caller that passed a malformed id has a bug, and
// quietly notifying a subset of the intended recipients is a worse failure
// than an error.
func parseUUIDs(ids []string) ([]uuid.UUID, error) {
	out := make([]uuid.UUID, 0, len(ids))
	for _, id := range ids {
		parsed, err := parseUUID(id)
		if err != nil {
			return nil, fmt.Errorf("repository: invalid user id %q: %w", id, apperror.ErrInvalidInput)
		}
		out = append(out, parsed)
	}
	return out, nil
}

// uuidPtrOrNil converts a nullable Postgres uuid column (from a LEFT JOIN
// that may not have matched) to *string — used for MyRequestID, which is
// only meaningful when the viewer has an actual meetup_requests row.
func uuidPtrOrNil(u pgtype.UUID) *string {
	if !u.Valid {
		return nil
	}
	s := uuid.UUID(u.Bytes).String()
	return &s
}

// numericToFloat64 converts a NUMERIC(3,2) rating aggregate (host_rating_
// average/requester_rating_average — a live AVG() over this service's own
// meetup_user_ratings, ADR-017's addendum; no longer a stored users.
// rating_average column, this database has no users table) to a plain
// float64. Falls back to 0 on an invalid/unparseable value rather than
// propagating an error — COALESCE'd to 0 in the query already, so this
// only guards against a theoretical scan
// oddity, not an expected runtime case.
func numericToFloat64(n pgtype.Numeric) float64 {
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}
