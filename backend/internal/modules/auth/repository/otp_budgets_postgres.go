package repository

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository/sqlcgen"
)

// OTPBudgetRepository counts, per target, purpose and Asia/Colombo day, the
// codes sent and the guesses that failed (plan 30B, #106). The target is
// passed as a hash; the table never holds an address or number.
type OTPBudgetRepository interface {
	// TakeSend takes one send and reports false when the day's max is spent.
	TakeSend(ctx context.Context, targetHash []byte, purpose string, max int) (bool, error)
	// TakeGuess takes one guess before the code is compared, and reports
	// false when the day's max is spent. A guess that turns out right is
	// handed back with RefundGuess.
	TakeGuess(ctx context.Context, targetHash []byte, purpose string, max int) (bool, error)
	RefundGuess(ctx context.Context, targetHash []byte, purpose string) error
	// DeleteOld removes days before yesterday and returns how many went.
	DeleteOld(ctx context.Context) (int64, error)
}

type postgresOTPBudgetRepository struct{ q *sqlcgen.Queries }

// NewOTPBudgetRepository constructs an OTPBudgetRepository backed by pool.
func NewOTPBudgetRepository(pool *pgxpool.Pool) OTPBudgetRepository {
	return &postgresOTPBudgetRepository{q: sqlcgen.New(pool)}
}

func (r *postgresOTPBudgetRepository) TakeSend(ctx context.Context, targetHash []byte, purpose string, max int) (bool, error) {
	_, err := r.q.TakeOTPSend(ctx, sqlcgen.TakeOTPSendParams{TargetHash: targetHash, Purpose: purpose, MaxSends: int32(max)})
	return taken(err, "send")
}

func (r *postgresOTPBudgetRepository) TakeGuess(ctx context.Context, targetHash []byte, purpose string, max int) (bool, error) {
	_, err := r.q.TakeOTPGuess(ctx, sqlcgen.TakeOTPGuessParams{TargetHash: targetHash, Purpose: purpose, MaxGuesses: int32(max)})
	return taken(err, "guess")
}

func (r *postgresOTPBudgetRepository) RefundGuess(ctx context.Context, targetHash []byte, purpose string) error {
	if err := r.q.RefundOTPGuess(ctx, sqlcgen.RefundOTPGuessParams{TargetHash: targetHash, Purpose: purpose}); err != nil {
		return fmt.Errorf("repository: refund otp guess: %w", err)
	}
	return nil
}

func (r *postgresOTPBudgetRepository) DeleteOld(ctx context.Context) (int64, error) {
	n, err := r.q.DeleteOldOTPBudgets(ctx)
	if err != nil {
		return 0, fmt.Errorf("repository: delete old otp budgets: %w", err)
	}
	return n, nil
}

// taken reads a conditional upsert: a row back means taken, no row means
// the cap refused it.
func taken(err error, what string) (bool, error) {
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, pgx.ErrNoRows):
		return false, nil
	default:
		return false, fmt.Errorf("repository: take otp %s: %w", what, err)
	}
}
