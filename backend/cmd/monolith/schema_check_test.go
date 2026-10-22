package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

type fakeRow struct {
	version uint
	dirty   bool
	err     error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*dest[0].(*uint) = r.version
	*dest[1].(*bool) = r.dirty
	return nil
}

type fakeDB struct{ row fakeRow }

func (f fakeDB) QueryRow(context.Context, string, ...any) pgx.Row { return f.row }

// #95. Code that needs a migration that has not run starts, passes its
// probe, and fails on the first request that touches the new schema. The
// check turns that into a revision that never becomes ready.
func TestCheckSchemaVersion(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name    string
		row     fakeRow
		want    uint
		wantErr string
	}{
		{"current", fakeRow{version: 24}, 24, ""},
		// A rollback to an older image after migrating must keep working.
		{"newer schema than the build", fakeRow{version: 25}, 24, ""},
		{"behind the build", fakeRow{version: 22}, 24, "run the pending migrations"},
		{"dirty", fakeRow{version: 24, dirty: true}, 24, "dirty"},
		{"never migrated", fakeRow{err: errors.New(`relation "schema_migrations" does not exist`)}, 24, "have migrations been run"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := checkSchemaVersion(ctx, fakeDB{tc.row}, tc.want)
			switch {
			case tc.wantErr == "" && err != nil:
				t.Errorf("refused to start: %v", err)
			case tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)):
				t.Errorf("err = %v, want one mentioning %q", err, tc.wantErr)
			}
		})
	}
}
