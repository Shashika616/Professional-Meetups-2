package billing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/billing/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple"
	"professional-meetups-monolith/backend/internal/modules/billing/store/google"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// The store webhooks (plan 29 §3.7, ADR-031 §3), ported from the source's
// service/webhooks.go and extended with consumable refunds and Google's
// voided purchases.
//
// # VERIFY FIRST, THEN ONCE
//
// Nothing in a notification is read before its signature (Apple) or push
// token (Google) verifies; a failure is 401 and writes nothing. Then each
// notification is applied at most once: its id goes into
// processed_store_notifications in the same transaction as the change.
// A notification for a purchase this server never verified is recorded and
// acknowledged, so the store stops retrying it.

// maxNotification bounds a webhook body's payload.
const maxNotification = 256 << 10

// Outcomes recorded per notification.
const (
	outcomeApplied  = "applied"
	outcomeRefunded = "refunded"
	outcomeIgnored  = "ignored"
	outcomeUnknown  = "unknown_purchase"
	outcomeOtherApp = "other_app"
	outcomeTest     = "test"
	// outcomeStale is a notification overtaken by a later one: stores do
	// not deliver in order.
	outcomeStale = "stale"
)

// notice is one notification's identity, for the idempotency record.
type notice struct {
	platform store.Platform
	id       string
	typ      string
	subtype  string
}

// subscriptionChange is what a notification does to a subscription. Nil
// fields leave the stored value alone.
type subscriptionChange struct {
	status      string
	periodStart *time.Time
	periodEnd   *time.Time
	graceEnd    *time.Time
	autoRenew   *bool
	// asOf is the end of the period the notification is about. A change
	// that ends access is stale when a later period is already stored.
	asOf *time.Time
}

// HandleAppleNotification processes an App Store Server Notification V2.
// It returns false for a notification handled before.
func (s *Service) HandleAppleNotification(ctx context.Context, signedPayload string) (bool, error) {
	if signedPayload == "" || len(signedPayload) > maxNotification {
		return false, fmt.Errorf("billing: no notification: %w", apperror.ErrInvalidInput)
	}
	if s.appleRoots == nil {
		return false, fmt.Errorf("billing: apple notifications are not configured: %w", apperror.ErrUnavailable)
	}
	n, err := apple.ParseNotification(signedPayload, s.appleRoots)
	if errors.Is(err, apple.ErrBadSignature) {
		s.logger.Warn("billing: apple notification failed verification", "error", err)
		return false, fmt.Errorf("billing: notification signature does not verify: %w", apperror.ErrUnauthorized)
	}
	if err != nil {
		return false, fmt.Errorf("billing: unreadable apple notification: %w", apperror.ErrInvalidInput)
	}
	nt := notice{platform: store.IOS, id: n.ID, typ: n.Type, subtype: n.Subtype}
	switch {
	case n.Type == "TEST":
		return s.recordOnly(ctx, nt, outcomeTest)
	case n.BundleID != "" && n.BundleID != s.cfg.AppleBundleID:
		return s.recordOnly(ctx, nt, outcomeOtherApp)
	case n.Transaction == nil:
		return s.recordOnly(ctx, nt, outcomeIgnored)
	}
	tx := *n.Transaction

	if n.Type == "REFUND" || n.Type == "REVOKE" {
		if p, err := s.q.GetStorePurchase(ctx, sqlcgen.GetStorePurchaseParams{
			Platform: string(store.IOS), TransactionID: tx.TransactionID,
		}); err == nil && p.Kind == string(store.Consumable) {
			return s.refundPack(ctx, nt, p)
		}
	}
	change, ok := appleChange(n)
	if !ok {
		return s.recordOnly(ctx, nt, outcomeIgnored)
	}
	return s.applySubscriptionChange(ctx, nt, tx.OriginalTransactionID, change)
}

// appleChange maps (notificationType, subtype) to a subscription change.
// Apple's V2 set is larger; types that do not change entitlement are
// acknowledged and ignored (the source's appleTransition, plus renewal
// status and grace ends).
func appleChange(n apple.Notification) (subscriptionChange, bool) {
	tx := n.Transaction
	switch n.Type {
	case "SUBSCRIBED", "DID_RENEW":
		c := subscriptionChange{status: statusActive, periodEnd: tx.ExpiresAt, autoRenew: n.AutoRenew}
		if !tx.PurchasedAt.IsZero() {
			p := tx.PurchasedAt
			c.periodStart = &p
		}
		return c, tx.ExpiresAt != nil
	case "DID_CHANGE_RENEWAL_STATUS":
		on := n.Subtype == "AUTO_RENEW_ENABLED"
		return subscriptionChange{autoRenew: &on}, true
	case "DID_FAIL_TO_RENEW":
		if n.Subtype == "GRACE_PERIOD" {
			return subscriptionChange{status: statusGracePeriod, graceEnd: n.GracePeriodEnd, asOf: tx.ExpiresAt}, true
		}
		return subscriptionChange{status: statusPastDue, asOf: tx.ExpiresAt}, true
	case "GRACE_PERIOD_EXPIRED", "EXPIRED":
		return subscriptionChange{status: statusExpired, asOf: tx.ExpiresAt}, true
	case "REFUND", "REVOKE":
		// A refund of an earlier period's transaction does not end a
		// period renewed since.
		return subscriptionChange{status: statusRevoked, asOf: tx.ExpiresAt}, true
	default:
		return subscriptionChange{}, false
	}
}

// HandleGoogleNotification processes one RTDN Pub/Sub push.
func (s *Service) HandleGoogleNotification(ctx context.Context, authorization, messageID, dataBase64 string) (bool, error) {
	if s.googlePush == nil {
		s.logger.Error("billing: google notifications are not configured (GOOGLE_PUBSUB_PUSH_AUDIENCE); refusing")
		return false, fmt.Errorf("billing: google notifications are not configured: %w", apperror.ErrUnavailable)
	}
	if _, err := s.googlePush.Verify(ctx, authorization); err != nil {
		s.logger.Warn("billing: google push failed verification", "error", err)
		return false, fmt.Errorf("billing: push authorization does not verify: %w", apperror.ErrUnauthorized)
	}
	if len(dataBase64) > maxNotification {
		return false, fmt.Errorf("billing: notification too large: %w", apperror.ErrInvalidInput)
	}
	n, err := google.ParseNotification(messageID, dataBase64)
	if err != nil {
		return false, fmt.Errorf("billing: unreadable google notification: %w", apperror.ErrInvalidInput)
	}
	nt := notice{platform: store.Android, id: n.ID}
	switch {
	case n.Test:
		nt.typ = "test"
		return s.recordOnly(ctx, nt, outcomeTest)
	case n.PackageName != s.cfg.GooglePackageName:
		nt.typ = "other_app"
		return s.recordOnly(ctx, nt, outcomeOtherApp)
	case n.Voided != nil:
		nt.typ = fmt.Sprintf("voided:%d", n.Voided.ProductType)
		return s.googleVoided(ctx, nt, *n.Voided)
	case n.Subscription != nil:
		nt.typ = fmt.Sprintf("subscription:%d", n.Subscription.Type)
		return s.googleSubscription(ctx, nt, *n.Subscription)
	default:
		nt.typ = "other"
		return s.recordOnly(ctx, nt, outcomeIgnored)
	}
}

func (s *Service) googleVoided(ctx context.Context, nt notice, v google.VoidedEvent) (bool, error) {
	p, err := s.q.FindStorePurchaseByTokenHash(ctx, sqlcgen.FindStorePurchaseByTokenHashParams{
		Platform: string(store.Android), TokenHash: pgtype.Text{String: v.TokenHash, Valid: true},
	})
	if errors.Is(err, pgx.ErrNoRows) && v.OrderID != "" {
		p, err = s.q.GetStorePurchase(ctx, sqlcgen.GetStorePurchaseParams{Platform: string(store.Android), TransactionID: v.OrderID})
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return s.recordOnly(ctx, nt, outcomeUnknown)
	}
	if err != nil {
		return false, fmt.Errorf("billing: find voided purchase: %w", err)
	}
	if p.Kind == string(store.Consumable) {
		return s.refundPack(ctx, nt, p)
	}
	return s.applySubscriptionChange(ctx, nt, p.OriginalTransactionID, subscriptionChange{status: statusRevoked})
}

// googleSubscription maps an RTDN subscription type. RTDN carries no state
// of its own, so the types that extend access re-read the subscription from
// the Play Developer API for the new period end.
func (s *Service) googleSubscription(ctx context.Context, nt notice, e google.SubscriptionEvent) (bool, error) {
	if done, err := s.seen(ctx, nt); err != nil || done {
		return false, err
	}
	var change subscriptionChange
	switch e.Type {
	case google.SubRecovered, google.SubRenewed, google.SubPurchased, google.SubRestarted, google.SubInGracePeriod:
		tx, err := s.store.Verify(ctx, store.Request{Platform: store.Android, Kind: store.Subscription, ProductID: e.ProductID, Token: e.PurchaseToken})
		if errors.Is(err, store.ErrUnavailable) || errors.Is(err, store.ErrNotConfigured) {
			// Not recorded: Pub/Sub redelivers, and the next try may
			// reach Google.
			return false, fmt.Errorf("billing: refresh google subscription: %w: %w", apperror.ErrUnavailable, err)
		}
		if err != nil || tx.ExpiresAt == nil {
			return s.recordOnly(ctx, nt, outcomeIgnored)
		}
		change = subscriptionChange{status: statusActive, periodEnd: tx.ExpiresAt, autoRenew: &tx.AutoRenew}
		if e.Type == google.SubInGracePeriod {
			// Google moves the expiry to the end of the grace period.
			change.status, change.graceEnd = statusGracePeriod, tx.ExpiresAt
		}
	case google.SubCanceled:
		off := false
		change = subscriptionChange{autoRenew: &off}
	case google.SubOnHold, google.SubPaused, google.SubExpired:
		// RTDN can arrive after a later renewal. Ask Google: if the
		// subscription still runs, this notification is stale.
		tx, err := s.store.Verify(ctx, store.Request{Platform: store.Android, Kind: store.Subscription, ProductID: e.ProductID, Token: e.PurchaseToken})
		if errors.Is(err, store.ErrUnavailable) || errors.Is(err, store.ErrNotConfigured) {
			return false, fmt.Errorf("billing: refresh google subscription: %w: %w", apperror.ErrUnavailable, err)
		}
		if err == nil && tx.ExpiresAt != nil && tx.ExpiresAt.After(s.now()) && !tx.Revoked {
			return s.recordOnly(ctx, nt, outcomeStale)
		}
		change = subscriptionChange{status: statusPastDue}
		if e.Type == google.SubExpired {
			change.status = statusExpired
		}
	case google.SubRevoked:
		change = subscriptionChange{status: statusRevoked}
	default:
		return s.recordOnly(ctx, nt, outcomeIgnored)
	}
	return s.applySubscriptionChange(ctx, nt, e.TokenHash, change)
}

// applySubscriptionChange finds the account that owns the store
// subscription and applies change under its wallet lock, once.
func (s *Service) applySubscriptionChange(ctx context.Context, nt notice, originalTransactionID string, change subscriptionChange) (bool, error) {
	owner, err := s.q.FindStorePurchaseByOriginal(ctx, sqlcgen.FindStorePurchaseByOriginalParams{
		Platform: string(nt.platform), OriginalTransactionID: originalTransactionID,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return s.recordOnly(ctx, nt, outcomeUnknown)
	}
	if err != nil {
		return false, fmt.Errorf("billing: find subscription owner: %w", err)
	}
	fresh := false
	err = s.ledger.Do(ctx, owner.UserID.String(), func(t *wallet.Tx) error {
		q := t.Queries()
		cur, found, err := lockSubscription(ctx, q, owner.UserID)
		if err != nil {
			return err
		}
		outcome := outcomeApplied
		// The account may since have moved to another store subscription
		// or an operator's plan; this notification is about the old one.
		switch {
		case !found || cur.OriginalTransactionID.String != originalTransactionID:
			outcome = outcomeIgnored
		case change.asOf != nil && change.status != statusActive && change.asOf.Before(cur.CurrentPeriodEnd.Time.Add(-time.Second)):
			outcome = outcomeStale
		}
		if fresh, err = record(ctx, q, nt, outcome); err != nil || !fresh || outcome != outcomeApplied {
			return err
		}
		next := fromStored(cur)
		if change.status != "" {
			next.Status = change.status
		}
		if change.periodEnd != nil && change.periodEnd.After(next.PeriodEnd) {
			next.PeriodEnd = *change.periodEnd
			next.PeriodStart = periodStart(next.PeriodEnd, productPeriod(ctx, q, next.ProductID), timeOr(change.periodStart), t.Now())
		}
		if change.status != "" && change.status != statusGracePeriod {
			next.GracePeriodEnd = nil
		}
		if change.graceEnd != nil {
			g := *change.graceEnd
			next.GracePeriodEnd = &g
		}
		if change.autoRenew != nil {
			next.AutoRenew = *change.autoRenew
		}
		return s.writeSubscription(ctx, q, owner.UserID, cur, found, next, t.Now())
	})
	return fresh, err
}

// refundPack applies a store refund of a credit pack (plan 3.6): the lot's
// remaining credits are removed and what was spent becomes debt.
func (s *Service) refundPack(ctx context.Context, nt notice, p sqlcgen.BillingStorePurchase) (bool, error) {
	fresh := false
	err := s.ledger.Do(ctx, p.UserID.String(), func(t *wallet.Tx) error {
		q := t.Queries()
		var err error
		if fresh, err = record(ctx, q, nt, outcomeRefunded); err != nil || !fresh {
			return err
		}
		locked, err := q.LockStorePurchase(ctx, p.ID)
		if err != nil {
			return fmt.Errorf("billing: lock refunded purchase: %w", err)
		}
		if locked.RefundedAt.Valid || !locked.LotID.Valid {
			return nil
		}
		removed, debt, err := t.RevokeLot(uuid.UUID(locked.LotID.Bytes), "store_refund:"+p.ID.String(), "store_purchase", p.ID.String())
		if err != nil {
			return err
		}
		s.logger.Info("billing: store refund applied", "purchase_id", p.ID, "removed", removed, "debt", debt)
		_, err = q.MarkStorePurchaseRefunded(ctx, p.ID)
		return err
	})
	return fresh, err
}

// record inserts the idempotency row; false means it was there already.
func record(ctx context.Context, q *sqlcgen.Queries, nt notice, outcome string) (bool, error) {
	n, err := q.InsertProcessedNotification(ctx, sqlcgen.InsertProcessedNotificationParams{
		Platform: string(nt.platform), NotificationID: nt.id, NotificationType: nt.typ,
		Subtype: nullText(nt.subtype), Outcome: outcome,
	})
	if err != nil {
		return false, fmt.Errorf("billing: record notification: %w", err)
	}
	return n == 1, nil
}

// recordOnly acknowledges a notification that changes nothing.
func (s *Service) recordOnly(ctx context.Context, nt notice, outcome string) (bool, error) {
	fresh, err := record(ctx, s.q, nt, outcome)
	if err == nil && outcome == outcomeUnknown {
		s.logger.Info("billing: store notification for a purchase this server never verified",
			"platform", nt.platform, "type", nt.typ)
	}
	return fresh, err
}

// seen reports whether a notification was handled before, to skip the
// store call a redelivery would otherwise repeat.
func (s *Service) seen(ctx context.Context, nt notice) (bool, error) {
	n, err := s.q.CountProcessedNotifications(ctx, sqlcgen.CountProcessedNotificationsParams{
		Platform: string(nt.platform), NotificationID: nt.id,
	})
	if err != nil {
		return false, fmt.Errorf("billing: read notification record: %w", err)
	}
	return n > 0, nil
}

// productPeriod is a subscription product's billing period; a product no
// longer in the catalog counts as monthly.
func productPeriod(ctx context.Context, q *sqlcgen.Queries, productID string) string {
	if p, err := q.GetStoreProduct(ctx, productID); err == nil && p.Period.Valid {
		return p.Period.String
	}
	return "month"
}

func timeOr(t *time.Time) time.Time {
	if t == nil {
		return time.Time{}
	}
	return *t
}
