package meetup_test

// §F7: the notification outbox, against real Postgres. Everything here is
// about the DELIVERY MECHANISM's guarantees — atomicity with the business
// write, concurrent-claim safety, backoff, dead-lettering, and crash
// recovery. Who gets notified and what the copy says is covered by the
// module's own integration tests.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/modules/meetup"
	"professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/modules/notification"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// --- §F7: atomicity with the business write -------------------------------

// TestOutbox_RollsBackWithTheBusinessWrite is THE test §F exists for.
//
// It simulates a failure after the outbox rows have been written but before
// the business write commits, and asserts BOTH disappear. That is what
// "genuinely atomic" means here, as opposed to "committed, then a best-effort
// publish afterwards" — the shape Phase 2 had, in which a crash in that gap
// loses the notification permanently with the business fact already durable.
func TestOutbox_RollsBackWithTheBusinessWrite_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	seedDisplay(t, h, requester, "Requester")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register host device: %v", err)
	}

	m := createOpenMeetup(t, h, host)

	requestsBefore := countRows(t, h, "meetup.meetup_requests")
	outboxBefore := h.countOutboxRows(t)

	// A notify callback that queues a notification and THEN fails — exactly
	// the "something went wrong between the outbox insert and the commit"
	// scenario.
	boom := errors.New("simulated failure after the outbox insert")
	_, err := h.requests.Create(ctx, m.ID, requester, host,
		func(ctx context.Context, tx repository.NotifyTx, created repository.MeetupRequest) error {
			if err := tx.Enqueue(ctx, repository.OutboxRow{
				FCMTokens: []string{"host-device-token"},
				Title:     "New join request",
				Body:      "someone wants to join",
			}); err != nil {
				return err
			}
			return boom
		})

	if !errors.Is(err, boom) {
		t.Fatalf("Create() error = %v, want the simulated failure to propagate", err)
	}

	if got := countRows(t, h, "meetup.meetup_requests"); got != requestsBefore {
		t.Errorf("meetup_requests rows = %d, want %d — the business write survived a failure that should have rolled it back", got, requestsBefore)
	}
	if got := h.countOutboxRows(t); got != outboxBefore {
		t.Errorf("notification_outbox rows = %d, want %d — the outbox insert committed independently of the business write it was supposed to be atomic with", got, outboxBefore)
	}
}

// TestOutbox_CommitsWithTheBusinessWrite is the same guarantee from the
// other side: on the success path, the row and its notification appear
// together. Without this, the test above would pass trivially against an
// implementation that never queues anything at all.
func TestOutbox_CommitsWithTheBusinessWrite_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	seedDisplay(t, h, requester, "Requester")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register host device: %v", err)
	}

	m := createOpenMeetup(t, h, host)
	// Creating a meetup queues the host's own safety-checklist prompt, which
	// is not what this test is about — clear it so the assertion below is
	// about the join request alone.
	clearOutbox(t, h)

	if _, err := h.svc.RequestToJoin(ctx, requestToJoin(m.ID, requester)); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	titles := h.outboxTitles(t)
	if len(titles) != 1 || titles[0] != "New join request" {
		t.Fatalf("queued notifications = %v, want exactly one \"New join request\"", titles)
	}

	row := firstOutboxRow(t, h)
	if len(row.FCMTokens) != 1 || row.FCMTokens[0] != "host-device-token" {
		t.Errorf("queued tokens = %v, want the host's registered token", row.FCMTokens)
	}
	if row.ProcessedAt != nil {
		t.Error("a freshly queued row is already marked processed")
	}
	if row.Attempts != 0 {
		t.Errorf("attempts = %d on a fresh row, want 0", row.Attempts)
	}
}

// TestOutbox_NoDeviceMeansNoRow pins the deliberate skip: queuing a
// notification for someone with no registered device would create a row the
// poller claims, delivers to nobody, and marks processed — pure churn that
// would also inflate every delivery metric with non-events.
func TestOutbox_NoDeviceMeansNoRow_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	seedDisplay(t, h, requester, "Requester")
	// Deliberately no device token for the host.

	m := createOpenMeetup(t, h, host)
	if _, err := h.svc.RequestToJoin(ctx, requestToJoin(m.ID, requester)); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	if got := h.countOutboxRows(t); got != 0 {
		t.Errorf("queued %d rows for a user with no registered device, want 0", got)
	}
}

// --- §F7: concurrent claims ------------------------------------------------

// TestClaimBatch_ConcurrentClaimersNeverOverlap is the FOR UPDATE SKIP
// LOCKED guarantee, and the reason §C2/§F can survive a horizontally-scaled
// monolith. Two claimers running at the same instant against the same
// pending set must receive DISJOINT rows — if they overlap, every user in
// the overlap gets the same notification twice.
func TestClaimBatch_ConcurrentClaimersNeverOverlap_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const total = 60
	seedOutboxRows(t, h, total)

	const claimers = 4
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		claimed []string
		start   = make(chan struct{})
	)

	for i := 0; i < claimers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start // maximise the overlap
			for {
				rows, err := h.outbox.ClaimBatch(ctx, 7)
				if err != nil {
					t.Errorf("ClaimBatch: %v", err)
					return
				}
				if len(rows) == 0 {
					return
				}
				mu.Lock()
				for _, r := range rows {
					claimed = append(claimed, r.ID)
				}
				mu.Unlock()

				// Mark them processed so they leave the pending set, the
				// way the real poller does.
				for _, r := range rows {
					if err := h.outbox.MarkProcessed(ctx, r.ID); err != nil {
						t.Errorf("MarkProcessed: %v", err)
						return
					}
				}
			}
		}()
	}
	close(start)
	wg.Wait()

	seen := map[string]int{}
	for _, id := range claimed {
		seen[id]++
	}

	// THE ASSERTION THIS TEST EXISTS FOR. Before the claim query was rewritten
	// to stamp a visibility timeout, this failed immediately and severely —
	// with four concurrent claimers, rows came back two and three times each,
	// which in production is the same user receiving the same push two and
	// three times.
	for id, n := range seen {
		if n > 1 {
			t.Errorf("row %s was claimed %d times by concurrent claimers — SKIP LOCKED plus the visibility timeout are not preventing overlap, and every recipient of that row would be notified %d times", id, n, n)
		}
	}

	// Nothing was DROPPED either: the pending set is drained. Asserted on the
	// table rather than on this test's own tally, because a real monolith
	// container attached to the same database has its own poller and is a
	// legitimate competing claimer — rows it took are delivered, just not by
	// these goroutines. "Claimed by somebody, exactly once" is the guarantee;
	// "claimed by me" is not.
	var stillDue int
	if err := h.pool.QueryRow(ctx, `
		SELECT count(*) FROM meetup.notification_outbox
		WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()`).
		Scan(&stillDue); err != nil {
		t.Fatalf("count still-due rows: %v", err)
	}
	if stillDue != 0 {
		t.Errorf("%d rows were left due after every claimer stopped — concurrent claiming dropped work", stillDue)
	}
	t.Logf("%d claimers took %d rows between them, no row twice; %d of the %d seeded were taken by this test's own claimers",
		claimers, len(seen), len(seen), total)
}

// TestClaimBatch_LockedRowsAreSkippedNotWaitedOn distinguishes SKIP LOCKED
// from a plain FOR UPDATE. With plain FOR UPDATE a second claimer BLOCKS on
// the first transaction, so one slow claimer stalls every other one instead
// of them working in parallel.
//
// # WHAT THIS ASSERTS, AND WHY NOT A ROW COUNT
//
// The two properties that ARE the guarantee: the claim returns promptly
// (skipped, not waited on) and it never returns a row another transaction
// holds (disjoint, not overlapping). It deliberately does not assert "exactly
// N rows came back", because a real monolith container attached to the same
// database has its own poller that is a legitimate competing claimer — it may
// take some of these rows first, which is correct behaviour and not something
// this test should fail on. An exact-count assertion made this test fail
// intermittently for a reason that was never a defect.
func TestClaimBatch_LockedRowsAreSkippedNotWaitedOn_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedOutboxRows(t, h, 20)

	// Hold locks on some rows in a transaction we keep open, imitating a
	// claimer that is mid-processing.
	tx, err := h.pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	rows, err := tx.Query(ctx, `
		SELECT id FROM meetup.notification_outbox
		WHERE processed_at IS NULL AND dead_lettered_at IS NULL
		ORDER BY next_attempt_at LIMIT 5 FOR UPDATE SKIP LOCKED`)
	if err != nil {
		t.Fatalf("hold lock: %v", err)
	}
	held := map[string]bool{}
	for rows.Next() {
		var id string
		_ = rows.Scan(&id)
		held[id] = true
	}
	rows.Close()
	if len(held) == 0 {
		t.Skip("could not hold a lock on any row — another claimer took them all first; nothing to assert")
	}

	start := time.Now()
	claimed, err := h.outbox.ClaimBatch(ctx, 50)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}

	// PROPERTY 1: skipped, not waited on. With plain FOR UPDATE this would
	// block until the transaction above ends — which, since it is held to the
	// end of this test, means until the test timeout.
	if elapsed > 3*time.Second {
		t.Errorf("ClaimBatch took %v — it appears to be WAITING on the locked rows rather than skipping them", elapsed)
	}

	// PROPERTY 2: never overlapping. This is the one that would produce
	// duplicate notifications in production.
	for _, r := range claimed {
		if held[r.ID] {
			t.Errorf("claimed row %s while another transaction holds a lock on it — two claimers would both deliver it", r.ID)
		}
	}
	t.Logf("held locks on %d rows; a concurrent claim returned %d disjoint rows in %v", len(held), len(claimed), elapsed)
}

// TestClaimBatch_RecoversRowsFromACrashedClaimer proves a claimer that dies
// mid-delivery does not strand its rows.
//
// Recovery is the VISIBILITY TIMEOUT, not lock release: the claim writes
// next_attempt_at into the future, so a claimer that records no outcome
// simply leaves its rows to fall due again on their own. Nothing detects the
// crash; there is no lease table and no stuck-claim reaper. That is the
// property worth pinning, because the alternative designs all require code
// that only ever runs after a crash — the code least likely to be correct.
func TestClaimBatch_RecoversRowsFromACrashedClaimer_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedOutboxRows(t, h, 2)

	// A claimer takes the rows and then "crashes" — no MarkProcessed, no
	// MarkFailed, nothing.
	claimed, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(claimed) != 2 {
		t.Fatalf("claimed %d rows, want 2", len(claimed))
	}

	// Immediately afterwards nothing else can claim them — this is what
	// stops two live pollers double-delivering.
	again, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(again) != 0 {
		t.Fatalf("claimed %d rows that another claimer is still working on", len(again))
	}

	// Once the visibility timeout lapses (simulated rather than waited out),
	// the abandoned rows become claimable again with no recovery step.
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.notification_outbox SET next_attempt_at = now() - interval '1 second'`); err != nil {
		t.Fatalf("expire visibility timeout: %v", err)
	}

	recovered, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(recovered) != 2 {
		t.Errorf("recovered %d rows after the claimer died, want 2 — work abandoned by a crashed claimer must become claimable again on its own", len(recovered))
	}
	// And the attempt was counted, so a row that reliably kills its claimer
	// still exhausts its budget and dead-letters instead of looping forever.
	for _, r := range recovered {
		if r.Attempts < 2 {
			t.Errorf("attempts = %d after two claims, want at least 2 — a delivery that crashes the process must still count against the retry ceiling", r.Attempts)
		}
	}
}

// --- §F7: backoff and dead-lettering ---------------------------------------

// TestOutbox_FailedRowBacksOffAndIsNotImmediatelyReclaimable pins the retry
// schedule actually taking effect in SQL: a failed row must drop out of the
// claimable set until its next_attempt_at is due, or a permanently-failing
// row becomes a hot loop that starves every healthy row behind it.
func TestOutbox_FailedRowBacksOffAndIsNotImmediatelyReclaimable_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedOutboxRows(t, h, 1)
	claimed, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil || len(claimed) != 1 {
		t.Fatalf("ClaimBatch: %v (%d rows)", err, len(claimed))
	}

	future := time.Now().Add(time.Hour)
	if err := h.outbox.MarkFailed(ctx, claimed[0].ID, future, "simulated transient failure"); err != nil {
		t.Fatalf("MarkFailed: %v", err)
	}

	again, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("claimed %d rows, want 0 — a row backing off must not be claimable before it is due", len(again))
	}

	// Attempts is what drives both the backoff curve and the dead-letter
	// ceiling, so it has to actually increment.
	row := firstOutboxRow(t, h)
	if row.Attempts != 1 {
		t.Errorf("attempts = %d after one claim-and-fail, want 1 (incremented at claim time, not again on failure — double-counting would halve the retry budget)", row.Attempts)
	}
	if row.ProcessedAt != nil {
		t.Error("a failed row was marked processed")
	}

	// Once due, it is claimable again.
	if _, err := h.pool.Exec(ctx,
		`UPDATE meetup.notification_outbox SET next_attempt_at = now() - interval '1 second'`); err != nil {
		t.Fatalf("make row due: %v", err)
	}
	due, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(due) != 1 {
		t.Errorf("claimed %d rows once the backoff elapsed, want 1", len(due))
	}
}

// TestOutbox_DeadLetteredRowIsNeverClaimedAgain pins the terminal state: a
// row past its retry ceiling must leave the claimable set permanently, but
// remain in the table as evidence.
func TestOutbox_DeadLetteredRowIsNeverClaimedAgain_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedOutboxRows(t, h, 1)
	claimed, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil || len(claimed) != 1 {
		t.Fatalf("ClaimBatch: %v (%d rows)", err, len(claimed))
	}

	if err := h.outbox.MarkDeadLettered(ctx, claimed[0].ID, "gave up after 10 attempts"); err != nil {
		t.Fatalf("MarkDeadLettered: %v", err)
	}

	again, err := h.outbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("claimed %d dead-lettered rows, want 0", len(again))
	}

	// Kept, not deleted — a permanent delivery failure is something someone
	// should be able to find and investigate.
	if got := h.countOutboxRows(t); got != 1 {
		t.Errorf("outbox rows = %d, want the dead-lettered row to be retained", got)
	}
	row := firstOutboxRow(t, h)
	if row.DeadLetteredAt == nil {
		t.Error("dead_lettered_at was not set")
	}
	if row.LastError == nil || *row.LastError == "" {
		t.Error("last_error was not recorded — a dead-lettered row with no reason is not evidence of anything")
	}
}

// --- §F7: end-to-end through the real poller -------------------------------

// TestPoller_DeliversQueuedNotifications wires the real generic poller to the
// real store with a recording sender, and asserts the whole path: a business
// call queues a row, the poller claims it, the sender receives exactly the
// tokens/title/body/data that were queued, and the row ends up processed.
func TestPoller_DeliversQueuedNotifications_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host Person")
	seedDisplay(t, h, requester, "Requester Person")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register device: %v", err)
	}

	m := createOpenMeetup(t, h, host)
	clearOutbox(t, h) // drop the host's own checklist prompt from creation
	if _, err := h.svc.RequestToJoin(ctx, requestToJoin(m.ID, requester)); err != nil {
		t.Fatalf("RequestToJoin: %v", err)
	}

	recorder := &recordingSender{}
	poller := outbox.New(h.outbox, deliverWith(recorder), outbox.WithLogger(slog.New(slog.DiscardHandler)))
	poller.DrainOnce(ctx)

	sent := recorder.calls()
	if len(sent) != 1 {
		t.Fatalf("sender received %d notifications, want 1", len(sent))
	}
	got := sent[0]
	if len(got.tokens) != 1 || got.tokens[0] != "host-device-token" {
		t.Errorf("tokens = %v, want [host-device-token]", got.tokens)
	}
	if got.title != "New join request" {
		t.Errorf("title = %q, want \"New join request\"", got.title)
	}
	if got.body != fmt.Sprintf("Requester Person wants to join your %s meetup", m.Intent) {
		t.Errorf("body = %q, which does not match the composed copy", got.body)
	}
	if got.data["meetup_id"] != m.ID {
		t.Errorf("data[meetup_id] = %q, want %q", got.data["meetup_id"], m.ID)
	}

	row := firstOutboxRow(t, h)
	if row.ProcessedAt == nil {
		t.Error("the delivered row was not marked processed — it will be delivered again")
	}
}

// TestService_WakesThePollerAfterEveryNotifyingWrite is §F5's guarantee, and
// it caught a real omission: four of the notifying call sites in requests.go
// (join, withdraw, accept, reject) were not calling Wake at all, so every
// join-request notification would have waited for the safety-net tick
// instead of going out immediately.
//
// # WHY THIS ASSERTS ON THE WAKE CALL RATHER THAN ON DELIVERY LATENCY
//
// The obvious version — start a poller with an hour-long tick, do a business
// write, assert something arrives quickly — is not deterministic HERE,
// because integration tests run against a database that may also have a real
// monolith container attached to it. That container's own poller is a
// perfectly valid competing claimer (proving, incidentally, that concurrent
// claiming works), and it will happily take the row before this test's
// poller sees it. The test would then fail for a reason that is not a defect.
//
// So the assertion is on the thing that actually regressed and that this
// code owns: does every notifying business write nudge the poller? The
// mechanism on the other side of that nudge — that a Wake causes a drain,
// with the tick far too long to be responsible — is pinned deterministically
// in internal/platform/outbox's own TestRun_WakeTriggersADrain, with no
// database and no possible competitor.
func TestService_WakesThePollerAfterEveryNotifyingWrite_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	host := newUserID(t, h)
	requester := newUserID(t, h)
	seedDisplay(t, h, host, "Host")
	seedDisplay(t, h, requester, "Requester")
	if err := h.deviceTokens.Upsert(ctx, host, "host-device-token"); err != nil {
		t.Fatalf("register host device: %v", err)
	}
	if err := h.deviceTokens.Upsert(ctx, requester, "requester-device-token"); err != nil {
		t.Fatalf("register requester device: %v", err)
	}

	var mu sync.Mutex
	wakes := 0
	svc := h.serviceWithWake(t, func() {
		mu.Lock()
		defer mu.Unlock()
		wakes++
	})
	countWakes := func() int {
		mu.Lock()
		defer mu.Unlock()
		return wakes
	}

	// CreateMeetup queues the host's own safety-checklist prompt, so it too
	// must nudge the poller.
	m := createOpenMeetupWith(t, h, svc, host)
	if countWakes() == 0 {
		t.Error("CreateMeetup did not wake the notification poller")
	}

	// Each step below queues at least one notification, so each must nudge
	// the poller. Checked one at a time so a failure names the call site.
	steps := []struct {
		name string
		run  func(t *testing.T)
	}{
		{name: "RequestToJoin", run: func(t *testing.T) {
			if _, err := svc.RequestToJoin(ctx, requestToJoin(m.ID, requester)); err != nil {
				t.Fatalf("RequestToJoin: %v", err)
			}
		}},
		{name: "RespondToRequest(accept)", run: func(t *testing.T) {
			reqs, err := h.requests.ListForMeetup(ctx, m.ID)
			if err != nil || len(reqs) == 0 {
				t.Fatalf("list requests: %v (%d)", err, len(reqs))
			}
			if _, err := svc.RespondToRequest(ctx, meetup.RespondToRequestRequest{
				RequestID: reqs[0].ID, HostUserID: host, Accept: true,
			}); err != nil {
				t.Fatalf("RespondToRequest: %v", err)
			}
		}},
		{name: "CancelMeetup", run: func(t *testing.T) {
			if err := svc.CancelMeetup(ctx, meetup.CancelMeetupRequest{
				MeetupID: m.ID, HostUserID: host, Reason: "something came up",
			}); err != nil {
				t.Fatalf("CancelMeetup: %v", err)
			}
		}},
	}

	for _, step := range steps {
		before := countWakes()
		step.run(t)
		if got := countWakes(); got <= before {
			t.Errorf("%s did not wake the notification poller — its notifications would sit queued until the next safety-net tick instead of going out immediately", step.name)
		}
	}
}

// TestPoller_DrainsWithoutAWake covers the safety net from the other side:
// rows that are already queued must be delivered by a poller that is simply
// running, with nobody nudging it. This is what recovers notifications that
// piled up while the process was down.
func TestPoller_DrainsWithoutAWake_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedOutboxRows(t, h, 3)

	recorder := &recordingSender{}
	poller := outbox.New(h.outbox, deliverWith(recorder), outbox.WithLogger(slog.New(slog.DiscardHandler)))

	// No Wake call anywhere.
	poller.DrainOnce(ctx)

	// A real monolith container attached to the same database may have taken
	// some of these first — that is correct behaviour, not a failure — so the
	// assertion is that the pending set is drained, not that this particular
	// sender saw every row.
	var pending int
	if err := h.pool.QueryRow(ctx,
		`SELECT count(*) FROM meetup.notification_outbox WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()`).
		Scan(&pending); err != nil {
		t.Fatalf("count pending: %v", err)
	}
	if pending != 0 {
		t.Errorf("%d rows were still due after a drain — the poller is not claiming without a wake signal", pending)
	}
}

// --- helpers ---------------------------------------------------------------

// seedDisplay populates the user_display_cache row a notification body needs
// (the requester's name). In production this arrives via the auth module's
// user-onboarded event; here it is seeded directly, which is what the rest of
// this package's tests do too.
func seedDisplay(t *testing.T, h *harness, userID, name string) {
	t.Helper()
	if _, err := h.userDisplayCache.Upsert(context.Background(), userID, name, "", 4, time.Now()); err != nil {
		t.Fatalf("seed display cache for %s: %v", userID, err)
	}
}

func createOpenMeetup(t *testing.T, h *harness, host string) meetup.Meetup {
	t.Helper()
	return h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
}

func createOpenMeetupWith(t *testing.T, h *harness, svc meetup.Service, host string) meetup.Meetup {
	t.Helper()
	m, err := svc.CreateMeetup(context.Background(), meetup.CreateMeetupRequest{
		HostUserID:     host,
		HostTrustLevel: 4,
		Intent:         meetup.IntentCoffee,
		WindowStart:    time.Now().Add(time.Hour),
		WindowEnd:      time.Now().Add(3 * time.Hour),
		LocationLat:    colomboLat,
		LocationLng:    colomboLng,
		LocationLabel:  "Test Cafe",
		Capacity:       2,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	return m
}

func requestToJoin(meetupID, requester string) meetup.RequestToJoinRequest {
	return meetup.RequestToJoinRequest{MeetupID: meetupID, RequesterID: requester, RequesterTrustLevel: 4}
}

// deliverWith builds the poller's process function around a sender, the same
// way cmd/monolith does — so these tests exercise the real Delivery logic
// (breaker, partial-success handling, dead-token cleanup) rather than a
// simplified stand-in.
func deliverWith(sender notification.Sender) func(context.Context, outbox.Row) error {
	return notification.NewDelivery(sender, nil, slog.New(slog.DiscardHandler)).Process
}

type outboxRow struct {
	ID             string
	FCMTokens      []string
	Title          string
	Attempts       int
	ProcessedAt    *time.Time
	DeadLetteredAt *time.Time
	LastError      *string
}

func firstOutboxRow(t *testing.T, h *harness) outboxRow {
	t.Helper()
	var row outboxRow
	err := h.pool.QueryRow(context.Background(), `
		SELECT id, fcm_tokens, title, attempts, processed_at, dead_lettered_at, last_error
		FROM meetup.notification_outbox ORDER BY created_at, id LIMIT 1`).
		Scan(&row.ID, &row.FCMTokens, &row.Title, &row.Attempts, &row.ProcessedAt, &row.DeadLetteredAt, &row.LastError)
	if err != nil {
		t.Fatalf("read outbox row: %v", err)
	}
	return row
}

func clearOutbox(t *testing.T, h *harness) {
	t.Helper()
	if _, err := h.pool.Exec(context.Background(), `DELETE FROM meetup.notification_outbox`); err != nil {
		t.Fatalf("clear outbox: %v", err)
	}
}

func seedOutboxRows(t *testing.T, h *harness, n int) {
	t.Helper()
	_, err := h.pool.Exec(context.Background(), `
		INSERT INTO meetup.notification_outbox (fcm_tokens, title, body, data)
		SELECT ARRAY['token-' || g], 'Seeded ' || g, 'body', '{}'::jsonb
		FROM generate_series(1, $1) AS g`, n)
	if err != nil {
		t.Fatalf("seed outbox rows: %v", err)
	}
}

func countRows(t *testing.T, h *harness, table string) int {
	t.Helper()
	var n int
	// table is a compile-time constant from this test file, never caller
	// input — the one place in this repo where an identifier is
	// interpolated, and it cannot carry anything a test author didn't type.
	if err := h.pool.QueryRow(context.Background(), "SELECT count(*) FROM "+table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

type sentNotification struct {
	tokens []string
	title  string
	body   string
	data   map[string]string
}

// recordingSender is a notification.Sender that records instead of sending.
type recordingSender struct {
	mu     sync.Mutex
	sent   []sentNotification
	onSend func()
	fail   error
}

func (s *recordingSender) SendToTokens(_ context.Context, tokens []string, title, body string, data map[string]string) error {
	s.mu.Lock()
	s.sent = append(s.sent, sentNotification{tokens: tokens, title: title, body: body, data: data})
	fail := s.fail
	onSend := s.onSend
	s.mu.Unlock()

	if onSend != nil {
		onSend()
	}
	return fail
}

func (s *recordingSender) calls() []sentNotification {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]sentNotification(nil), s.sent...)
}

// --- §F8: retention --------------------------------------------------------

// TestOutboxRetention_DeletesOnlyRowsPastTheirWindow is §F8's proof, and the
// asymmetry it checks is the point: dead-lettered rows are kept four times
// longer than delivered ones, because a permanent delivery failure is
// evidence someone should still be able to find.
func TestOutboxRetention_DeletesOnlyRowsPastTheirWindow_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	// Seed one row in each of the six meaningful states.
	seed := func(label string, processedAgo, deadLetteredAgo time.Duration) {
		t.Helper()
		var processedAt, deadLetteredAt any
		if processedAgo > 0 {
			processedAt = time.Now().Add(-processedAgo)
		}
		if deadLetteredAgo > 0 {
			deadLetteredAt = time.Now().Add(-deadLetteredAgo)
		}
		_, err := h.pool.Exec(ctx, `
			INSERT INTO meetup.notification_outbox (fcm_tokens, title, body, data, processed_at, dead_lettered_at)
			VALUES (ARRAY['tok'], $1, 'body', '{}'::jsonb, $2, $3)`,
			label, processedAt, deadLetteredAt)
		if err != nil {
			t.Fatalf("seed %s: %v", label, err)
		}
	}

	seed("processed-long-ago", notification.ProcessedRetention+24*time.Hour, 0)      // deleted
	seed("processed-recently", time.Hour, 0)                                         // kept
	seed("dead-lettered-long-ago", 0, notification.DeadLetterRetention+24*time.Hour) // deleted
	seed("dead-lettered-recently", 0, 24*time.Hour)                                  // kept
	// A dead-lettered row older than the PROCESSED window but inside its own,
	// longer window — the exact row a single shared retention period would
	// wrongly delete.
	seed("dead-lettered-past-processed-window", 0, notification.ProcessedRetention+24*time.Hour) // kept
	seedOutboxRows(t, h, 1)                                                                      // pending, kept

	job := notification.NewRetention(h.outbox, slog.New(slog.DiscardHandler))
	processed, deadLettered, err := job.Sweep(ctx)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if processed != 1 {
		t.Errorf("deleted %d processed rows, want 1", processed)
	}
	if deadLettered != 1 {
		t.Errorf("deleted %d dead-lettered rows, want 1", deadLettered)
	}

	remaining := outboxTitleSet(t, h)
	for _, gone := range []string{"processed-long-ago", "dead-lettered-long-ago"} {
		if _, present := remaining[gone]; present {
			t.Errorf("%s survived retention", gone)
		}
	}
	for _, kept := range []string{"processed-recently", "dead-lettered-recently", "dead-lettered-past-processed-window"} {
		if _, present := remaining[kept]; !present {
			t.Errorf("%s was deleted before its retention window elapsed", kept)
		}
	}
	// A row still awaiting delivery must never be touched by retention —
	// deleting one would silently drop a real, undelivered notification.
	if len(remaining) != 4 {
		t.Errorf("remaining rows = %v, want the three in-window rows plus the pending one", remaining)
	}
}

// TestOutboxRetention_IsIdempotentAndBatches covers the loop: a backlog
// larger than one DELETE batch must still be fully drained in one run, and a
// second run with nothing eligible must delete nothing.
func TestOutboxRetention_IsIdempotentAndBatches_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const backlog = 1200 // larger than the 1000-row batch
	_, err := h.pool.Exec(ctx, `
		INSERT INTO meetup.notification_outbox (fcm_tokens, title, body, data, processed_at)
		SELECT ARRAY['tok'], 'old-' || g, 'body', '{}'::jsonb, now() - interval '30 days'
		FROM generate_series(1, $1) AS g`, backlog)
	if err != nil {
		t.Fatalf("seed backlog: %v", err)
	}

	job := notification.NewRetention(h.outbox, slog.New(slog.DiscardHandler))
	processed, _, err := job.Sweep(ctx)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if processed != backlog {
		t.Errorf("deleted %d rows, want %d — a backlog larger than one batch must be drained by looping, not truncated at the batch size", processed, backlog)
	}

	again, _, err := job.Sweep(ctx)
	if err != nil {
		t.Fatalf("second Sweep: %v", err)
	}
	if again != 0 {
		t.Errorf("second sweep deleted %d rows, want 0", again)
	}
}

func outboxTitleSet(t *testing.T, h *harness) map[string]struct{} {
	t.Helper()
	out := map[string]struct{}{}
	for _, title := range h.outboxTitles(t) {
		out[title] = struct{}{}
	}
	return out
}
