package billing_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/billing"
	"professional-meetups-monolith/backend/internal/modules/billing/wallet"
	"professional-meetups-monolith/backend/internal/platform/apperror"
)

const week = 7 * 24 * time.Hour

// D1/D2: a 60-credit welcome lot decays by 6 each week until it is gone, the
// sweep is idempotent, and a spend between sweeps sees the decayed balance.
func TestWelcomeCreditsDecayWeekly(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := h.newHost()

	if got := h.wallet(t, host).Balance; got != 60 {
		t.Fatalf("welcome balance = %d, want 60", got)
	}

	for k, want := range []int64{54, 48, 42, 36, 30, 24, 18, 12, 6, 0} {
		h.clock.Advance(week)
		if _, err := h.svc.SweepDecayAndExpiry(ctx); err != nil {
			t.Fatal(err)
		}
		before := h.count(t, `SELECT count(*) FROM billing.ledger_entries WHERE user_id = $1`, host.UserID)
		// Rerunning the sweep in the same instant changes nothing.
		if _, err := h.svc.SweepDecayAndExpiry(ctx); err != nil {
			t.Fatal(err)
		}
		if after := h.count(t, `SELECT count(*) FROM billing.ledger_entries WHERE user_id = $1`, host.UserID); after != before {
			t.Fatalf("week %d: a second sweep wrote %d more ledger rows", k+1, after-before)
		}
		if got := h.wallet(t, host).Balance; got != want {
			t.Fatalf("after week %d balance = %d, want %d", k+1, got, want)
		}
	}
	h.assertReconciled(t)
}

func TestSpendBetweenSweepsSeesTheDecayedBalance(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := h.newHost()
	_ = h.wallet(t, host) // grant 60

	// Three weeks pass with no sweep at all: the lot is allowed 42.
	h.clock.Advance(3*week + time.Hour)
	rules, _ := h.svc.Rules(ctx)
	_, err := h.svc.Reserve(ctx, host.UserID, billing.ReserveRequest{Cost: 43, PriceVersion: rules.Version}, "k1")
	var coded *apperror.CodedError
	if !errors.As(err, &coded) || coded.Code != apperror.CodeInsufficientCredits || coded.Fields["available"] != 42 {
		t.Fatalf("reserving 43 against a decayed 42: err = %v", err)
	}
	if _, err := h.svc.Reserve(ctx, host.UserID, billing.ReserveRequest{Cost: 42, PriceVersion: rules.Version}, "k2"); err != nil {
		t.Fatalf("reserving the decayed balance exactly: %v", err)
	}
	h.assertReconciled(t)
}

// Expiring credits are spent first, so free welcome credits go before
// purchased ones, and a refund puts credits back in the lot they came from.
func TestSpendOrderAndRefundToOriginalLots(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := h.newHost()
	_ = h.wallet(t, host) // 60 welcome
	purchased, err := h.svc.GrantLotForTest(ctx, host.UserID, wallet.KindPurchase, 100, nil)
	if err != nil {
		t.Fatal(err)
	}

	hold := h.reserveCapture(t, host, 70)

	lot := func(id uuid.UUID) int64 {
		return int64(h.count(t, `SELECT remaining FROM billing.credit_lots WHERE id = $1`, id))
	}
	welcomeRemaining := int64(h.count(t, `SELECT remaining FROM billing.credit_lots WHERE kind = 'welcome' AND user_id = $1`, host.UserID))
	if welcomeRemaining != 0 || lot(purchased) != 90 {
		t.Fatalf("after spending 70: welcome %d (want 0), purchased %d (want 90)", welcomeRemaining, lot(purchased))
	}

	// A full refund (cancelled well ahead) returns 60 to welcome and 10 to
	// the purchase.
	err = h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
		HoldID: hold, MeetupID: uuid.NewString(), Event: billing.EventCancelled,
		WindowStart: h.clock.Now().Add(72 * time.Hour), EndedAt: h.clock.Now(),
	})
	if err != nil {
		t.Fatal(err)
	}
	welcomeRemaining = int64(h.count(t, `SELECT remaining FROM billing.credit_lots WHERE kind = 'welcome' AND user_id = $1`, host.UserID))
	if welcomeRemaining != 60 || lot(purchased) != 100 {
		t.Fatalf("after refund: welcome %d (want 60), purchased %d (want 100)", welcomeRemaining, lot(purchased))
	}
	h.assertReconciled(t)
}

// Credits refunded to a lot that has since expired expire with it.
func TestRefundToAnExpiredLotExpiresWithIt(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	soon := h.clock.Now().Add(24 * time.Hour)
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPromo, 30, &soon); err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 50, nil); err != nil {
		t.Fatal(err)
	}
	hold := h.reserveCapture(t, c, 40) // 30 promo + 10 purchased

	h.clock.Advance(48 * time.Hour) // the promo lot has expired
	if err := h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
		HoldID: hold, MeetupID: uuid.NewString(), Event: billing.EventCancelled,
		WindowStart: h.clock.Now().Add(72 * time.Hour), EndedAt: h.clock.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	// 10 back to the purchase; the 30 that went back to the promo lot
	// expired again at once.
	if got := h.wallet(t, c).Balance; got != 50 {
		t.Fatalf("balance = %d, want 50", got)
	}
	h.assertReconciled(t)
}

func TestCaptureAfterTheHoldExpired(t *testing.T) {
	ctx := context.Background()

	t.Run("enough balance: spent, no debt", func(t *testing.T) {
		h := newHarness(t)
		c := h.newUser()
		if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 25, nil); err != nil {
			t.Fatal(err)
		}
		rules, _ := h.svc.Rules(ctx)
		hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k")
		if err != nil {
			t.Fatal(err)
		}
		h.clock.Advance(3 * time.Hour)
		if n, err := h.svc.SweepExpiredHolds(ctx); err != nil || n != 1 {
			t.Fatalf("expiry sweep released %d, %v; want 1", n, err)
		}
		if v := h.wallet(t, c); v.Held != 0 || v.Available != 25 {
			t.Fatalf("after expiry: %+v", v)
		}
		if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
			t.Fatal(err)
		}
		if v := h.wallet(t, c); v.Balance != 15 || v.Debt != 0 {
			t.Fatalf("after late capture: %+v, want balance 15 and no debt", v)
		}
		h.assertReconciled(t)
	})

	t.Run("not enough balance: records debt, which blocks creation", func(t *testing.T) {
		h := newHarness(t)
		c := h.newUser()
		if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 12, nil); err != nil {
			t.Fatal(err)
		}
		rules, _ := h.svc.Rules(ctx)
		hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k1")
		if err != nil {
			t.Fatal(err)
		}
		h.clock.Advance(3 * time.Hour)
		if _, err := h.svc.SweepExpiredHolds(ctx); err != nil {
			t.Fatal(err)
		}
		// Meanwhile the credits went elsewhere.
		h.reserveCapture(t, c, 8)
		if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
			t.Fatal(err)
		}
		v := h.wallet(t, c)
		if v.Balance != 0 || v.Debt != 6 {
			t.Fatalf("after late capture: %+v, want balance 0 and debt 6", v)
		}
		_, err = h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 1, PriceVersion: rules.Version}, "k2")
		var coded *apperror.CodedError
		if !errors.As(err, &coded) || coded.Code != apperror.CodeCreditsDebt {
			t.Fatalf("reserve with debt: %v, want credits_debt", err)
		}
		// A grant pays the debt off first.
		if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 10, nil); err != nil {
			t.Fatal(err)
		}
		if v := h.wallet(t, c); v.Debt != 0 || v.Balance != 4 {
			t.Fatalf("after a grant: %+v, want debt 0 and balance 4", v)
		}
		h.assertReconciled(t)
	})
}

func TestCaptureIsIdempotent(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 30, nil); err != nil {
		t.Fatal(err)
	}
	hold := h.reserveCapture(t, c, 10)
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if got := h.wallet(t, c).Balance; got != 20 {
		t.Fatalf("balance after repeated captures = %d, want 20", got)
	}
	h.assertReconciled(t)
}

// D7: the refund policy and the 3-per-30-days cap.
func TestRefundPolicy(t *testing.T) {
	ctx := context.Background()
	h := newHarness(t)
	now := h.clock.Now()

	cases := []struct {
		name  string
		event billing.MeetupEnded
		want  int64 // credits back from a 20-credit charge
	}{
		{"cancelled 24h or more ahead: full", billing.MeetupEnded{Event: billing.EventCancelled, WindowStart: now.Add(24 * time.Hour), EndedAt: now}, 20},
		{"cancelled under 24h ahead: nothing", billing.MeetupEnded{Event: billing.EventCancelled, WindowStart: now.Add(23 * time.Hour), EndedAt: now}, 0},
		{"closed with nobody accepted: half", billing.MeetupEnded{Event: billing.EventClosed, AcceptedCount: 0, WindowStart: now.Add(-2 * time.Hour), EndedAt: now}, 10},
		{"closed with people: nothing", billing.MeetupEnded{Event: billing.EventClosed, AcceptedCount: 2, WindowStart: now.Add(-2 * time.Hour), EndedAt: now}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := h.newUser()
			if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 100, nil); err != nil {
				t.Fatal(err)
			}
			hold := h.reserveCapture(t, c, 20)
			e := tc.event
			e.HoldID, e.MeetupID = hold, uuid.NewString()
			for i := 0; i < 3; i++ { // redelivery is a no-op
				if err := h.svc.HandleMeetupEnded(ctx, e); err != nil {
					t.Fatal(err)
				}
			}
			if got := h.wallet(t, c).Balance; got != 80+tc.want {
				t.Fatalf("balance = %d, want %d", got, 80+tc.want)
			}
		})
	}
	h.assertReconciled(t)

	t.Run("at most 3 refunds per 30 days", func(t *testing.T) {
		c := h.newUser()
		if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 100, nil); err != nil {
			t.Fatal(err)
		}
		cancel := func() {
			hold := h.reserveCapture(t, c, 10)
			if err := h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
				HoldID: hold, MeetupID: uuid.NewString(), Event: billing.EventCancelled,
				WindowStart: h.clock.Now().Add(48 * time.Hour), EndedAt: h.clock.Now(),
			}); err != nil {
				t.Fatal(err)
			}
		}
		for i := 0; i < 3; i++ {
			cancel()
		}
		if got := h.wallet(t, c).Balance; got != 100 {
			t.Fatalf("after 3 refunded cancellations balance = %d, want 100", got)
		}
		cancel() // the fourth is not refunded
		if got := h.wallet(t, c).Balance; got != 90 {
			t.Fatalf("after the 4th cancellation balance = %d, want 90", got)
		}
		if n := h.count(t, `SELECT count(*) FROM billing.refund_log WHERE user_id = $1 AND outcome = 'skipped_cap'`, c.UserID); n != 1 {
			t.Fatalf("skipped_cap rows = %d, want 1", n)
		}
		// 30 days on, refunds are allowed again.
		h.clock.Advance(31 * 24 * time.Hour)
		cancel()
		if got := h.wallet(t, c).Balance; got != 90 {
			t.Fatalf("after the window balance = %d, want 90 (refunded)", got)
		}
		h.assertReconciled(t)
	})
}

// A full refund arriving before the created event was captured just
// releases the hold: nothing is charged at all.
func TestCancelBeforeCaptureReleases(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 30, nil); err != nil {
		t.Fatal(err)
	}
	rules, _ := h.svc.Rules(ctx)
	hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k")
	if err != nil {
		t.Fatal(err)
	}
	meetup := uuid.NewString()
	if err := h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
		HoldID: hold, MeetupID: meetup, Event: billing.EventCancelled,
		WindowStart: h.clock.Now().Add(48 * time.Hour), EndedAt: h.clock.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	// The late created event then captures nothing.
	if err := h.svc.Capture(ctx, hold, meetup); err != nil {
		t.Fatal(err)
	}
	if v := h.wallet(t, c); v.Balance != 30 || v.Held != 0 {
		t.Fatalf("wallet = %+v, want 30 untouched", v)
	}
	h.assertReconciled(t)
}

// Plan 3.4: ten creations a period inside the quota, the eleventh costs
// credits; 30 people and 30 days ahead only with a plan.
func TestPlanQuotaAndLimits(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 100, nil); err != nil {
		t.Fatal(err)
	}
	soon := h.clock.Now().Add(5 * time.Hour)

	// Without a plan: capacity 30 and 30 days ahead are refused.
	if _, err := h.svc.Quote(ctx, c, 30, soon); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("capacity 30 without a plan: %v", err)
	}
	if _, err := h.svc.Quote(ctx, c, 4, h.clock.Now().Add(30*24*time.Hour)); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("30 days ahead without a plan: %v", err)
	}

	if err := h.svc.AdminSetPlan(ctx, c.UserID, "pro", h.clock.Now().Add(30*24*time.Hour),
		billing.AdminAction{Operator: "test", Reason: "quota test"}); err != nil {
		t.Fatal(err)
	}
	q, err := h.svc.Quote(ctx, c, 30, h.clock.Now().Add(29*24*time.Hour))
	if err != nil {
		t.Fatalf("capacity 30, 29 days ahead with a plan: %v", err)
	}
	if !q.CoveredByPlan || q.Cost != 0 {
		t.Fatalf("first creation on a plan: %+v, want covered and free", q)
	}

	for i := 0; i < 10; i++ {
		q, err := h.svc.Quote(ctx, c, 4, soon)
		if err != nil {
			t.Fatal(err)
		}
		if !q.CoveredByPlan {
			t.Fatalf("creation %d not covered by the plan", i+1)
		}
		hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{
			Cost: q.Cost, PriceVersion: q.PriceVersion, CoveredByPlan: true,
		}, uuid.NewString())
		if err != nil {
			t.Fatal(err)
		}
		if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
			t.Fatal(err)
		}
	}
	q, err = h.svc.Quote(ctx, c, 4, soon)
	if err != nil {
		t.Fatal(err)
	}
	if q.CoveredByPlan || q.Cost != 10 {
		t.Fatalf("eleventh creation: %+v, want 10 credits", q)
	}
	ent, err := h.svc.Entitlements(ctx, c)
	if err != nil {
		t.Fatal(err)
	}
	if ent.PlanCode != "pro" || ent.MeetupsUsed != 10 || ent.MeetupsIncluded != 10 || ent.Limits.MaxCapacity != 30 {
		t.Fatalf("entitlements = %+v", ent)
	}
	if got := h.wallet(t, c).Balance; got != 100 {
		t.Fatalf("quota creations spent credits: balance %d", got)
	}
	h.assertReconciled(t)
}

// Credits have no switch: without a plan the free limits apply and every
// creation is priced, from day one.
func TestFreeLimitsApplyWithoutAPlan(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.Quote(ctx, c, 4, h.clock.Now().Add(15*24*time.Hour)); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("15 days ahead without a plan: err = %v, want invalid input", err)
	}
	if _, err := h.svc.Quote(ctx, c, 21, h.clock.Now().Add(time.Hour)); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("21 people without a plan: err = %v, want invalid input", err)
	}
	q, err := h.svc.Quote(ctx, c, 5, h.clock.Now().Add(time.Hour))
	if err != nil || q.Cost != 12 || q.WouldCost != 12 || q.Limits != (billing.Limits{MaxCapacity: 20, MaxAdvanceDays: 14}) {
		t.Fatalf("quote = %+v, %v; want cost 12 under the free limits", q, err)
	}
}

// D1: once per user and once per person, under concurrent first calls.
func TestWelcomeGrantOncePerUserAndPerPerson(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	t.Run("one user, many concurrent first calls", func(t *testing.T) {
		host := h.newHost()
		var wg sync.WaitGroup
		for i := 0; i < 15; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				var err error
				switch i % 3 {
				case 0:
					_, err = h.svc.Wallet(ctx, host)
				case 1:
					_, err = h.svc.Entitlements(ctx, host)
				default:
					_, err = h.svc.Quote(ctx, host, 4, h.clock.Now().Add(time.Hour))
				}
				if err != nil {
					t.Error(err)
				}
			}(i)
		}
		wg.Wait()
		if got := h.wallet(t, host).Balance; got != 60 {
			t.Fatalf("balance = %d, want one 60-credit grant", got)
		}
	})

	t.Run("two accounts, one verified phone", func(t *testing.T) {
		a, b := h.newHost(), h.newHost()
		h.fps.set(b.UserID, "shared-phone")
		h.fps.set(a.UserID, "shared-phone")
		var wg sync.WaitGroup
		for _, c := range []billing.Caller{a, b, a, b, a, b} {
			wg.Add(1)
			go func(c billing.Caller) {
				defer wg.Done()
				if _, err := h.svc.Wallet(ctx, c); err != nil {
					t.Error(err)
				}
			}(c)
		}
		wg.Wait()
		total := h.wallet(t, a).Balance + h.wallet(t, b).Balance
		if total != 60 {
			t.Fatalf("two accounts with one phone got %d credits between them, want 60", total)
		}
	})

	t.Run("below hosting level: no grant", func(t *testing.T) {
		c := h.newHost()
		c.TrustLevel = 2
		if got := h.wallet(t, c).Balance; got != 0 {
			t.Fatalf("level 2 balance = %d, want 0", got)
		}
	})
	h.assertReconciled(t)
}

func TestLedgerIsAppendOnly(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	_ = h.wallet(t, h.newHost())
	if _, err := h.pool.Exec(ctx, `UPDATE billing.ledger_entries SET delta = 1000`); err == nil {
		t.Fatal("UPDATE of the ledger succeeded")
	}
	if _, err := h.pool.Exec(ctx, `DELETE FROM billing.ledger_entries`); err == nil {
		t.Fatal("DELETE from the ledger succeeded")
	}
	if _, err := h.pool.Exec(ctx, `TRUNCATE billing.ledger_entries`); err == nil {
		t.Fatal("TRUNCATE of the ledger succeeded")
	}
}

func TestReconciliationFindsTamperingAndRunsOncePerDay(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := h.newHost()
	_ = h.wallet(t, host)
	h.assertReconciled(t)

	if _, err := h.pool.Exec(ctx, `UPDATE billing.wallets SET balance = balance + 5 WHERE user_id = $1`, host.UserID); err != nil {
		t.Fatal(err)
	}
	m, err := h.svc.FindMismatches(ctx)
	if err != nil || len(m) != 1 || m[0].UserID != host.UserID {
		t.Fatalf("mismatches = %+v, %v; want the tampered wallet", m, err)
	}
	if n, err := h.svc.Reconcile(ctx); err != nil || n != 1 {
		t.Fatalf("first run today checked %d, %v", n, err)
	}
	if n, err := h.svc.Reconcile(ctx); err != nil || n != 0 {
		t.Fatalf("second run today checked %d, %v; want a no-op", n, err)
	}
	if got := h.count(t, `SELECT mismatches FROM billing.reconciliation_runs`); got != 1 {
		t.Fatalf("recorded mismatches = %d, want 1", got)
	}
}

func TestLedgerPagination(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	for i := 0; i < 7; i++ {
		if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, int64(i+1), nil); err != nil {
			t.Fatal(err)
		}
	}
	other := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, other.UserID, wallet.KindPurchase, 999, nil); err != nil {
		t.Fatal(err)
	}

	var seen []int64
	cursor := ""
	for {
		page, err := h.svc.Ledger(ctx, c.UserID, cursor, 3)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range page.Entries {
			if e.Delta == 999 {
				t.Fatal("another user's entry appeared")
			}
			seen = append(seen, e.Delta)
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
	}
	if len(seen) != 7 || seen[0] != 7 || seen[6] != 1 {
		t.Fatalf("pages gave %v, want 7..1 newest first", seen)
	}
	if _, err := h.svc.Ledger(ctx, c.UserID, "not-a-cursor", 3); !errors.Is(err, apperror.ErrInvalidInput) {
		t.Fatalf("bad cursor: %v", err)
	}
}

func TestDeletedAccountWalletIsClosed(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 40, nil); err != nil {
		t.Fatal(err)
	}
	if err := h.svc.HandleUserDeleted(ctx, eventbusPayload(c.UserID)); err != nil {
		t.Fatal(err)
	}
	if err := h.svc.HandleUserDeleted(ctx, eventbusPayload(c.UserID)); err != nil {
		t.Fatal(err)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.admin_audit WHERE user_id = $1 AND action = 'account_deleted'`, c.UserID); n != 1 {
		t.Fatalf("audit rows = %d, want 1", n)
	}
	rules, _ := h.svc.Rules(ctx)
	if _, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k"); !errors.Is(err, apperror.ErrForbidden) {
		t.Fatalf("reserve on a closed wallet: %v", err)
	}
}

func eventbusPayload(userID string) eventbus.UserDeletedPayload {
	return eventbus.UserDeletedPayload{UserID: userID}
}

// A host's first quote — the create path's first billing call — grants the
// welcome credits, so a new host can create a meetup straight away.
func TestFirstQuoteGrantsWelcomeCredits(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := h.newHost()
	q, err := h.svc.Quote(ctx, host, 4, h.clock.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if q.BalanceAvailable != 60 || q.Cost != 10 {
		t.Fatalf("first quote = %+v; want 60 available and cost 10", q)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.welcome_grants WHERE user_id = $1`, host.UserID); n != 1 {
		t.Fatalf("%d welcome grants, want 1", n)
	}
}

// Review fix 4: a cancellation that lands before the capture (and so just
// releases the hold) still counts toward the 3-refunds-per-30-days cap, and
// once the cap is reached it is charged like any other.
func TestCancelBeforeCaptureCountsTowardTheRefundCap(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 100, nil); err != nil {
		t.Fatal(err)
	}
	rules, _ := h.svc.Rules(ctx)
	cancelEarly := func() {
		hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, uuid.NewString())
		if err != nil {
			t.Fatal(err)
		}
		if err := h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
			HoldID: hold, MeetupID: uuid.NewString(), Event: billing.EventCancelled,
			WindowStart: h.clock.Now().Add(48 * time.Hour), EndedAt: h.clock.Now(),
		}); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		cancelEarly()
	}
	if got := h.wallet(t, c).Balance; got != 100 {
		t.Fatalf("after 3 early cancellations balance = %d, want 100", got)
	}
	cancelEarly()
	if v := h.wallet(t, c); v.Balance != 90 || v.Held != 0 {
		t.Fatalf("after the 4th: %+v, want 10 charged and nothing held", v)
	}
	if n := h.count(t, `SELECT count(*) FROM billing.refund_log WHERE user_id = $1 AND outcome = 'skipped_cap'`, c.UserID); n != 1 {
		t.Fatalf("skipped_cap rows = %d, want 1", n)
	}
	h.assertReconciled(t)
}

// Review fix 5: a full refund of a capture that went partly into debt gives
// back what was spent and writes off the debt that capture created, leaving
// the wallet where it was before the capture.
func TestFullRefundWritesOffTheCapturesOwnDebt(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c := h.newUser()
	if _, err := h.svc.GrantLotForTest(ctx, c.UserID, wallet.KindPurchase, 12, nil); err != nil {
		t.Fatal(err)
	}
	rules, _ := h.svc.Rules(ctx)
	hold, err := h.svc.Reserve(ctx, c.UserID, billing.ReserveRequest{Cost: 10, PriceVersion: rules.Version}, "k1")
	if err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(3 * time.Hour)
	if _, err := h.svc.SweepExpiredHolds(ctx); err != nil {
		t.Fatal(err)
	}
	h.reserveCapture(t, c, 8)
	before := h.wallet(t, c) // balance 4, debt 0
	if err := h.svc.Capture(ctx, hold, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	if v := h.wallet(t, c); v.Balance != 0 || v.Debt != 6 {
		t.Fatalf("after the short capture: %+v, want balance 0, debt 6", v)
	}
	if err := h.svc.HandleMeetupEnded(ctx, billing.MeetupEnded{
		HoldID: hold, MeetupID: uuid.NewString(), Event: billing.EventCancelled,
		WindowStart: h.clock.Now().Add(48 * time.Hour), EndedAt: h.clock.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if v := h.wallet(t, c); v.Balance != before.Balance || v.Debt != before.Debt {
		t.Fatalf("after a full refund: %+v, want balance %d and debt %d as before the capture", v, before.Balance, before.Debt)
	}
	h.assertReconciled(t)
}
