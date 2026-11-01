package flags

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresStore reads and writes ops.feature_flags.
//
// Hand-written pgx rather than an sqlc entry: three statements over one
// small table, owned by a platform package rather than a module.
type PostgresStore struct {
	pool *pgxpool.Pool
}

// NewPostgresStore constructs a PostgresStore.
func NewPostgresStore(pool *pgxpool.Pool) *PostgresStore {
	return &PostgresStore{pool: pool}
}

var _ Store = (*PostgresStore)(nil)

// All reads every flag.
func (p *PostgresStore) All(ctx context.Context) ([]Flag, error) {
	rows, err := p.pool.Query(ctx, `SELECT key, enabled, rules, value FROM ops.feature_flags ORDER BY key`)
	if err != nil {
		return nil, fmt.Errorf("flags: read: %w", err)
	}
	defer rows.Close()
	var out []Flag
	for rows.Next() {
		var (
			f     Flag
			rules []byte
			value []byte
		)
		if err := rows.Scan(&f.Key, &f.Enabled, &rules, &value); err != nil {
			return nil, fmt.Errorf("flags: scan: %w", err)
		}
		if err := json.Unmarshal(rules, &f.Rules); err != nil {
			return nil, fmt.Errorf("flags: decode rules of %q: %w", f.Key, err)
		}
		if len(value) > 0 {
			f.Value = json.RawMessage(value)
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// Set writes one flag and its audit row in one transaction. Operator and
// reason are required: there is no anonymous way to change a flag.
func (p *PostgresStore) Set(ctx context.Context, f Flag, operator, reason string) error {
	if operator == "" || reason == "" {
		return errors.New("flags: operator and reason are required")
	}
	if err := Validate(f.Rules); err != nil {
		return err
	}
	if f.Rules == nil {
		f.Rules = []Rule{}
	}
	rules, err := json.Marshal(f.Rules)
	if err != nil {
		return fmt.Errorf("flags: encode rules: %w", err)
	}
	var value any
	if len(f.Value) > 0 {
		if !json.Valid(f.Value) {
			return errors.New("flags: value is not valid JSON")
		}
		value = []byte(f.Value)
	}

	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("flags: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var before []byte
	err = tx.QueryRow(ctx, `
		SELECT jsonb_build_object('enabled', enabled, 'rules', rules, 'value', value)
		FROM ops.feature_flags WHERE key = $1 FOR UPDATE`, f.Key).Scan(&before)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("flags: read before: %w", err)
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO ops.feature_flags (key, enabled, rules, value, updated_at, updated_by)
		VALUES ($1, $2, $3, $4, now(), $5)
		ON CONFLICT (key) DO UPDATE
		SET enabled = EXCLUDED.enabled, rules = EXCLUDED.rules, value = EXCLUDED.value,
		    updated_at = now(), updated_by = EXCLUDED.updated_by`,
		f.Key, f.Enabled, rules, value, operator); err != nil {
		return fmt.Errorf("flags: write: %w", err)
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO ops.feature_flag_audit (key, before, after, operator, reason)
		VALUES ($1, $2, jsonb_build_object('enabled', $3::boolean, 'rules', $4::jsonb, 'value', $5::jsonb), $6, $7)`,
		f.Key, before, f.Enabled, rules, value, operator, reason); err != nil {
		return fmt.Errorf("flags: audit: %w", err)
	}
	return tx.Commit(ctx)
}
