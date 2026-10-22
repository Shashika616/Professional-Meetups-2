package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// rowQuerier is the one pool method checkSchemaVersion needs.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// checkSchemaVersion refuses to start against a database whose schema is
// older than this build expects (#95).
//
// The failure it prevents is quiet: code that needs a column or table a
// pending migration adds will start, pass its startup probe, and then fail
// on the first request that touches it. Refusing here turns that into a
// revision that never becomes ready, so Cloud Run keeps serving the previous
// one until the migration has run.
//
// A NEWER schema is accepted. Migrations here are written to be backward
// compatible, so rolling back to an older image after migrating must keep
// working; refusing it would turn every rollback into an outage.
//
// A dirty schema is refused: it means a migration failed halfway, and
// nothing about the database's shape can be assumed.
func checkSchemaVersion(ctx context.Context, db rowQuerier, want uint) (have uint, err error) {
	var dirty bool
	if err := db.QueryRow(ctx, `SELECT version, dirty FROM schema_migrations LIMIT 1`).Scan(&have, &dirty); err != nil {
		return 0, fmt.Errorf("read schema version (have migrations been run?): %w", err)
	}
	if dirty {
		return have, fmt.Errorf("schema is dirty at version %d: a migration failed partway; fix it before starting", have)
	}
	if have < want {
		return have, fmt.Errorf("schema is at version %d but this build needs %d: run the pending migrations first", have, want)
	}
	return have, nil
}
