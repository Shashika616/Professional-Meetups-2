package ratelimit

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Rule is one limit enforced through Postgres (tracker #81): at most Limit
// uses per subject per Window, counted across every instance.
//
// FailClosed says what happens when the database cannot be asked. For OTP
// sends, SOS and trusted-contact changes the answer is "refuse": an
// unlimited window on those is the abuse the limit exists to stop. For the
// rest a database hiccup should not block an ordinary action, so the use is
// allowed and logged.
type Rule struct {
	Name       string
	Limit      int
	Window     time.Duration
	FailClosed bool
}

// SharedDB is the one pool method the shared limiter needs.
type SharedDB interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// Shared counts uses in ops.rate_counters. Hand-written pgx rather than an
// sqlc entry: two statements, used by several modules.
//
// Windows are fixed and aligned to Asia/Colombo midnight (UTC+05:30), so a
// daily rule resets when a Sri Lankan user's day does. The clock is the
// database's: no instance's own time decides a window.
type Shared struct {
	db     SharedDB
	logger *slog.Logger
}

// NewShared constructs a Shared limiter.
func NewShared(db SharedDB, logger *slog.Logger) *Shared {
	if logger == nil {
		logger = slog.Default()
	}
	return &Shared{db: db, logger: logger}
}

// colomboOffsetSeconds aligns windows to Asia/Colombo days (no DST).
const colomboOffsetSeconds = 19800

// claimSQL takes one use in the subject's current window, or none when the
// window is full. One statement, so two instances racing for the last use
// cannot both get it.
const claimSQL = `
WITH w AS (
    SELECT to_timestamp(floor((extract(epoch FROM now()) + $4) / $2) * $2 - $4) AS start
)
INSERT INTO ops.rate_counters (key_hash, window_start, count, expires_at)
SELECT $1, w.start, 1, w.start + make_interval(secs => $2) FROM w
ON CONFLICT (key_hash, window_start) DO UPDATE
    SET count = ops.rate_counters.count + 1
    WHERE ops.rate_counters.count < $3
RETURNING count`

// Check counts one use of rule by subject. It returns an error wrapping
// apperror.ErrRateLimited when the window is full, apperror.ErrUnavailable
// when the database cannot be asked and the rule fails closed, and nil
// otherwise. subject is hashed with the rule's name before it is stored,
// so no e-mail address, phone number or user id lands in the table.
//
// A nil *Shared allows everything; production always wires one
// (cmd/monolith), and tests that are not about limits need not.
func (s *Shared) Check(ctx context.Context, rule Rule, subject string) error {
	if s == nil {
		return nil
	}
	if rule.Limit <= 0 || rule.Window < time.Second {
		return fmt.Errorf("ratelimit: rule %q is not a limit: %w", rule.Name, apperror.ErrInternal)
	}
	key := sha256.Sum256([]byte(rule.Name + "\x00" + subject))
	var count int
	err := s.db.QueryRow(ctx, claimSQL, key[:], int64(rule.Window/time.Second), rule.Limit, colomboOffsetSeconds).Scan(&count)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("too many attempts, please try again later: %w", apperror.ErrRateLimited)
	case rule.FailClosed:
		s.logger.Error("ratelimit: shared counter unavailable, refusing", "rule", rule.Name, "error", err)
		return fmt.Errorf("please try again in a moment: %w", apperror.ErrUnavailable)
	default:
		s.logger.Warn("ratelimit: shared counter unavailable, allowing", "rule", rule.Name, "error", err)
		return nil
	}
}

// Sweep deletes finished windows and returns how many rows went.
func (s *Shared) Sweep(ctx context.Context) (int64, error) {
	if s == nil {
		return 0, nil
	}
	tag, err := s.db.Exec(ctx, `DELETE FROM ops.rate_counters WHERE expires_at < now()`)
	if err != nil {
		return 0, fmt.Errorf("ratelimit: sweep: %w", err)
	}
	return tag.RowsAffected(), nil
}
