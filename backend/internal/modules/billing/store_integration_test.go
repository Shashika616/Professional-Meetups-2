package billing_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/billing"
	"professional-meetups-monolith/backend/internal/modules/billing/store"
	"professional-meetups-monolith/backend/internal/modules/billing/store/apple/appletest"
	"professional-meetups-monolith/backend/internal/modules/billing/store/fake"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

// Plan 29B: store purchases, subscriptions, webhooks and the catalog,
// against real Postgres. The store itself is the fake one (it believes the
// token); what is under test is everything billing does with the answer.

// allowlistedUser is a seeded test account on billing.plans.visible's
// allowlist (migration 0025).
const allowlistedUser = "00000000-0000-4000-8000-000000000040"

// pack makes a production credit-pack token for c.
func (h *harness) pack(c billing.Caller, txID, product string) string {
	return fake.Encode(fake.Token{
		TransactionID: txID, ProductID: product, AppID: h.cfg.GooglePackageName,
		Environment: store.Production, AccountToken: billing.AccountToken(c.UserID),
	})
}

func (h *harness) sub(c billing.Caller, txID, original, product string, expires time.Time) string {
	return fake.Encode(fake.Token{
		TransactionID: txID, OriginalTransactionID: original, ProductID: product, AppID: h.cfg.AppleBundleID,
		Environment: store.Production, AccountToken: billing.AccountToken(c.UserID), ExpiresAt: &expires,
	})
}

func (h *harness) verify(c billing.Caller, platform, product, token string) (billing.PurchaseResult, error) {
	return h.svc.VerifyPurchase(context.Background(), c, billing.PurchaseRequest{Platform: platform, ProductID: product, Token: token})
}

func (h *harness) purchases(t *testing.T, c billing.Caller) int {
	return h.count(t, `SELECT count(*) FROM billing.store_purchases WHERE user_id = $1`, c.UserID)
}

// The same transaction verified twice, then ten times at once: one
// purchase, one lot, one ledger entry, and the repeats answer with the
// original grant.
func TestVerifyGrantsAPackExactlyOnce(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	token := h.pack(c, "GPA.1", "credits_120")

	first, err := h.verify(c, "android", "credits_120", token)
	if err != nil {
		t.Fatal(err)
	}
	if first.CreditsGranted != 120 || first.AlreadyProcessed || first.Wallet.Balance != 120 {
		t.Fatalf("first verify = %+v; want 120 credits (100 + 20 bonus)", first)
	}
	again, err := h.verify(c, "android", "credits_120", token)
	if err != nil || !again.AlreadyProcessed || again.CreditsGranted != 120 || again.Wallet.Balance != 120 {
		t.Fatalf("repeat = %+v, %v; want the original result and nothing new", again, err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 10)
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := h.verify(c, "android", "credits_120", token); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent verify: %v", err)
	}

	if n := h.purchases(t, c); n != 1 {
		t.Fatalf("%d store purchases, want 1", n)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.credit_lots WHERE user_id = $1 AND kind = 'purchase'`, c.UserID); n != 1 {
		t.Fatalf("%d purchase lots, want 1", n)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.ledger_entries WHERE user_id = $1 AND ref_type = 'store_purchase'`, c.UserID); n != 1 {
		t.Fatalf("%d ledger entries, want 1", n)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.credit_lots WHERE user_id = $1 AND expires_at IS NOT NULL`, c.UserID); n != 0 {
		t.Fatal("a purchased lot expires (App Review 3.1.1)")
	}
	if v := h.wallet(t, c); v.Balance != 120 {
		t.Fatalf("balance = %d, want 120", v.Balance)
	}
	// Google was told to consume it, and the token is gone.
	if n := h.count(t, `SELECT count(*) FROM billing.store_purchases
		WHERE user_id = $1 AND finished_at IS NOT NULL AND pending_finish_token IS NULL`, c.UserID); n != 1 {
		t.Fatal("the Android purchase was not finished, or its token was kept")
	}
	h.assertReconciled(t)
}

// One person's receipt replayed on another account: refused, nothing
// written for the second account.
func TestAnotherAccountsPurchaseIsRejected(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.newUser(), h.newUser()
	aliceToken := h.pack(alice, "GPA.7", "credits_50")
	if _, err := h.verify(alice, "android", "credits_50", aliceToken); err != nil {
		t.Fatal(err)
	}
	_, err := h.verify(bob, "android", "credits_50", aliceToken)
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Fatalf("bob verifying alice's purchase: %v, want forbidden", err)
	}
	// A fresh transaction bound to alice, sent first by bob.
	_, err = h.verify(bob, "android", "credits_50", h.pack(alice, "GPA.8", "credits_50"))
	if !errors.Is(err, apperror.ErrForbidden) {
		t.Fatalf("bob verifying a purchase bound to alice: %v, want forbidden", err)
	}
	if n := h.purchases(t, bob); n != 0 {
		t.Fatalf("%d purchases recorded for bob", n)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.wallets WHERE user_id = $1`, bob.UserID); n != 0 {
		t.Fatal("a wallet was created for bob")
	}
	if n := h.count(t, `SELECT count(*) FROM billing.store_purchases WHERE transaction_id = 'GPA.8'`); n != 0 {
		t.Fatal("the refused transaction was recorded")
	}
}

func TestVerifyRejectsWhatTheStoreSaysOtherwise(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	soon := h.clock.Now().Add(30 * 24 * time.Hour)
	past := h.clock.Now().Add(-time.Hour)
	base := fake.Token{ProductID: "credits_50", AppID: h.cfg.GooglePackageName, Environment: store.Production,
		AccountToken: billing.AccountToken(c.UserID)}
	with := func(f func(*fake.Token)) string {
		tok := base
		tok.TransactionID = uuid.NewString()
		f(&tok)
		return fake.Encode(tok)
	}
	cases := []struct {
		name, platform, product, token string
		want                           error
	}{
		{"wrong package", "android", "credits_50", with(func(t *fake.Token) { t.AppID = "com.other.app" }), apperror.ErrInvalidInput},
		{"wrong bundle", "ios", "credits_50", with(func(t *fake.Token) { t.AppID = h.cfg.GooglePackageName }), apperror.ErrInvalidInput},
		{"sandbox in production", "android", "credits_50", with(func(t *fake.Token) { t.Environment = store.Sandbox }), apperror.ErrInvalidInput},
		{"a different product", "android", "credits_300", with(func(*fake.Token) {}), apperror.ErrInvalidInput},
		{"unknown product", "android", "credits_9999", with(func(t *fake.Token) { t.ProductID = "credits_9999" }), apperror.ErrInvalidInput},
		{"revoked", "android", "credits_50", with(func(t *fake.Token) { t.Revoked = true }), apperror.ErrInvalidInput},
		{"pending", "android", "credits_50", with(func(t *fake.Token) { t.Pending = true }), apperror.ErrConflict},
		{"no account token", "android", "credits_50", with(func(t *fake.Token) { t.AccountToken = "" }), apperror.ErrForbidden},
		{"expired subscription", "ios", "premium_monthly", with(func(t *fake.Token) {
			t.ProductID, t.AppID, t.ExpiresAt = "premium_monthly", h.cfg.AppleBundleID, &past
		}), apperror.ErrInvalidInput},
		{"revoked subscription", "ios", "premium_monthly", with(func(t *fake.Token) {
			t.ProductID, t.AppID, t.ExpiresAt, t.Revoked = "premium_monthly", h.cfg.AppleBundleID, &soon, true
		}), apperror.ErrInvalidInput},
		{"subscription with no expiry", "ios", "premium_monthly", with(func(t *fake.Token) {
			t.ProductID, t.AppID = "premium_monthly", h.cfg.AppleBundleID
		}), apperror.ErrInvalidInput},
		{"bad platform", "web", "credits_50", with(func(*fake.Token) {}), apperror.ErrInvalidInput},
		{"not a store token", "android", "credits_50", "garbage", apperror.ErrInvalidInput},
	}
	for _, tc := range cases {
		if _, err := h.verify(c, tc.platform, tc.product, tc.token); !errors.Is(err, tc.want) {
			t.Errorf("%s: err = %v, want %v", tc.name, err, tc.want)
		}
	}
	if n := h.purchases(t, c); n != 0 {
		t.Fatalf("%d purchases recorded from rejected verifies", n)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.subscriptions WHERE user_id = $1`, c.UserID); n != 0 {
		t.Fatal("a rejected subscription was activated")
	}
}

// Sandbox money is for the test accounts on the plans allowlist, and for
// everyone off Cloud Run, never for everyone because the flag turned on.
func TestSandboxPurchasesOnlyForTheAllowlist(t *testing.T) {
	h := newHarness(t)
	sandbox := func(c billing.Caller) string {
		return fake.Encode(fake.Token{TransactionID: uuid.NewString(), ProductID: "credits_50", AppID: h.cfg.GooglePackageName,
			Environment: store.Sandbox, AccountToken: billing.AccountToken(c.UserID)})
	}
	tester := billing.Caller{UserID: allowlistedUser, TrustLevel: 3}
	if _, err := h.verify(tester, "android", "credits_50", sandbox(tester)); err != nil {
		t.Fatalf("allowlisted tester's sandbox purchase: %v", err)
	}
	setPlansFlag(t, h, true)
	someone := h.newUser()
	if _, err := h.verify(someone, "android", "credits_50", sandbox(someone)); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("an ordinary user's sandbox purchase with plans on for all: %v, want refused", err)
	}
	h.cfg.Production = false
	h.build()
	if _, err := h.verify(someone, "android", "credits_50", sandbox(someone)); err != nil {
		t.Fatalf("a sandbox purchase off Cloud Run: %v", err)
	}
}

// Missing credentials are 503 and never a grant.
func TestUnconfiguredStoreFailsClosed(t *testing.T) {
	h := newHarness(t)
	h.store.set(store.ByPlatform{})
	c := h.newUser()
	for _, p := range []string{"ios", "android"} {
		if _, err := h.verify(c, p, "credits_50", h.pack(c, uuid.NewString(), "credits_50")); !errors.Is(err, apperror.ErrUnavailable) {
			t.Fatalf("%s with no credentials: %v, want unavailable (503)", p, err)
		}
	}
	h.store.set(failingStore{store.ErrUnavailable})
	if _, err := h.verify(c, "ios", "credits_50", "x"); !errors.Is(err, apperror.ErrUnavailable) {
		t.Fatalf("store down: %v, want unavailable", err)
	}
	if n := h.purchases(t, c); n != 0 {
		t.Fatal("a purchase was recorded without verification")
	}
	if n := h.count(t, `SELECT count(*) FROM billing.wallets WHERE user_id = $1`, c.UserID); n != 0 {
		t.Fatal("a wallet was touched")
	}
}

type failingStore struct{ err error }

func (f failingStore) Verify(context.Context, store.Request) (store.Transaction, error) {
	return store.Transaction{}, f.err
}
func (f failingStore) Finish(context.Context, store.Platform, store.Kind, string, string) error {
	return f.err
}

// A Google consume that fails is retried by the outbox until it lands.
func TestGoogleFinishIsRetriedThroughTheOutbox(t *testing.T) {
	h := newHarness(t)
	h.store.set(finishFails{h.fake})
	c := h.newUser()
	if _, err := h.verify(c, "android", "credits_50", h.pack(c, "GPA.9", "credits_50")); err != nil {
		t.Fatalf("a failed finish must not fail the grant: %v", err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.store_purchases WHERE user_id = $1 AND finished_at IS NULL AND pending_finish_token IS NOT NULL`, c.UserID); n != 1 {
		t.Fatal("the unfinished purchase lost its pending token")
	}
	h.store.set(h.fake)
	payload, _ := json.Marshal(map[string]string{"purchase_id": purchaseID(t, h, c)})
	if err := h.svc.HandleOutboxEvent(context.Background(), billing.OutboxEvent{Topic: billing.TopicStoreFinish, Payload: payload}); err != nil {
		t.Fatal(err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.store_purchases WHERE user_id = $1 AND finished_at IS NOT NULL AND pending_finish_token IS NULL`, c.UserID); n != 1 {
		t.Fatal("the outbox retry did not finish the purchase")
	}
	if n := h.count(t, `SELECT count(*) FROM billing.billing_outbox WHERE topic = 'store.finish'`); n != 1 {
		t.Fatalf("%d store.finish rows, want 1", n)
	}
}

type finishFails struct{ *fake.Store }

func (finishFails) Finish(context.Context, store.Platform, store.Kind, string, string) error {
	return store.ErrUnavailable
}

func purchaseID(t *testing.T, h *harness, c billing.Caller) string {
	t.Helper()
	var id string
	if err := h.pool.QueryRow(context.Background(), `SELECT id::text FROM billing.store_purchases WHERE user_id = $1`, c.UserID).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

// A verified subscription puts the plan in force (and queues
// subscription.activated), even for an account the plans are hidden from.
func TestVerifiedSubscriptionActivatesThePlan(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	end := h.clock.Now().Add(30 * 24 * time.Hour)
	res, err := h.verify(c, "ios", "premium_monthly", h.sub(c, "2000001", "2000000", "premium_monthly", end))
	if err != nil {
		t.Fatalf("verify subscription for an account plans are hidden from: %v", err)
	}
	if !res.Subscription.Entitled || res.Subscription.PlanCode != "pro" || res.Subscription.Status != "active" {
		t.Fatalf("subscription = %+v", res.Subscription)
	}
	ent, err := h.svc.Entitlements(context.Background(), c)
	if err != nil || ent.PlanCode != "pro" || ent.Limits.MaxCapacity != 30 || ent.MeetupsIncluded != 10 {
		t.Fatalf("entitlements = %+v, %v", ent, err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.billing_outbox WHERE topic = 'subscription.activated' AND payload->>'user_id' = $1`, c.UserID); n != 1 {
		t.Fatalf("%d subscription.activated events, want 1", n)
	}
	// Re-verifying is a no-op, with no second event.
	if res, err := h.verify(c, "ios", "premium_monthly", h.sub(c, "2000001", "2000000", "premium_monthly", end)); err != nil || !res.AlreadyProcessed {
		t.Fatalf("repeat = %+v, %v", res, err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.billing_outbox WHERE topic = 'subscription.activated'`); n != 1 {
		t.Fatalf("%d activation events after a repeat", n)
	}
	// The same store subscription cannot be claimed by a second account.
	other := h.newUser()
	tok := fake.Encode(fake.Token{TransactionID: "2000002", OriginalTransactionID: "2000000", ProductID: "premium_monthly",
		AppID: h.cfg.AppleBundleID, Environment: store.Production, AccountToken: billing.AccountToken(other.UserID), ExpiresAt: &end})
	if _, err := h.verify(other, "ios", "premium_monthly", tok); !errors.Is(err, apperror.ErrForbidden) {
		t.Fatalf("a second account claiming the subscription: %v, want forbidden", err)
	}
}

// --- webhooks ---

func (h *harness) appleNotification(t *testing.T, chain appletest.Chain, id, typ, subtype string, tx jwt.MapClaims) string {
	t.Helper()
	data := map[string]any{"bundleId": h.cfg.AppleBundleID, "environment": "Production"}
	if tx != nil {
		data["signedTransactionInfo"] = chain.Sign(t, tx)
	}
	return chain.Sign(t, jwt.MapClaims{"notificationType": typ, "subtype": subtype, "notificationUUID": id, "data": data})
}

func TestAppleWebhookVerifiesFirstAndAppliesOnce(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	end := h.clock.Now().Add(30 * 24 * time.Hour)
	if _, err := h.verify(c, "ios", "premium_monthly", h.sub(c, "3000001", "3000000", "premium_monthly", end)); err != nil {
		t.Fatal(err)
	}
	expired := appletest.Transaction("3000001", "3000000", h.cfg.AppleBundleID, "premium_monthly",
		"Auto-Renewable Subscription", billing.AccountToken(c.UserID), "Production", &end)

	// Signed under another root: 401, nothing written.
	forged := h.appleNotification(t, appletest.New(t), "n-forged", "EXPIRED", "", expired)
	if _, err := h.svc.HandleAppleNotification(context.Background(), forged); !errors.Is(err, apperror.ErrUnauthorized) {
		t.Fatalf("forged notification: %v, want unauthorized", err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.processed_store_notifications`); n != 0 {
		t.Fatal("a forged notification was recorded")
	}
	if v, _ := h.svc.Subscription(context.Background(), c); !v.Entitled {
		t.Fatal("a forged notification changed the subscription")
	}

	real := h.appleNotification(t, h.apple, "n-1", "EXPIRED", "VOLUNTARY", expired)
	for i, want := range []bool{true, false} {
		processed, err := h.svc.HandleAppleNotification(context.Background(), real)
		if err != nil || processed != want {
			t.Fatalf("delivery %d: processed=%v, %v; want %v", i+1, processed, err, want)
		}
	}
	v, _ := h.svc.Subscription(context.Background(), c)
	if v.Entitled || v.Status != "expired" {
		t.Fatalf("after EXPIRED: %+v", v)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.billing_outbox WHERE topic = 'subscription.deactivated'`); n != 1 {
		t.Fatalf("%d deactivation events for one notification delivered twice", n)
	}

	// DID_RENEW brings it back with the new period.
	next := end.Add(30 * 24 * time.Hour)
	renewed := appletest.Transaction("3000002", "3000000", h.cfg.AppleBundleID, "premium_monthly",
		"Auto-Renewable Subscription", billing.AccountToken(c.UserID), "Production", &next)
	if _, err := h.svc.HandleAppleNotification(context.Background(), h.appleNotification(t, h.apple, "n-2", "DID_RENEW", "", renewed)); err != nil {
		t.Fatal(err)
	}
	v, _ = h.svc.Subscription(context.Background(), c)
	if !v.Entitled || v.PeriodEnd == nil || !v.PeriodEnd.Equal(next.Truncate(time.Millisecond)) {
		t.Fatalf("after DID_RENEW: %+v, want entitled until %v", v, next)
	}
	// Apple redelivers the old EXPIRED: it was applied once already, so it
	// must not end the renewed subscription.
	if processed, err := h.svc.HandleAppleNotification(context.Background(), real); err != nil || processed {
		t.Fatalf("late redelivery: processed=%v, %v", processed, err)
	}
	if v, _ := h.svc.Subscription(context.Background(), c); !v.Entitled {
		t.Fatal("a redelivered notification was applied a second time and ended the renewed subscription")
	}

	// Notifications arrive out of order. An EXPIRED about the period that
	// ended before the renewal must not end the renewed subscription.
	staleExpired := h.appleNotification(t, h.apple, "n-stale", "EXPIRED", "VOLUNTARY", expired)
	if _, err := h.svc.HandleAppleNotification(context.Background(), staleExpired); err != nil {
		t.Fatal(err)
	}
	if v, _ := h.svc.Subscription(context.Background(), c); !v.Entitled {
		t.Fatal("a late EXPIRED for an earlier period ended the renewed subscription")
	}

	// Unknown purchases and other apps are acknowledged, not applied.
	stranger := appletest.Transaction("9", "9", h.cfg.AppleBundleID, "premium_monthly", "Auto-Renewable Subscription", "x", "Production", &next)
	if p, err := h.svc.HandleAppleNotification(context.Background(), h.appleNotification(t, h.apple, "n-3", "EXPIRED", "", stranger)); err != nil || !p {
		t.Fatalf("unknown purchase: %v, %v", p, err)
	}
}

func TestGoogleWebhookVerifiesFirstAndAppliesOnce(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	end := h.clock.Now().Add(30 * 24 * time.Hour)
	token := fake.Encode(fake.Token{TransactionID: "GPA.S1", ProductID: "premium_monthly", AppID: h.cfg.GooglePackageName,
		Environment: store.Production, AccountToken: billing.AccountToken(c.UserID), ExpiresAt: &end})
	if _, err := h.verify(c, "android", "premium_monthly", token); err != nil {
		t.Fatal(err)
	}
	msg := base64.StdEncoding.EncodeToString([]byte(`{"packageName":"` + h.cfg.GooglePackageName +
		`","subscriptionNotification":{"notificationType":12,"purchaseToken":` + jsonString(token) + `,"subscriptionId":"premium_monthly"}}`))

	if _, err := h.svc.HandleGoogleNotification(context.Background(), "Bearer forged", "m-1", msg); !errors.Is(err, apperror.ErrUnauthorized) {
		t.Fatalf("bad push token: %v, want unauthorized", err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.processed_store_notifications`); n != 0 {
		t.Fatal("an unverified push was recorded")
	}
	for i, want := range []bool{true, false} {
		processed, err := h.svc.HandleGoogleNotification(context.Background(), "Bearer good-token", "m-1", msg)
		if err != nil || processed != want {
			t.Fatalf("delivery %d: processed=%v, %v; want %v", i+1, processed, err, want)
		}
	}
	v, _ := h.svc.Subscription(context.Background(), c)
	if v.Entitled || v.Status != "revoked" {
		t.Fatalf("after REVOKED: %+v", v)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.billing_outbox WHERE topic = 'subscription.deactivated'`); n != 1 {
		t.Fatalf("%d deactivation events", n)
	}
}

// A late EXPIRED or ON_HOLD while Google says the subscription runs on is
// stale and changes nothing.
func TestGoogleStaleNotificationIsIgnored(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	end := h.clock.Now().Add(30 * 24 * time.Hour)
	token := fake.Encode(fake.Token{TransactionID: "GPA.S2", ProductID: "premium_monthly", AppID: h.cfg.GooglePackageName,
		Environment: store.Production, AccountToken: billing.AccountToken(c.UserID), ExpiresAt: &end})
	if _, err := h.verify(c, "android", "premium_monthly", token); err != nil {
		t.Fatal(err)
	}
	for i, typ := range []string{"13", "5"} {
		msg := base64.StdEncoding.EncodeToString([]byte(`{"packageName":"` + h.cfg.GooglePackageName +
			`","subscriptionNotification":{"notificationType":` + typ + `,"purchaseToken":` + jsonString(token) + `,"subscriptionId":"premium_monthly"}}`))
		if _, err := h.svc.HandleGoogleNotification(context.Background(), "Bearer good-token", "m-stale-"+typ, msg); err != nil {
			t.Fatal(err)
		}
		if v, _ := h.svc.Subscription(context.Background(), c); !v.Entitled {
			t.Fatalf("notification %d (type %s) ended a subscription Google says runs until %v", i, typ, end)
		}
	}
}

func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// Plan 3.6: a store refund after part of the pack was spent removes what
// is left, records the rest as debt, and creation is blocked until a new
// grant pays it off.
func TestPackRefundAfterPartialSpendRecordsDebt(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	claims := appletest.Transaction("4000001", "4000001", h.cfg.AppleBundleID, "credits_50", "Consumable",
		billing.AccountToken(c.UserID), "Production", nil)
	tok := fake.Encode(fake.Token{TransactionID: "4000001", ProductID: "credits_50", AppID: h.cfg.AppleBundleID,
		Environment: store.Production, AccountToken: billing.AccountToken(c.UserID)})
	if _, err := h.verify(c, "ios", "credits_50", tok); err != nil {
		t.Fatal(err)
	}
	h.reserveCapture(t, c, 30)

	refund := h.appleNotification(t, h.apple, "n-refund", "REFUND", "", claims)
	for range 2 {
		if _, err := h.svc.HandleAppleNotification(ctx, refund); err != nil {
			t.Fatal(err)
		}
	}
	v := h.wallet(t, c)
	if v.Balance != 0 || v.Debt != 30 {
		t.Fatalf("after the refund wallet = %+v, want balance 0 and debt 30", v)
	}
	rules, err := h.svc.Rules(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k-debt")
	var coded *apperror.CodedError
	if !errors.As(err, &coded) || coded.Code != apperror.CodeCreditsDebt {
		t.Fatalf("creating with debt: %v, want credits_debt", err)
	}

	// A new pack pays the debt first.
	if _, err := h.verify(c, "ios", "credits_50", fake.Encode(fake.Token{TransactionID: "4000002", ProductID: "credits_50",
		AppID: h.cfg.AppleBundleID, Environment: store.Production, AccountToken: billing.AccountToken(c.UserID)})); err != nil {
		t.Fatal(err)
	}
	if v := h.wallet(t, c); v.Balance != 20 || v.Debt != 0 {
		t.Fatalf("after a new pack wallet = %+v, want balance 20 and debt 0", v)
	}
	if _, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k-after"); err != nil {
		t.Fatalf("creating after the debt is paid: %v", err)
	}
	h.assertReconciled(t)
}

// Google's voided purchase does the same for an Android pack.
func TestGoogleVoidedPackIsTakenBack(t *testing.T) {
	h := newHarness(t)
	c := h.newUser()
	tok := h.pack(c, "GPA.V1", "credits_50")
	if _, err := h.verify(c, "android", "credits_50", tok); err != nil {
		t.Fatal(err)
	}
	msg := base64.StdEncoding.EncodeToString([]byte(`{"packageName":"` + h.cfg.GooglePackageName +
		`","voidedPurchaseNotification":{"purchaseToken":` + jsonString(tok) + `,"orderId":"GPA.V1","productType":2}}`))
	if _, err := h.svc.HandleGoogleNotification(context.Background(), "Bearer good-token", "m-void", msg); err != nil {
		t.Fatal(err)
	}
	if v := h.wallet(t, c); v.Balance != 0 || v.Debt != 0 {
		t.Fatalf("after voiding an unspent pack wallet = %+v, want 0 and no debt", v)
	}
	h.assertReconciled(t)
}

// --- catalog ---

func setPlansFlag(t *testing.T, h *harness, on bool) {
	t.Helper()
	if _, err := h.pool.Exec(context.Background(), `UPDATE ops.feature_flags SET enabled = $1 WHERE key = 'billing.plans.visible'`, on); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = h.pool.Exec(context.Background(), `UPDATE ops.feature_flags SET enabled = false WHERE key = 'billing.plans.visible'`)
	})
}

func TestCatalogShowsPlansOnlyWhereTheFlagSays(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	ordinary := uuid.NewString()

	cat, err := h.svc.Catalog(ctx, ordinary)
	if err != nil {
		t.Fatal(err)
	}
	if cat.PlansVisible || len(cat.Plans) != 0 {
		t.Fatalf("an ordinary user sees plans: %+v", cat.Plans)
	}
	if len(cat.CreditPacks) != 3 || cat.CreditPacks[1].ProductID != "credits_120" || cat.CreditPacks[1].Credits != 120 || cat.CreditPacks[1].Bonus != 20 {
		t.Fatalf("credit packs = %+v", cat.CreditPacks)
	}
	if cat.AppAccountToken != billing.AccountToken(ordinary) || cat.TermsURL == "" {
		t.Fatalf("catalog = %+v", cat)
	}

	tester, err := h.svc.Catalog(ctx, allowlistedUser)
	if err != nil || !tester.PlansVisible || len(tester.Plans) != 2 {
		t.Fatalf("allowlisted tester's catalog = %+v, %v", tester, err)
	}
	if p := tester.Plans[1]; p.Code != "pro" || p.Period != "year" || !p.Featured || p.ProductIDs["ios"] != "premium_yearly" || len(p.Perks) == 0 {
		t.Fatalf("yearly plan = %+v", p)
	}

	setPlansFlag(t, h, true)
	for _, who := range []string{ordinary, ""} {
		c, err := h.svc.Catalog(ctx, who)
		if err != nil || !c.PlansVisible || len(c.Plans) != 2 {
			t.Fatalf("after the flag flips, catalog for %q = %+v, %v", who, c, err)
		}
	}
	anon, _ := h.svc.Catalog(ctx, "")
	if anon.AppAccountToken != "" {
		t.Fatal("an anonymous catalog carries an account token")
	}
	raw, _ := json.Marshal(tester)
	if strings.Contains(strings.ToLower(string(raw)), "price") {
		t.Fatalf("the catalog carries a price: %s", raw)
	}
}

// The account token is the documented UUIDv5, stable and per user.
func TestAccountTokenIsStableUUIDv5(t *testing.T) {
	a := billing.AccountToken("00000000-0000-4000-8000-000000000040")
	if a != billing.AccountToken("00000000-0000-4000-8000-000000000040") || a == billing.AccountToken(uuid.NewString()) {
		t.Fatal("account token is not stable per user")
	}
	if u, err := uuid.Parse(a); err != nil || u.Version() != 5 {
		t.Fatalf("account token %q is not a UUIDv5", a)
	}
	if want := uuid.NewSHA1(billing.AccountTokenNamespace, []byte("00000000-0000-4000-8000-000000000040")).String(); a != want {
		t.Fatalf("account token = %s, want %s", a, want)
	}
}
