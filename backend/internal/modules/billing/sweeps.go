package billing

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
)

// sweepBatch bounds one sweep's work so it stays well inside the tick's
// per-sweep 30-second budget; anything left is picked up next tick.
const sweepBatch = 200

// SweepExpiredHolds releases reservations whose TTL has passed (plan 3.2):
// a create that crashed between reserving and committing leaves a hold that
// nothing else would ever release.
func (s *Service) SweepExpiredHolds(ctx context.Context) (int, error) {
	rows, err := s.q.ExpiredHolds(ctx, sqlcgen.ExpiredHoldsParams{Now: ts(s.now().UTC()), BatchSize: sweepBatch})
	if err != nil {
		return 0, fmt.Errorf("billing: list expired holds: %w", err)
	}
	released := 0
	for _, row := range rows {
		err := s.ledger.Do(ctx, row.UserID.String(), func(t *wallet.Tx) error {
			ok, err := t.Release(row.ID, "expired")
			if ok {
				released++
			}
			return err
		})
		if err != nil {
			return released, err
		}
	}
	return released, nil
}

// SweepDecayAndExpiry materialises decay periods and expiries that have come
// due, for users who have not touched their wallet since. The spend path
// does the same for its own user, so this sweep only keeps balances
// truthful for people who are not spending.
func (s *Service) SweepDecayAndExpiry(ctx context.Context) (int, error) {
	users, err := s.q.UsersWithDueLots(ctx, sqlcgen.UsersWithDueLotsParams{Now: ts(s.now().UTC()), BatchSize: sweepBatch})
	if err != nil {
		return 0, fmt.Errorf("billing: list due lots: %w", err)
	}
	for _, u := range users {
		if err := s.ledger.ApplyDue(ctx, u); err != nil {
			return 0, err
		}
	}
	return len(users), nil
}

// Mismatch is one wallet whose stored figures disagree with its lots, holds
// or ledger.
type Mismatch struct {
	UserID        string `json:"user_id"`
	Balance       int64  `json:"balance"`
	Held          int64  `json:"held"`
	Debt          int64  `json:"debt"`
	LotsRemaining int64  `json:"lots_remaining"`
	HoldsHeld     int64  `json:"holds_held"`
	LedgerBalance int64  `json:"ledger_balance"`
	LedgerHeld    int64  `json:"ledger_held"`
	LedgerDebt    int64  `json:"ledger_debt"`
}

// FindMismatches runs the reconciliation query (plan 3.2) without recording
// a run.
func (s *Service) FindMismatches(ctx context.Context) ([]Mismatch, error) {
	// A full pass over the ledger: background work that outgrows the
	// request path's 10-second statement backstop at a few million ledger
	// rows (1.6 s at a million in the 29F scalability check), so it runs in
	// a read-only transaction with its own limit.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("billing: reconcile: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '120s'`); err != nil {
		return nil, fmt.Errorf("billing: reconcile: %w", err)
	}
	rows, err := s.q.WithTx(tx).ReconcileWallets(ctx)
	if err != nil {
		return nil, fmt.Errorf("billing: reconcile: %w", err)
	}
	out := make([]Mismatch, 0, len(rows))
	for _, r := range rows {
		out = append(out, Mismatch{
			UserID: r.UserID.String(), Balance: r.Balance, Held: r.Held, Debt: r.Debt,
			LotsRemaining: r.LotsRemaining, HoldsHeld: r.HoldsHeld,
			LedgerBalance: r.LedgerBalance, LedgerHeld: r.LedgerHeld, LedgerDebt: r.LedgerDebt,
		})
	}
	return out, nil
}

// Reconcile is the daily reconciliation sweep. The tick runs every few
// minutes; this does its work once per UTC day and records the result in
// billing.reconciliation_runs for the daily report. Every mismatch is
// logged at error level: one should never exist.
func (s *Service) Reconcile(ctx context.Context) (int, error) {
	today := s.now().UTC().Truncate(24 * time.Hour)
	date := pgtype.Date{Time: today, Valid: true}
	done, err := s.q.ReconciliationRunExists(ctx, date)
	if err != nil {
		return 0, fmt.Errorf("billing: read reconciliation runs: %w", err)
	}
	if done {
		return 0, nil
	}
	mismatches, err := s.FindMismatches(ctx)
	if err != nil {
		return 0, err
	}
	checked, err := s.q.CountWallets(ctx)
	if err != nil {
		return 0, fmt.Errorf("billing: count wallets: %w", err)
	}
	for _, m := range mismatches {
		s.logger.Error("billing: reconciliation mismatch", "mismatch", m)
	}
	detail, err := json.Marshal(mismatches)
	if err != nil {
		return 0, err
	}
	if _, err := s.q.InsertReconciliationRun(ctx, sqlcgen.InsertReconciliationRunParams{
		RunDate: date, Checked: int32(checked), Mismatches: int32(len(mismatches)), Detail: detail,
	}); err != nil {
		return 0, fmt.Errorf("billing: record reconciliation run: %w", err)
	}
	return int(checked), nil
}

// ReconciliationRun is the day's reconciliation result as counts, for the
// daily analytics report (29F). found is false when no run is recorded.
// Never the detail: it names wallets.
func (s *Service) ReconciliationRun(ctx context.Context, day time.Time) (checked, mismatches int64, found bool, err error) {
	rows, err := s.q.GetReconciliationRun(ctx, pgtype.Date{Time: day, Valid: true})
	if err != nil {
		return 0, 0, false, fmt.Errorf("billing: read reconciliation run: %w", err)
	}
	if len(rows) == 0 {
		return 0, 0, false, nil
	}
	return int64(rows[0].Checked), int64(rows[0].Mismatches), true, nil
}
