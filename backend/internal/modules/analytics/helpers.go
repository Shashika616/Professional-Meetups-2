package analytics

import (
	"encoding/json"

	"github.com/jackc/pgx/v5/pgtype"
)

func marshalAttributes(attrs map[string]any) (json.RawMessage, error) {
	if len(attrs) == 0 {
		return nil, nil
	}
	return json.Marshal(attrs)
}

func textKey(key string) pgtype.Text { return pgtype.Text{String: key, Valid: key != ""} }
