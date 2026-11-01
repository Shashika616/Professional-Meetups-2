package billing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
	"professional-meetups-monolith/backend/internal/platform/flags"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// AccountTokenNamespace is the UUIDv5 namespace for the account token the
// app attaches to every purchase (Apple appAccountToken, Google
// obfuscatedAccountId): uuid.NewSHA1(AccountTokenNamespace, user id). The
// app must use exactly this value (docs/api/billing.md). Changing it would
// orphan every purchase made before the change.
var AccountTokenNamespace = uuid.MustParse("2cea7eda-3ade-4a4a-8872-aba93a04a532")

// AccountToken is the token a purchase by userID must carry. It binds a
// receipt to one account: replaying it on another account fails the check.
func AccountToken(userID string) string {
	return uuid.NewSHA1(AccountTokenNamespace, []byte(strings.ToLower(userID))).String()
}

// maxPurchaseToken bounds the token the app sends: a StoreKit 2 JWS is a
// few kilobytes, a Google token a few hundred bytes.
const maxPurchaseToken = 16 << 10

// Outbox topics 29B adds.
const (
	TopicStoreFinish             = "store.finish"
	TopicPurchaseVerified        = "purchase.verified"
	TopicSubscriptionActivated   = "subscription.activated"
	TopicSubscriptionDeactivated = "subscription.deactivated"
)

// PurchaseRequest is what the app sends after a store purchase: which
// store, which product, and the store's token. Never an amount.
type PurchaseRequest struct {
	Platform  string
	ProductID string
	Token     string
}

// PurchaseResult is the state after a verified purchase.
type PurchaseResult struct {
	Kind           string
	ProductID      string
	CreditsGranted int64
	// AlreadyProcessed is a repeat of a purchase verified before; nothing
	// new was granted.
	AlreadyProcessed bool
	Wallet           WalletView
	Subscription     SubscriptionView
}

// VerifyPurchase verifies a store purchase and grants it, exactly once
// (plan 29 §3.7). Credit packs become a purchase lot that never expires;
// subscriptions activate the plan. A paid purchase is granted whatever the
// flags say.
func (s *Service) VerifyPurchase(ctx context.Context, caller Caller, req PurchaseRequest) (PurchaseResult, error) {
	uid, err := parseUser(caller.UserID)
	if err != nil {
		return PurchaseResult{}, err
	}
	platform := store.Platform(req.Platform)
	if platform != store.IOS && platform != store.Android {
		return PurchaseResult{}, fmt.Errorf("billing: platform must be ios or android: %w", apperror.ErrInvalidInput)
	}
	if req.Token == "" || len(req.Token) > maxPurchaseToken {
		return PurchaseResult{}, fmt.Errorf("billing: a purchase token is required: %w", apperror.ErrInvalidInput)
	}
	product, err := s.q.GetStoreProduct(ctx, req.ProductID)
	if errors.Is(err, pgx.ErrNoRows) {
		return PurchaseResult{}, fmt.Errorf("billing: %q is not something TieHere sells: %w", req.ProductID, apperror.ErrInvalidInput)
	}
	if err != nil {
		return PurchaseResult{}, fmt.Errorf("billing: read product: %w", err)
	}
	kind := store.Kind(product.Kind)

	tx, err := s.store.Verify(ctx, store.Request{Platform: platform, Kind: kind, ProductID: product.ProductID, Token: req.Token})
	if err != nil {
		return PurchaseResult{}, s.verifyError(platform, err)
	}
	if err := s.checkTransaction(ctx, caller, platform, product, tx); err != nil {
		s.logger.Warn("billing: verified purchase refused", "platform", platform, "product_id", product.ProductID, "reason", err)
		return PurchaseResult{}, err
	}

	var (
		res        PurchaseResult
		purchaseID uuid.UUID
	)
	res.Kind, res.ProductID = product.Kind, product.ProductID
	finishToken := ""
	if platform == store.Android {
		finishToken = req.Token
	}
	if kind == store.Consumable {
		purchaseID, res.CreditsGranted, res.AlreadyProcessed, err = s.grantPack(ctx, uid, product, tx, finishToken)
	} else {
		purchaseID, res.AlreadyProcessed, err = s.activateSubscription(ctx, caller, product, tx, finishToken)
	}
	if err != nil {
		return PurchaseResult{}, err
	}
	if !res.AlreadyProcessed {
		metrics.Default.PurchasesVerified.WithLabelValues(string(platform), product.Kind).Inc()
	}
	// Tell Google now; the store.finish outbox row queued with the grant
	// retries it if this fails.
	if platform == store.Android {
		if err := s.finishPurchase(ctx, purchaseID); err != nil {
			s.logger.Warn("billing: finish purchase with the store, will retry", "purchase_id", purchaseID, "error", err)
		}
	}

	if res.Wallet, err = s.Wallet(ctx, caller); err != nil {
		return PurchaseResult{}, err
	}
	if res.Subscription, err = s.Subscription(ctx, caller); err != nil {
		return PurchaseResult{}, err
	}
	return res, nil
}

// verifyError maps a store failure. Missing credentials and outages are
// 503 (the purchase may be fine; ask again later), never a grant and never
// "invalid".
func (s *Service) verifyError(platform store.Platform, err error) error {
	switch {
	case errors.Is(err, store.ErrNotConfigured):
		s.logger.Error("billing: store verification is not configured; refusing the purchase (fail closed)", "platform", platform)
		return fmt.Errorf("billing: purchases cannot be verified right now: %w", apperror.ErrUnavailable)
	case errors.Is(err, store.ErrUnavailable):
		s.logger.Warn("billing: store unavailable", "platform", platform, "error", err)
		return fmt.Errorf("billing: purchases cannot be verified right now: %w", apperror.ErrUnavailable)
	default:
		s.logger.Warn("billing: store rejected a purchase", "platform", platform, "error", err)
		return fmt.Errorf("billing: this purchase could not be verified: %w", apperror.ErrInvalidInput)
	}
}

// checkTransaction holds the store's answer to what the app claimed (plan
// 29 §5, API10): the product, the app, the environment, the account, and
// that the purchase is paid and live.
func (s *Service) checkTransaction(ctx context.Context, caller Caller, platform store.Platform, product sqlcgen.BillingStoreProduct, tx store.Transaction) error {
	reject := func(why string) error {
		return fmt.Errorf("billing: this purchase could not be verified (%s): %w", why, apperror.ErrInvalidInput)
	}
	if tx.ProductID != product.ProductID {
		return reject("a different product")
	}
	wantApp := s.cfg.GooglePackageName
	if platform == store.IOS {
		wantApp = s.cfg.AppleBundleID
	}
	if tx.AppID != wantApp {
		return reject("another app")
	}
	if tx.Environment != store.Production && !s.sandboxAllowed(ctx, caller.UserID) {
		return reject("a sandbox purchase")
	}
	if tx.AccountToken != AccountToken(caller.UserID) {
		return fmt.Errorf("billing: this purchase belongs to another account: %w", apperror.ErrForbidden)
	}
	if tx.Revoked {
		return reject("refunded or revoked")
	}
	if tx.Pending {
		return fmt.Errorf("billing: this purchase is still pending with the store: %w", apperror.ErrConflict)
	}
	if store.Kind(product.Kind) == store.Subscription && (tx.ExpiresAt == nil || !tx.ExpiresAt.After(s.now())) {
		return reject("an expired subscription")
	}
	return nil
}

// sandboxAllowed: anywhere off Cloud Run, and in production only for the
// test accounts on billing.plans.visible's allowlist (App Review uses the
// sandbox, plan 29 §6). The allowlist, not the flag: turning plans on for
// everyone must not let everyone pay with sandbox money.
func (s *Service) sandboxAllowed(ctx context.Context, userID string) bool {
	if !s.cfg.Production {
		return true
	}
	if s.flags == nil {
		return false
	}
	ok, err := s.flags.Allowlisted(ctx, flags.BillingPlansVisible, flags.Subject{UserID: userID})
	if err != nil {
		s.logger.Warn("billing: flags unreadable, refusing a sandbox purchase", "error", err)
		return false
	}
	return ok
}

// recordPurchase inserts the store_purchases row, or returns the existing
// one for a repeat. A repeat on a different account is refused.
func recordPurchase(ctx context.Context, q *sqlcgen.Queries, uid uuid.UUID, product sqlcgen.BillingStoreProduct,
	tx store.Transaction, finishToken string) (row sqlcgen.BillingStorePurchase, repeat bool, err error) {
	raw := tx.Raw
	if len(raw) == 0 {
		raw = json.RawMessage(`{}`)
	}
	row, err = q.InsertStorePurchase(ctx, sqlcgen.InsertStorePurchaseParams{
		UserID: uid, Platform: string(tx.Platform), TransactionID: tx.TransactionID,
		OriginalTransactionID: tx.OriginalTransactionID, TokenHash: nullText(tx.TokenHash),
		ProductID: product.ProductID, Kind: product.Kind, AppAccountToken: uuid.MustParse(tx.AccountToken),
		Environment: string(tx.Environment), Raw: raw, PendingFinishToken: nullText(finishToken),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		row, err = q.GetStorePurchase(ctx, sqlcgen.GetStorePurchaseParams{Platform: string(tx.Platform), TransactionID: tx.TransactionID})
		if err != nil {
			return row, false, fmt.Errorf("billing: read repeated purchase: %w", err)
		}
		if row.UserID != uid {
			return row, false, fmt.Errorf("billing: this purchase belongs to another account: %w", apperror.ErrForbidden)
		}
		return row, true, nil
	}
	if err != nil {
		return row, false, fmt.Errorf("billing: record purchase: %w", err)
	}
	// Plan 29D: purchase.verified, for analytics, in the same transaction.
	payload, err := json.Marshal(map[string]string{
		"user_id": uid.String(), "platform": string(tx.Platform), "kind": product.Kind, "product_id": product.ProductID,
	})
	if err != nil {
		return row, false, err
	}
	if err := q.InsertBillingOutbox(ctx, sqlcgen.InsertBillingOutboxParams{Topic: TopicPurchaseVerified, Payload: payload}); err != nil {
		return row, false, fmt.Errorf("billing: queue purchase.verified: %w", err)
	}
	if finishToken != "" {
		if err := queueFinish(ctx, q, row.ID); err != nil {
			return row, false, err
		}
	}
	return row, false, nil
}

// grantPack credits a pack: one transaction inserts the purchase, creates a
// purchase lot that never expires (App Review 3.1.1), writes the ledger
// entry, and queues credits.changed and the Google finish.
func (s *Service) grantPack(ctx context.Context, uid uuid.UUID, product sqlcgen.BillingStoreProduct,
	tx store.Transaction, finishToken string) (uuid.UUID, int64, bool, error) {
	var (
		id      uuid.UUID
		granted int64
		repeat  bool
	)
	err := s.ledger.Do(ctx, uid.String(), func(t *wallet.Tx) error {
		row, rep, err := recordPurchase(ctx, t.Queries(), uid, product, tx, finishToken)
		if err != nil {
			return err
		}
		id, repeat = row.ID, rep
		if rep {
			granted = row.Credits.Int64
			return nil
		}
		granted = product.Credits.Int64 + product.Bonus
		lot, err := t.Grant(wallet.GrantInput{
			Kind: wallet.KindPurchase, Amount: granted, SourceRef: row.ID.String(),
			Key: "purchase:" + row.ID.String(), RefType: "store_purchase", RefID: row.ID.String(),
		})
		if err != nil {
			return err
		}
		return t.Queries().SetStorePurchaseGrant(ctx, sqlcgen.SetStorePurchaseGrantParams{
			ID: row.ID, Credits: pgtype.Int8{Int64: granted, Valid: true}, LotID: pgtype.UUID{Bytes: lot, Valid: true},
		})
	})
	return id, granted, repeat, err
}

// activateSubscription records the purchase and puts the plan in force.
// A repeat still refreshes the period (a renewal re-verified), and never
// moves it backwards.
func (s *Service) activateSubscription(ctx context.Context, caller Caller, product sqlcgen.BillingStoreProduct,
	tx store.Transaction, finishToken string) (uuid.UUID, bool, error) {
	uid, _ := parseUser(caller.UserID)
	end := *tx.ExpiresAt
	start := periodStart(end, product.Period.String, tx.PurchasedAt, s.now())
	var (
		id     uuid.UUID
		repeat bool
	)
	err := s.ledger.Do(ctx, caller.UserID, func(t *wallet.Tx) error {
		q := t.Queries()
		// The first account to verify a store subscription owns it.
		if owner, err := q.FindStorePurchaseByOriginal(ctx, sqlcgen.FindStorePurchaseByOriginalParams{
			Platform: string(tx.Platform), OriginalTransactionID: tx.OriginalTransactionID,
		}); err == nil && owner.UserID != uid {
			return fmt.Errorf("billing: this subscription belongs to another account: %w", apperror.ErrForbidden)
		} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("billing: read subscription owner: %w", err)
		}
		row, rep, err := recordPurchase(ctx, q, uid, product, tx, finishToken)
		if err != nil {
			return err
		}
		id, repeat = row.ID, rep
		cur, found, err := lockSubscription(ctx, q, uid)
		if err != nil {
			return err
		}
		if found && cur.OriginalTransactionID.String == tx.OriginalTransactionID && cur.CurrentPeriodEnd.Time.After(end) {
			end, start = cur.CurrentPeriodEnd.Time, cur.CurrentPeriodStart.Time
		}
		next := subscriptionRow{
			PlanCode: product.PlanCode.String, Status: statusActive, Platform: string(tx.Platform),
			OriginalTransactionID: tx.OriginalTransactionID, ProductID: product.ProductID,
			PeriodStart: start, PeriodEnd: end, AutoRenew: tx.AutoRenew,
		}
		return s.writeSubscription(ctx, q, uid, cur, found, next, t.Now())
	})
	if err == nil && !repeat && !s.plansVisibleTo(ctx, caller.UserID) {
		// Plan 29 §3.7: a paid purchase is never refused. Granted, and
		// flagged so someone looks at how it was bought.
		s.logger.Warn("billing: granted a subscription to an account the plans are hidden from",
			"user_id", caller.UserID, "product_id", product.ProductID)
	}
	return id, repeat, err
}

// periodStart is the start of the period ending at end: the store's
// purchase time when it falls inside that period (Apple's renewal
// transaction), else one billing period before the end.
func periodStart(end time.Time, period string, purchased, now time.Time) time.Time {
	start := end.AddDate(0, -1, 0)
	if period == "year" {
		start = end.AddDate(-1, 0, 0)
	}
	if purchased.After(start) && purchased.Before(end) {
		start = purchased
	}
	if start.After(now) {
		start = now
	}
	return start
}

func (s *Service) plansVisibleTo(ctx context.Context, userID string) bool {
	if s.flags == nil {
		return false
	}
	on, err := s.flags.Enabled(ctx, flags.BillingPlansVisible, flags.Subject{UserID: userID})
	if err != nil {
		s.logger.Warn("billing: flags unreadable, plans treated as hidden", "error", err)
		return false
	}
	return on
}

// queueFinish queues the Google consume or acknowledge, retried by the
// billing outbox until the store accepts it.
func queueFinish(ctx context.Context, q *sqlcgen.Queries, purchaseID uuid.UUID) error {
	payload, err := json.Marshal(map[string]string{"purchase_id": purchaseID.String()})
	if err != nil {
		return err
	}
	if err := q.InsertBillingOutbox(ctx, sqlcgen.InsertBillingOutboxParams{Topic: TopicStoreFinish, Payload: payload}); err != nil {
		return fmt.Errorf("billing: queue store finish: %w", err)
	}
	return nil
}

// finishPurchase consumes or acknowledges a Google purchase once. Done,
// refunded, or nothing to finish is a no-op.
func (s *Service) finishPurchase(ctx context.Context, purchaseID uuid.UUID) error {
	p, err := s.q.GetStorePurchaseByID(ctx, purchaseID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("billing: read purchase to finish: %w", err)
	}
	if p.FinishedAt.Valid || !p.PendingFinishToken.Valid || p.RefundedAt.Valid {
		return nil
	}
	if err := s.store.Finish(ctx, store.Platform(p.Platform), store.Kind(p.Kind), p.ProductID, p.PendingFinishToken.String); err != nil {
		return fmt.Errorf("billing: finish purchase %s: %w", purchaseID, err)
	}
	return s.q.MarkStorePurchaseFinished(ctx, purchaseID)
}

// HandleOutboxEvent is billing's own consumer of billing_outbox: the
// store.finish retries. Other topics are for other consumers.
func (s *Service) HandleOutboxEvent(ctx context.Context, e OutboxEvent) error {
	if e.Topic != TopicStoreFinish {
		return nil
	}
	var p struct {
		PurchaseID string `json:"purchase_id"`
	}
	if err := json.Unmarshal(e.Payload, &p); err != nil {
		return fmt.Errorf("billing: decode store.finish: %w", err)
	}
	id, err := uuid.Parse(p.PurchaseID)
	if err != nil {
		return fmt.Errorf("billing: store.finish purchase id: %w", err)
	}
	return s.finishPurchase(ctx, id)
}

func nullText(s string) pgtype.Text { return pgtype.Text{String: s, Valid: s != ""} }
