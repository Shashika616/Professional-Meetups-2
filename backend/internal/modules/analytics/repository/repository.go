// Package repository is the analytics module's persistence: the sqlc
// queries for partitions, consent, deletion and the daily aggregates, and,
// hand-written here because sqlc cannot express them, the COPY flush and the
// archive export.
package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/analytics/repository/sqlcgen"
)

// Event is one analytics.events row. Every field is already validated: by
// the registry for the event itself, by the ingest for the context. Empty
// strings are stored as NULL.
type Event struct {
	ReceivedAt    time.Time
	EventID       uuid.UUID
	Name          string
	SchemaVersion int
	Source        string
	OccurredAt    time.Time
	UserKey       string
	InstallID     string
	SessionID     string
	AppVersion    string
	OSName        string
	OSVersion     string
	DeviceClass   string
	Locale        string
	Screen        string
	FlowID        string
	FlowStep      string
	Attributes    map[string]any
}

// ReceivedDay is the partition key: the server's UTC day.
func (e Event) ReceivedDay() time.Time {
	y, m, d := e.ReceivedAt.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// WriteResult is what one flush did.
type WriteResult struct {
	Inserted   int
	OptedOut   int
	Duplicates int
}

// Store is the analytics persistence.
type Store struct {
	pool *pgxpool.Pool
	Q    *sqlcgen.Queries
}

// New constructs the Store.
func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool, Q: sqlcgen.New(pool)} }

// columns is analytics.events in table order, which the stage table
// (LIKE analytics.events) shares.
var columns = []string{
	"received_day", "event_id", "event_name", "schema_version", "source", "occurred_at", "received_at",
	"user_key", "install_id", "session_id", "app_version", "os_name", "os_version", "device_class",
	"locale", "screen", "flow_id", "flow_step", "attributes",
}

// Write stores events in one transaction: COPY into a temporary stage,
// remove anything from an account that opted out, then insert what is left
// once per (day, event_id). A repeated event_id is stored once, whether it
// repeats within the batch or arrives again later the same day.
func (s *Store) Write(ctx context.Context, events []Event) (WriteResult, error) {
	if len(events) == 0 {
		return WriteResult{}, nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return WriteResult{}, fmt.Errorf("analytics: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE analytics_stage (LIKE analytics.events INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
		return WriteResult{}, fmt.Errorf("analytics: stage: %w", err)
	}
	rows := make([][]any, len(events))
	for i, e := range events {
		attrs := e.Attributes
		if attrs == nil {
			attrs = map[string]any{}
		}
		rows[i] = []any{
			pgtype.Date{Time: e.ReceivedDay(), Valid: true}, e.EventID, e.Name, int32(e.SchemaVersion), e.Source,
			e.OccurredAt, e.ReceivedAt, text(e.UserKey), text(e.InstallID), text(e.SessionID), text(e.AppVersion),
			text(e.OSName), text(e.OSVersion), text(e.DeviceClass), text(e.Locale), text(e.Screen),
			text(e.FlowID), text(e.FlowStep), attrs,
		}
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"analytics_stage"}, columns, pgx.CopyFromRows(rows)); err != nil {
		return WriteResult{}, fmt.Errorf("analytics: copy: %w", err)
	}
	optedOut, err := tx.Exec(ctx, `DELETE FROM analytics_stage s USING analytics.opt_outs o WHERE s.user_key = o.user_key`)
	if err != nil {
		return WriteResult{}, fmt.Errorf("analytics: opt-outs: %w", err)
	}
	// DO NOTHING also skips a key repeated within this same statement (a
	// batch that carries one event twice), so no DISTINCT is needed.
	inserted, err := tx.Exec(ctx, `
		INSERT INTO analytics.events SELECT * FROM analytics_stage
		ON CONFLICT (received_day, event_id) DO NOTHING`)
	if err != nil {
		return WriteResult{}, fmt.Errorf("analytics: insert: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return WriteResult{}, fmt.Errorf("analytics: commit: %w", err)
	}
	res := WriteResult{Inserted: int(inserted.RowsAffected()), OptedOut: int(optedOut.RowsAffected())}
	res.Duplicates = len(events) - res.OptedOut - res.Inserted
	return res, nil
}

func text(s string) pgtype.Text { return pgtype.Text{String: s, Valid: s != ""} }

// backgroundStatementTimeout lifts the 10-second request backstop for the
// day-sized background statements (aggregation, export), inside their own
// transaction only.
const backgroundStatementTimeout = `SET LOCAL statement_timeout = '120s'`

// exportRow is one archived line: the stored row without its per-person
// keys (#110).
type exportRow struct {
	EventID       uuid.UUID       `json:"event_id"`
	EventName     string          `json:"event_name"`
	SchemaVersion int32           `json:"schema_version"`
	Source        string          `json:"source"`
	OccurredAt    time.Time       `json:"occurred_at"`
	ReceivedAt    time.Time       `json:"received_at"`
	SessionID     *string         `json:"session_id,omitempty"`
	AppVersion    *string         `json:"app_version,omitempty"`
	OSName        *string         `json:"os_name,omitempty"`
	OSVersion     *string         `json:"os_version,omitempty"`
	DeviceClass   *string         `json:"device_class,omitempty"`
	Locale        *string         `json:"locale,omitempty"`
	Screen        *string         `json:"screen,omitempty"`
	FlowID        *string         `json:"flow_id,omitempty"`
	FlowStep      *string         `json:"flow_step,omitempty"`
	Attributes    json.RawMessage `json:"attributes"`
}

// ExportDay streams one day's events to w as NDJSON, one row per line, and
// returns how many it wrote. user_key and install_id are left out (#110):
// the archive outlives account deletion and opt-out, which can only erase
// what is in Postgres, so it holds nothing that links an event to a person
// or a device. Sessions, screens, flows and attributes keep it useful. It reads with a cursor, so a large day never
// sits in memory.
func (s *Store) ExportDay(ctx context.Context, day time.Time, w io.Writer) (int, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return 0, fmt.Errorf("analytics: export: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, backgroundStatementTimeout); err != nil {
		return 0, fmt.Errorf("analytics: export: %w", err)
	}
	rows, err := tx.Query(ctx, `
		SELECT event_id, event_name, schema_version, source, occurred_at, received_at,
		       session_id, app_version, os_name, os_version, device_class,
		       locale, screen, flow_id, flow_step, attributes
		FROM analytics.events
		WHERE received_day = $1
		ORDER BY received_at, event_id`, pgtype.Date{Time: day, Valid: true})
	if err != nil {
		return 0, fmt.Errorf("analytics: export: %w", err)
	}
	defer rows.Close()
	enc := json.NewEncoder(w)
	n := 0
	for rows.Next() {
		var r exportRow
		if err := rows.Scan(&r.EventID, &r.EventName, &r.SchemaVersion, &r.Source, &r.OccurredAt, &r.ReceivedAt,
			&r.SessionID, &r.AppVersion, &r.OSName, &r.OSVersion, &r.DeviceClass,
			&r.Locale, &r.Screen, &r.FlowID, &r.FlowStep, &r.Attributes); err != nil {
			return n, fmt.Errorf("analytics: export scan: %w", err)
		}
		r.OccurredAt, r.ReceivedAt = r.OccurredAt.UTC(), r.ReceivedAt.UTC()
		if err := enc.Encode(r); err != nil {
			return n, err
		}
		n++
	}
	return n, rows.Err()
}

// Aggregate rebuilds one day's aggregates in one transaction: every
// daily_* row for the day is replaced and the run recorded, so running it
// twice gives the same rows. A day is an Asia/Colombo calendar day (plan
// 29F); the queries read the two UTC partitions it spans.
func (s *Store) Aggregate(ctx context.Context, day time.Time) (int64, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("analytics: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	// A day's aggregation is background work over a whole day of events:
	// it gets its own statement limit instead of the request path's
	// 10-second backstop (platform/db), which it outgrows at a few million
	// events a day (scalability check 2026-11-01).
	if _, err := tx.Exec(ctx, backgroundStatementTimeout); err != nil {
		return 0, fmt.Errorf("analytics: statement timeout: %w", err)
	}
	q := s.Q.WithTx(tx)
	d := pgtype.Date{Time: day, Valid: true}
	for _, del := range []func(context.Context, pgtype.Date) error{
		q.DeleteScreenStats, q.DeleteFeatureStats, q.DeleteFunnelStats,
		q.DeleteSessionStats, q.DeleteErrorStats, q.DeleteCreditStats,
		q.DeleteAbandonStats, q.DeleteCreditBandStats, q.DeleteActivity,
	} {
		if err := del(ctx, d); err != nil {
			return 0, fmt.Errorf("analytics: clear aggregates: %w", err)
		}
	}
	for name, agg := range map[string]func(context.Context, pgtype.Date) (int64, error){
		"screens": q.AggregateScreens, "features": q.AggregateFeatures, "funnels": q.AggregateFunnels,
		"sessions": q.AggregateSessions, "errors": q.AggregateErrors, "credits": q.AggregateCredits,
		"first seen": q.UpsertFirstSeen,
		"abandons":   q.AggregateAbandons, "credit bands": q.AggregateCreditBands,
		"insufficient then purchase": q.AggregateInsufficientThenPurchase,
		"activity":                   q.AggregateActivity,
	} {
		if _, err := agg(ctx, d); err != nil {
			return 0, fmt.Errorf("analytics: aggregate %s: %w", name, err)
		}
	}
	events, err := q.CountPartitionEvents(ctx, d)
	if err != nil {
		return 0, fmt.Errorf("analytics: count: %w", err)
	}
	if err := q.InsertAggregateRun(ctx, sqlcgen.InsertAggregateRunParams{Day: d, Events: events}); err != nil {
		return 0, fmt.Errorf("analytics: record run: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("analytics: commit: %w", err)
	}
	return events, nil
}

// DeleteUser removes everything stored under one user_key: raw events, the
// cohort row, the activity days, and the opt-out (the account is gone).
func (s *Store) DeleteUser(ctx context.Context, userKey string) (int64, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("analytics: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.Q.WithTx(tx)
	n, err := q.DeleteEventsByUserKey(ctx, text(userKey))
	if err != nil {
		return 0, fmt.Errorf("analytics: delete events: %w", err)
	}
	if err := q.DeleteFirstSeen(ctx, userKey); err != nil {
		return 0, fmt.Errorf("analytics: delete first seen: %w", err)
	}
	if err := q.DeleteActivityByUserKey(ctx, userKey); err != nil {
		return 0, fmt.Errorf("analytics: delete activity: %w", err)
	}
	if err := q.DeleteOptOut(ctx, userKey); err != nil {
		return 0, fmt.Errorf("analytics: delete opt-out: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("analytics: commit: %w", err)
	}
	return n, nil
}
