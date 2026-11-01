package billing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Operator actions, run by cmd/billingadmin against the database. There is no
// HTTP surface for any of this (plan 29 §1, API5). Every action names its
// operator and reason, and lands in the ledger or billing.admin_audit.

// AdminAction identifies who is acting and why.
type AdminAction struct {
	Operator string
	Reason   string
	// Key makes the action idempotent: running the same command twice with
	// the same key applies it once.
	Key string
}

func (a AdminAction) validate() error {
	if strings.TrimSpace(a.Operator) == "" || strings.TrimSpace(a.Reason) == "" {
		return fmt.Errorf("billing: --operator and --reason are required: %w", apperror.ErrInvalidInput)
	}
	if strings.TrimSpace(a.Key) == "" {
		return fmt.Errorf("billing: an idempotency key is required: %w", apperror.ErrInvalidInput)
	}
	return nil
}

// AdminGrant credits a user with an operator lot. expiresIn 0 means it never
// expires.
func (s *Service) AdminGrant(ctx context.Context, userID string, amount int64, expiresIn time.Duration, a AdminAction) (applied bool, err error) {
	if err := a.validate(); err != nil {
		return false, err
	}
	err = s.ledger.Do(ctx, userID, func(t *wallet.Tx) error {
		key := "admin:" + a.Key
		used, err := t.KeyUsed(key)
		if err != nil || used {
			return err
		}
		in := wallet.GrantInput{Kind: wallet.KindAdmin, Amount: amount, Key: key, RefType: "admin",
			Operator: a.Operator, Note: a.Reason}
		if expiresIn > 0 {
			at := t.Now().Add(expiresIn)
			in.ExpiresAt = &at
		}
		if _, err := t.Grant(in); err != nil {
			return err
		}
		applied = true
		return nil
	})
	return applied, err
}

// AdminAdjust adds (delta > 0) or removes (delta < 0) credits. Removal draws
// in spend order and never goes below zero.
func (s *Service) AdminAdjust(ctx context.Context, userID string, delta int64, a AdminAction) (applied bool, err error) {
	if err := a.validate(); err != nil {
		return false, err
	}
	if delta == 0 {
		return false, fmt.Errorf("billing: delta must not be zero: %w", apperror.ErrInvalidInput)
	}
	err = s.ledger.Do(ctx, userID, func(t *wallet.Tx) error {
		key := "adjust:" + a.Key
		used, err := t.KeyUsed(key)
		if err != nil {
			return err
		}
		if !used {
			used, err = t.KeyUsed(key + ":1")
			if err != nil {
				return err
			}
		}
		if used {
			return nil
		}
		if delta > 0 {
			_, err = t.Grant(wallet.GrantInput{Kind: wallet.KindAdmin, Amount: delta, Reason: "admin_adjust",
				Key: key, RefType: "admin", Operator: a.Operator, Note: a.Reason})
		} else {
			err = t.Remove(-delta, key, a.Operator, a.Reason)
		}
		if err == nil {
			applied = true
		}
		return err
	})
	return applied, err
}

// PlanNone cancels an operator-set plan.
const PlanNone = "none"

// AdminSetPlan gives a user a plan until a date (an enterprise contract, or
// a manual pro), or removes it with PlanNone.
func (s *Service) AdminSetPlan(ctx context.Context, userID, plan string, until time.Time, a AdminAction) error {
	if strings.TrimSpace(a.Operator) == "" || strings.TrimSpace(a.Reason) == "" {
		return fmt.Errorf("billing: --operator and --reason are required: %w", apperror.ErrInvalidInput)
	}
	uid, err := parseUser(userID)
	if err != nil {
		return err
	}
	now := s.now().UTC()
	status, code := "active", plan
	if plan == PlanNone {
		status, code = "canceled", "pro"
		until = now.Add(time.Second)
	} else {
		if _, err := s.q.GetPlan(ctx, plan); errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("billing: no plan %q: %w", plan, apperror.ErrInvalidInput)
		} else if err != nil {
			return err
		}
		if !until.After(now) {
			return fmt.Errorf("billing: --until must be in the future: %w", apperror.ErrInvalidInput)
		}
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)
	if err := q.UpsertManualSubscription(ctx, sqlcgen.UpsertManualSubscriptionParams{
		UserID: uid, PlanCode: code, Status: status, PeriodStart: ts(now), PeriodEnd: ts(until),
	}); err != nil {
		return fmt.Errorf("billing: set plan: %w", err)
	}
	detail, _ := json.Marshal(map[string]any{"plan": plan, "until": until})
	if err := q.InsertAdminAudit(ctx, sqlcgen.InsertAdminAuditParams{
		UserID: uid, Action: "set_plan", Detail: detail, Operator: a.Operator, Reason: a.Reason,
	}); err != nil {
		return fmt.Errorf("billing: audit set plan: %w", err)
	}
	return tx.Commit(ctx)
}

// HandleUserDeleted closes a deleted account's wallet (plan 3.6). Remaining
// purchased credits are recorded in the audit table; nothing is owed by the
// app, since store refunds go through Apple and Google. The welcome-grant
// row stays so deleting and re-creating an account does not earn a second
// grant. Idempotent.
func (s *Service) HandleUserDeleted(ctx context.Context, p eventbus.UserDeletedPayload) error {
	uid, err := parseUser(p.UserID)
	if err != nil {
		return nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)
	n, err := q.CloseWallet(ctx, uid)
	if err != nil {
		return fmt.Errorf("billing: close wallet: %w", err)
	}
	if n == 0 {
		return nil
	}
	purchased, err := q.SumOpenPurchasedCredits(ctx, uid)
	if err != nil {
		return fmt.Errorf("billing: sum purchased credits: %w", err)
	}
	detail, _ := json.Marshal(map[string]any{"remaining_purchased_credits": purchased})
	if err := q.InsertAdminAudit(ctx, sqlcgen.InsertAdminAuditParams{
		UserID: uid, Action: "account_deleted", Detail: detail, Operator: "system", Reason: "account deleted",
	}); err != nil {
		return fmt.Errorf("billing: audit deletion: %w", err)
	}
	return tx.Commit(ctx)
}
