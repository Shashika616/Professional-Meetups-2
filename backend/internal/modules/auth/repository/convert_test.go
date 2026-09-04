package repository

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestTextOrEmptyAndTextOrNullRoundTrip(t *testing.T) {
	if got := textOrEmpty(pgtype.Text{}); got != "" {
		t.Errorf("textOrEmpty(invalid) = %q, want empty", got)
	}
	if got := textOrEmpty(textOrNull("")); got != "" {
		t.Errorf("textOrEmpty(textOrNull(\"\")) = %q, want empty", got)
	}
	if got := textOrEmpty(textOrNull("hello")); got != "hello" {
		t.Errorf("textOrEmpty(textOrNull(\"hello\")) = %q, want %q", got, "hello")
	}
}

func TestTimestamptzConversions(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Microsecond)

	ts := toTimestamptz(now)
	if !ts.Valid {
		t.Fatal("toTimestamptz produced an invalid pgtype.Timestamptz")
	}
	if got := timestamptzOrZero(ts); !got.Equal(now) {
		t.Errorf("timestamptzOrZero(toTimestamptz(now)) = %v, want %v", got, now)
	}

	if got := timePtrOrNil(pgtype.Timestamptz{}); got != nil {
		t.Errorf("timePtrOrNil(invalid) = %v, want nil", got)
	}
	if got := timePtrOrNil(ts); got == nil || !got.Equal(now) {
		t.Errorf("timePtrOrNil(valid) = %v, want %v", got, now)
	}
}

func TestUUIDConversions(t *testing.T) {
	if got := uuidPtrOrNil(pgtype.UUID{}); got != nil {
		t.Errorf("uuidPtrOrNil(invalid) = %v, want nil", got)
	}

	id := uuid.New()
	pt := pgtypeUUID(id)
	if !pt.Valid {
		t.Fatal("pgtypeUUID produced an invalid pgtype.UUID")
	}

	got := uuidPtrOrNil(pt)
	if got == nil {
		t.Fatal("uuidPtrOrNil(valid) = nil, want a pointer")
	}
	if *got != id.String() {
		t.Errorf("uuidPtrOrNil(pgtypeUUID(id)) = %q, want %q", *got, id.String())
	}
}
