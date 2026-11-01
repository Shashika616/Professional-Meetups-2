package billing

import (
	"context"
	"encoding/base64"
	"fmt"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// expiringWindow is how far ahead the wallet lists credits about to expire
// or decay.
const expiringWindow = 14 * 24 * time.Hour

// ExpiringLot is credits that will expire or start decaying soon.
type ExpiringLot struct {
	Kind             string
	Remaining        int64
	ExpiresAt        *time.Time
	NextDecayAt      *time.Time
	NextDecayCredits int64
}

// WalletView is GET /v1/billing/wallet.
type WalletView struct {
	Balance      int64
	Held         int64
	Available    int64
	Debt         int64
	ExpiringSoon []ExpiringLot
}

// Wallet is the caller's balance and what is about to expire. It applies due
// decay first so the figures are true, and grants the welcome credits the
// first time a hosting-level user looks.
func (s *Service) Wallet(ctx context.Context, caller Caller) (WalletView, error) {
	if _, err := parseUser(caller.UserID); err != nil {
		return WalletView{}, err
	}
	s.ensureWelcome(ctx, caller)
	var v WalletView
	err := s.ledger.Do(ctx, caller.UserID, func(t *wallet.Tx) error {
		v = WalletView{Balance: t.Balance(), Held: t.Held(), Available: t.Available(), Debt: t.Debt()}
		lots, err := t.Queries().ListOpenLots(ctx, t.UserID())
		if err != nil {
			return fmt.Errorf("billing: list lots: %w", err)
		}
		horizon := t.Now().Add(expiringWindow)
		for _, l := range lots {
			e := ExpiringLot{Kind: l.Kind, Remaining: l.Remaining}
			soon := false
			if l.ExpiresAt.Valid && l.ExpiresAt.Time.Before(horizon) {
				at := l.ExpiresAt.Time
				e.ExpiresAt, soon = &at, true
			}
			if l.DecayPercent.Valid && l.NextDecayAt.Valid && l.NextDecayAt.Time.Before(horizon) {
				at := l.NextDecayAt.Time
				e.NextDecayAt, soon = &at, true
				next := wallet.AllowedAfter(l.Initial, int(l.DecayPercent.Int32), int(l.DecayPeriodsApplied)+1)
				e.NextDecayCredits = max(l.Remaining-next, 0)
			}
			if soon {
				v.ExpiringSoon = append(v.ExpiringSoon, e)
			}
		}
		return nil
	})
	return v, err
}

// LedgerEntry is one row of the caller's history.
type LedgerEntry struct {
	ID           int64
	Delta        int64
	HeldDelta    int64
	Reason       string
	RefType      string
	RefID        string
	BalanceAfter int64
	CreatedAt    time.Time
}

// LedgerPage is one page of history and the cursor for the next, "" at the
// end.
type LedgerPage struct {
	Entries    []LedgerEntry
	NextCursor string
}

const (
	defaultLedgerPage = 30
	maxLedgerPage     = 100
)

// Ledger is the caller's history, newest first, keyset-paginated. The cursor
// only positions within the caller's own rows: every query is filtered by the
// user id from the token, so a cursor taken from someone else's page shows
// nothing of theirs.
func (s *Service) Ledger(ctx context.Context, userID, cursor string, pageSize int) (LedgerPage, error) {
	uid, err := parseUser(userID)
	if err != nil {
		return LedgerPage{}, err
	}
	before := int64(0)
	if cursor != "" {
		raw, err := base64.RawURLEncoding.DecodeString(cursor)
		if err == nil {
			before, err = strconv.ParseInt(string(raw), 10, 64)
		}
		if err != nil || before <= 0 {
			return LedgerPage{}, fmt.Errorf("billing: invalid cursor: %w", apperror.ErrInvalidInput)
		}
	}
	if pageSize <= 0 {
		pageSize = defaultLedgerPage
	}
	pageSize = min(pageSize, maxLedgerPage)

	rows, err := s.q.ListLedger(ctx, sqlcgen.ListLedgerParams{UserID: uid, BeforeID: before, PageSize: int32(pageSize + 1)})
	if err != nil {
		return LedgerPage{}, fmt.Errorf("billing: list ledger: %w", err)
	}
	page := LedgerPage{}
	for i, r := range rows {
		if i == pageSize {
			page.NextCursor = base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(rows[i-1].ID, 10)))
			break
		}
		page.Entries = append(page.Entries, LedgerEntry{
			ID: r.ID, Delta: r.Delta, HeldDelta: r.HeldDelta, Reason: r.Reason,
			RefType: r.RefType.String, RefID: r.RefID.String,
			BalanceAfter: r.BalanceAfter, CreatedAt: r.CreatedAt.Time,
		})
	}
	return page, nil
}

func ts(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }
