package billing

import (
	"context"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
)

// GrantLotForTest creates a lot of any kind directly. Purchased lots arrive
// with store purchases in 29B; these tests need one now to check the spend
// order and refunds across lot kinds.
func (s *Service) GrantLotForTest(ctx context.Context, userID, kind string, amount int64, expires *time.Time) (uuid.UUID, error) {
	var lot uuid.UUID
	err := s.ledger.Do(ctx, userID, func(t *wallet.Tx) error {
		var err error
		lot, err = t.Grant(wallet.GrantInput{Kind: kind, Amount: amount, ExpiresAt: expires,
			Key: "test-grant:" + uuid.NewString(), RefType: "test"})
		return err
	})
	return lot, err
}

// LedgerForTest exposes the ledger so tests can drive holds directly.
func (s *Service) LedgerForTest() *wallet.Ledger { return s.ledger }
