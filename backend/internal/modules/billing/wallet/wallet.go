// Package wallet is the billing module's ledger core (plan 29 §3.2): credit
// lots, holds, captures, releases, refunds, decay, expiry and debt.
//
// # ONE RULE HOLDS IT TOGETHER
//
// Every write happens inside Ledger.Do, which opens one transaction, locks
// the user's wallet row FOR UPDATE, materialises any decay or expiry that has
// come due, runs the operation, writes the wallet's new figures and commits.
// So:
//
//   - one user's operations are serialised by that one row lock, and the
//     lock order is always wallet, then lots, then holds;
//   - every change to a balance is a ledger entry in the same transaction,
//     with an idempotency key unique per user;
//   - a spend is always priced against the true balance, never one that a
//     decay sweep has not caught up with yet.
//
// Nothing here knows about meetups, prices or plans' rules. Callers decide
// what to reserve and when to capture; this package keeps the books.
package wallet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Lot kinds and hold kinds, as stored.
const (
	KindWelcome  = "welcome"
	KindPurchase = "purchase"
	KindPromo    = "promo"
	KindRefund   = "refund"
	KindAdmin    = "admin"

	HoldCredits   = "credits"
	HoldPlanQuota = "plan_quota"

	StateHeld     = "held"
	StateCaptured = "captured"
	StateReleased = "released"

	// ReleaseSettled marks a hold released because its meetup was cancelled
	// for a full refund before the capture arrived. Capture leaves such a
	// hold alone: the meetup is over and nothing is owed.
	ReleaseSettled = "refunded_before_capture"
)

// spendBatch is how many lots a capture locks at a time. Most captures are
// covered by the first lot; the loop only goes round again when a lot runs
// out, so a capture touches O(lots used), not O(lots owned).
const spendBatch = 8

var (
	// ErrAlreadyApplied means an idempotency key was seen before. Do rolls
	// the transaction back; callers that check first never see it.
	ErrAlreadyApplied = errors.New("wallet: operation already applied")
	// ErrQuotaExhausted is a plan-quota reservation with no quota left.
	ErrQuotaExhausted = errors.New("wallet: plan quota exhausted")
	// ErrWalletClosed is any new reservation on a deleted account's wallet.
	ErrWalletClosed = fmt.Errorf("wallet: the wallet is closed: %w", apperror.ErrForbidden)
	// ErrInsufficientForAdjust is a negative admin adjustment larger than
	// the balance. Adjustments never create debt.
	ErrInsufficientForAdjust = fmt.Errorf("wallet: not enough credits to remove: %w", apperror.ErrInvalidInput)
)

// Ledger runs wallet operations.
type Ledger struct {
	pool   *pgxpool.Pool
	q      *sqlcgen.Queries
	now    func() time.Time
	logger *slog.Logger
}

// New constructs a Ledger. now is the server clock (tests pass a fake one to
// walk through decay periods).
func New(pool *pgxpool.Pool, now func() time.Time, logger *slog.Logger) *Ledger {
	if now == nil {
		now = time.Now
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Ledger{pool: pool, q: sqlcgen.New(pool), now: now, logger: logger}
}

// Tx is one user's locked wallet inside one transaction.
type Tx struct {
	ctx    context.Context
	q      *sqlcgen.Queries
	logger *slog.Logger
	userID uuid.UUID
	now    time.Time

	balance, held, debt int64
	start               [3]int64
	closed              bool

	// changes is this transaction's balance change per ledger reason, for
	// credits.changed (plan 29D: analytics tells a grant from a spend from
	// an expiry without reading the ledger).
	changes map[string]int64
}

// UserID is the wallet's owner.
func (t *Tx) UserID() uuid.UUID { return t.userID }

// Now is the server time this transaction runs at.
func (t *Tx) Now() time.Time { return t.now }

// Queries exposes the transaction's queries to the billing service for
// statements outside this package's concern (welcome grants, refund log,
// plan usage reads).
func (t *Tx) Queries() *sqlcgen.Queries { return t.q }

// Balance, Held, Debt and Available are the wallet's current figures.
func (t *Tx) Balance() int64   { return t.balance }
func (t *Tx) Held() int64      { return t.held }
func (t *Tx) Debt() int64      { return t.debt }
func (t *Tx) Available() int64 { return max(t.balance-t.held, 0) }

// Do runs fn against userID's wallet under its row lock, creating the wallet
// on first use.
func (l *Ledger) Do(ctx context.Context, userID string, fn func(*Tx) error) error {
	uid, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("wallet: invalid user id: %w", apperror.ErrInvalidInput)
	}
	return l.do(ctx, uid, false, fn)
}

// do is Do with the choice of skipping a wallet another transaction holds
// (sweeps). A skipped wallet runs nothing and returns nil.
func (l *Ledger) do(ctx context.Context, uid uuid.UUID, skipLocked bool, fn func(*Tx) error) error {
	pgxTx, err := l.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("wallet: begin: %w: %w", apperror.ErrInternal, err)
	}
	defer func() { _ = pgxTx.Rollback(ctx) }()
	q := l.q.WithTx(pgxTx)

	var w sqlcgen.BillingWallet
	if skipLocked {
		w, err = q.LockWalletNoWait(ctx, uid)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
	} else {
		if err := q.EnsureWallet(ctx, uid); err != nil {
			return fmt.Errorf("wallet: ensure: %w", err)
		}
		w, err = q.LockWallet(ctx, uid)
	}
	if err != nil {
		return fmt.Errorf("wallet: lock: %w", err)
	}

	t := &Tx{
		ctx: ctx, q: q, logger: l.logger, userID: uid, now: l.now().UTC(),
		balance: w.Balance, held: w.Held, debt: w.Debt,
		start:  [3]int64{w.Balance, w.Held, w.Debt},
		closed: w.ClosedAt.Valid,
	}
	if err := t.applyDue(); err != nil {
		return err
	}
	if fn != nil {
		if err := fn(t); err != nil {
			return err
		}
	}
	if err := t.flush(); err != nil {
		return err
	}
	if err := pgxTx.Commit(ctx); err != nil {
		return fmt.Errorf("wallet: commit: %w: %w", apperror.ErrInternal, err)
	}
	return nil
}

// flush writes the wallet's figures and a credits.changed event when they
// moved.
func (t *Tx) flush() error {
	if [3]int64{t.balance, t.held, t.debt} == t.start {
		return nil
	}
	if err := t.q.UpdateWallet(t.ctx, sqlcgen.UpdateWalletParams{
		UserID: t.userID, Balance: t.balance, Held: t.held, Debt: t.debt,
	}); err != nil {
		return fmt.Errorf("wallet: update: %w", err)
	}
	payload, err := json.Marshal(map[string]any{
		"user_id":     t.userID.String(),
		"balance":     t.balance,
		"held":        t.held,
		"debt":        t.debt,
		"available":   t.Available(),
		"changes":     t.changes,
		"occurred_at": t.now,
	})
	if err != nil {
		return err
	}
	if err := t.q.InsertBillingOutbox(t.ctx, sqlcgen.InsertBillingOutboxParams{
		Topic: "credits.changed", Payload: payload,
	}); err != nil {
		return fmt.Errorf("wallet: queue credits.changed: %w", err)
	}
	t.start = [3]int64{t.balance, t.held, t.debt}
	t.changes = nil
	return nil
}

// entry is one ledger row.
type entry struct {
	delta, heldDelta, debtDelta int64
	reason                      string
	lotID, holdID               uuid.UUID
	refType, refID              string
	key                         string
	operator, note              string
}

// write applies an entry to the in-memory figures and appends it to the
// ledger. A replayed key is ErrAlreadyApplied, which rolls everything back.
func (t *Tx) write(e entry) error {
	balance, held, debt := t.balance+e.delta, t.held+e.heldDelta, t.debt+e.debtDelta
	if balance < 0 || held < 0 || debt < 0 {
		return fmt.Errorf("wallet: %s would make balance %d, held %d, debt %d: %w",
			e.reason, balance, held, debt, apperror.ErrInternal)
	}
	n, err := t.q.InsertLedgerEntry(t.ctx, sqlcgen.InsertLedgerEntryParams{
		UserID:         t.userID,
		Delta:          e.delta,
		HeldDelta:      e.heldDelta,
		DebtDelta:      e.debtDelta,
		Reason:         e.reason,
		LotID:          nullUUID(e.lotID),
		HoldID:         nullUUID(e.holdID),
		RefType:        nullText(e.refType),
		RefID:          nullText(e.refID),
		BalanceAfter:   balance,
		HeldAfter:      held,
		DebtAfter:      debt,
		IdempotencyKey: e.key,
		Operator:       nullText(e.operator),
		Note:           nullText(e.note),
	})
	if err != nil {
		return fmt.Errorf("wallet: write ledger: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("%w (%s)", ErrAlreadyApplied, e.key)
	}
	t.balance, t.held, t.debt = balance, held, debt
	if e.delta != 0 {
		if t.changes == nil {
			t.changes = map[string]int64{}
		}
		t.changes[e.reason] += e.delta
	}
	return nil
}

// KeyUsed reports whether this wallet's ledger already has key.
func (t *Tx) KeyUsed(key string) (bool, error) {
	return t.q.LedgerKeyExists(t.ctx, sqlcgen.LedgerKeyExistsParams{UserID: t.userID, IdempotencyKey: key})
}

// --- grants ---

// Decay configures a decaying lot.
type Decay struct {
	Percent int
	Every   time.Duration
}

// GrantInput is one new lot.
type GrantInput struct {
	Kind      string
	Amount    int64
	ExpiresAt *time.Time
	Decay     *Decay
	SourceRef string
	// Reason is the ledger reason: "grant" normally, "admin_adjust" for an
	// operator's positive adjustment.
	Reason   string
	Key      string
	RefType  string
	RefID    string
	Operator string
	Note     string
}

// Grant creates a lot and credits it, then pays off any debt from it
// (plan 3.6: future grants pay debt first).
func (t *Tx) Grant(in GrantInput) (uuid.UUID, error) {
	if in.Amount <= 0 {
		return uuid.Nil, fmt.Errorf("wallet: grant amount must be positive: %w", apperror.ErrInvalidInput)
	}
	params := sqlcgen.InsertLotParams{
		UserID: t.userID, Kind: in.Kind, Initial: in.Amount, GrantedAt: ts(t.now),
		SourceRef: nullText(in.SourceRef),
	}
	if in.ExpiresAt != nil {
		params.ExpiresAt = ts(*in.ExpiresAt)
	}
	if in.Decay != nil {
		params.DecayPercent = pgtype.Int4{Int32: int32(in.Decay.Percent), Valid: true}
		params.DecayEvery = pgtype.Interval{Microseconds: in.Decay.Every.Microseconds(), Valid: true}
		params.NextDecayAt = ts(t.now.Add(in.Decay.Every))
	}
	lot, err := t.q.InsertLot(t.ctx, params)
	if err != nil {
		return uuid.Nil, fmt.Errorf("wallet: insert lot: %w", err)
	}
	reason := in.Reason
	if reason == "" {
		reason = "grant"
	}
	if err := t.write(entry{
		delta: in.Amount, reason: reason, lotID: lot.ID,
		refType: in.RefType, refID: in.RefID, key: in.Key,
		operator: in.Operator, note: in.Note,
	}); err != nil {
		return uuid.Nil, err
	}
	return lot.ID, t.settleDebt()
}

// settleDebt pays debt off from open lots in spend order.
func (t *Tx) settleDebt() error {
	if t.debt == 0 {
		return nil
	}
	return t.spend(t.debt, func(lotID uuid.UUID, take int64) error {
		return t.write(entry{
			delta: -take, debtDelta: -take, reason: "reversal", lotID: lotID,
			refType: "debt", key: "debt:" + uuid.NewString(),
		})
	})
}

// spend takes up to amount from open lots in spend order (expiring first),
// calling take for each piece, and returns how much it could not cover.
func (t *Tx) spendFrom(amount int64, take func(lotID uuid.UUID, n int64) error) (uncovered int64, err error) {
	need := amount
	for need > 0 {
		lots, err := t.q.LockSpendableLots(t.ctx, sqlcgen.LockSpendableLotsParams{
			UserID: t.userID, Now: ts(t.now), BatchSize: spendBatch,
		})
		if err != nil {
			return need, fmt.Errorf("wallet: lock lots: %w", err)
		}
		if len(lots) == 0 {
			break
		}
		for _, lot := range lots {
			n := min(lot.Remaining, need)
			if err := t.q.SetLotRemaining(t.ctx, sqlcgen.SetLotRemainingParams{ID: lot.ID, Remaining: lot.Remaining - n}); err != nil {
				return need, fmt.Errorf("wallet: draw from lot: %w", err)
			}
			if err := take(lot.ID, n); err != nil {
				return need, err
			}
			need -= n
			if need == 0 {
				break
			}
		}
	}
	return need, nil
}

func (t *Tx) spend(amount int64, take func(lotID uuid.UUID, n int64) error) error {
	_, err := t.spendFrom(amount, take)
	return err
}

// Remove takes credits out by operator action, in spend order. It never
// creates debt: removing more than the balance is refused.
func (t *Tx) Remove(amount int64, key, operator, note string) error {
	if amount <= 0 {
		return fmt.Errorf("wallet: amount to remove must be positive: %w", apperror.ErrInvalidInput)
	}
	if amount > t.Available() {
		return ErrInsufficientForAdjust
	}
	i := 0
	return t.spend(amount, func(lotID uuid.UUID, n int64) error {
		i++
		return t.write(entry{delta: -n, reason: "admin_adjust", lotID: lotID, refType: "admin",
			key: fmt.Sprintf("%s:%d", key, i), operator: operator, note: note})
	})
}

// --- small conversions ---

func ts(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

func nullText(s string) pgtype.Text { return pgtype.Text{String: s, Valid: s != ""} }

func nullUUID(id uuid.UUID) pgtype.UUID { return pgtype.UUID{Bytes: id, Valid: id != uuid.Nil} }

func intervalDuration(i pgtype.Interval) time.Duration {
	if !i.Valid {
		return 0
	}
	return time.Duration(i.Microseconds)*time.Microsecond +
		time.Duration(i.Days)*24*time.Hour +
		time.Duration(i.Months)*30*24*time.Hour
}
