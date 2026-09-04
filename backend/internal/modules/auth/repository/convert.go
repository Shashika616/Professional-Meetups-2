package repository

import (
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
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

// textOrNull converts a plain Go string to a nullable Postgres text column,
// treating "" as NULL.
func textOrNull(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

// timestamptzOrZero converts a Postgres timestamptz to time.Time. Only used
// for columns that are NOT NULL in the schema (issued_at, expires_at,
// created_at, updated_at), where sqlc still generates pgtype.Timestamptz
// rather than time.Time.
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

// uuidPtrOrNil converts a nullable Postgres uuid column to *string.
func uuidPtrOrNil(id pgtype.UUID) *string {
	if !id.Valid {
		return nil
	}
	u := uuid.UUID(id.Bytes)
	s := u.String()
	return &s
}

// pgtypeUUID converts a uuid.UUID to a non-null pgtype.UUID for use as a
// query parameter on a nullable uuid column.
func pgtypeUUID(id uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: id, Valid: true}
}

// numericToFloat64 converts users.rating_average (NUMERIC(3,2), NOT NULL
// DEFAULT 0, written by services/meetup — ADR-015) to a plain float64.
// Falls back to 0 on an invalid/unparseable value rather than propagating
// an error — the column always has a well-formed default.
func numericToFloat64(n pgtype.Numeric) float64 {
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}

// float64ToNumeric is numericToFloat64's inverse — used by
// UpsertRatingCache to write a rating-updated event's average back into
// users.rating_average (NUMERIC(3,2)). Formatted to 2 decimal places to
// match the column's own scale.
func float64ToNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.Scan(strconv.FormatFloat(f, 'f', 2, 64))
	return n
}

// float8PtrOrNil converts a nullable Postgres double precision column
// (users.last_location_lat/lng, ADR-021 §4) to *float64.
func float8PtrOrNil(f pgtype.Float8) *float64 {
	if !f.Valid {
		return nil
	}
	v := f.Float64
	return &v
}
