package meetup

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
)

func testBase64URL(raw string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func TestEncodeDecodeCursor_RoundTrips(t *testing.T) {
	original := &repository.Cursor{
		CreatedAt: time.Unix(0, 1_700_000_000_000_000_000).UTC(),
		ID:        uuid.New().String(),
	}

	decoded, err := decodeCursor(encodeCursor(original))
	if err != nil {
		t.Fatalf("decodeCursor() error: %v", err)
	}
	if !decoded.CreatedAt.Equal(original.CreatedAt) || decoded.ID != original.ID {
		t.Errorf("decodeCursor(encodeCursor(c)) = %+v, want %+v", decoded, original)
	}
}

func TestDecodeCursor_EmptyStringIsFirstPage(t *testing.T) {
	cursor, err := decodeCursor("")
	if err != nil {
		t.Fatalf("decodeCursor(\"\") error: %v", err)
	}
	if cursor != nil {
		t.Errorf("decodeCursor(\"\") = %+v, want nil", cursor)
	}
}

// TestDecodeCursor_NonUUIDIdIsRejectedNotPanicked guards against a real bug:
// decodeCursor used to accept any string as the cursor's id half with no
// validation, which reached repository.mustParseUUID (meetups_postgres.go)
// several layers downstream and panicked — crashing the whole gRPC server
// process for any authenticated caller who passed a hand-crafted or
// corrupted `cursor` value, not just this one request. This must be a
// regular decode error instead.
func TestDecodeCursor_NonUUIDIdIsRejectedNotPanicked(t *testing.T) {
	raw := "1700000000000000000|not-a-uuid"
	encoded := testBase64URL(raw)

	_, err := decodeCursor(encoded)
	if err == nil {
		t.Fatal("decodeCursor() with a non-UUID id returned nil error, want error")
	}
}

func TestDecodeCursor_MalformedBase64IsRejected(t *testing.T) {
	if _, err := decodeCursor("not valid base64!!"); err == nil {
		t.Fatal("decodeCursor() with malformed base64 returned nil error, want error")
	}
}

func TestDecodeCursor_MissingSeparatorIsRejected(t *testing.T) {
	if _, err := decodeCursor(testBase64URL("no-separator-here")); err == nil {
		t.Fatal("decodeCursor() with no '|' separator returned nil error, want error")
	}
}

func TestDecodeCursor_NonNumericTimestampIsRejected(t *testing.T) {
	if _, err := decodeCursor(testBase64URL("not-a-number|" + uuid.New().String())); err == nil {
		t.Fatal("decodeCursor() with a non-numeric timestamp returned nil error, want error")
	}
}
