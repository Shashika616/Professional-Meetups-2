package meetup_test

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/eventbus"
	"professional-meetups-monolith/backend/internal/modules/meetup"
	meetuprepo "professional-meetups-monolith/backend/internal/modules/meetup/repository"
	"professional-meetups-monolith/backend/internal/platform/outbox"
)

// The meetups_completed_outbox — the async half of the profile "MEETUPS"
// figure (docs/plans/06-async-meetups-completed-recompute.md).
//
// Coverage deliberately mirrors outbox_integration_test.go's, because the
// Store implementation deliberately mirrors the notification outbox's: the
// same claim strategy earns the same proof, rather than being assumed to
// work because it was copied.

// seedCompletedOutboxRows writes n rows directly, bypassing the close path —
// these tests are about the Store, not about what produces its rows.
func seedCompletedOutboxRows(t *testing.T, h *harness, n int) {
	t.Helper()
	ctx := context.Background()
	for i := 0; i < n; i++ {
		if _, err := h.pool.Exec(ctx, `
			INSERT INTO meetup.meetups_completed_outbox (meetup_ids)
			VALUES (ARRAY[gen_random_uuid()])`); err != nil {
			t.Fatalf("seed outbox row %d: %v", i, err)
		}
	}
}

// TestMeetupsCompletedClaimBatch_ConcurrentClaimersNeverOverlap is the
// FOR UPDATE SKIP LOCKED + visibility-timeout guarantee for this second
// table.
//
// It matters less here than for notifications — a duplicate recompute is a
// complete no-op rather than a duplicate push — but a claim strategy that
// overlaps would still mean N claimers each running the expensive recompute
// over the same meetups, which is precisely the load this whole plan exists
// to avoid.
func TestMeetupsCompletedClaimBatch_ConcurrentClaimersNeverOverlap_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	const total = 60
	seedCompletedOutboxRows(t, h, total)

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
				rows, err := h.completedOutbox.ClaimBatch(ctx, 7)
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

				for _, r := range rows {
					if err := h.completedOutbox.MarkProcessed(ctx, r.ID); err != nil {
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
	for id, n := range seen {
		if n > 1 {
			t.Errorf("row %s was claimed %d times by concurrent claimers — SKIP LOCKED plus the visibility timeout are not preventing overlap", id, n)
		}
	}

	var stillDue int
	if err := h.pool.QueryRow(ctx, `
		SELECT count(*) FROM meetup.meetups_completed_outbox
		WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()`).
		Scan(&stillDue); err != nil {
		t.Fatalf("count still-due rows: %v", err)
	}
	if stillDue != 0 {
		t.Errorf("%d rows were left due after every claimer stopped — concurrent claiming dropped work", stillDue)
	}
}

// TestMeetupsCompletedStore_MarkTransitions covers the three terminal/retry
// writes and the pending gauge.
func TestMeetupsCompletedStore_MarkTransitions_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedCompletedOutboxRows(t, h, 3)
	if got := h.pendingCompletedRows(t, ctx); got != 3 {
		t.Fatalf("pending = %d, want 3", got)
	}

	rows, err := h.completedOutbox.ClaimBatch(ctx, 3)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("claimed %d rows, want 3", len(rows))
	}
	for _, r := range rows {
		if r.Attempts != 1 {
			t.Errorf("attempts = %d after one claim, want 1 — attempts must be incremented at claim time so a row that crashes its claimer still counts against the ceiling", r.Attempts)
		}
	}

	// Processed and dead-lettered both leave the pending set; failed does
	// not, by construction (processed_at untouched).
	if err := h.completedOutbox.MarkProcessed(ctx, rows[0].ID); err != nil {
		t.Fatalf("MarkProcessed: %v", err)
	}
	if err := h.completedOutbox.MarkDeadLettered(ctx, rows[1].ID, "hopeless"); err != nil {
		t.Fatalf("MarkDeadLettered: %v", err)
	}
	if err := h.completedOutbox.MarkFailed(ctx, rows[2].ID, time.Now().Add(time.Hour), "transient"); err != nil {
		t.Fatalf("MarkFailed: %v", err)
	}

	if got := h.pendingCompletedRows(t, ctx); got != 1 {
		t.Errorf("pending = %d, want 1 (only the failed row is still pending)", got)
	}

	// The failed row backed off, so it is not immediately reclaimable.
	again, err := h.completedOutbox.ClaimBatch(ctx, 10)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if len(again) != 0 {
		t.Errorf("claimed %d rows, want 0 — a failed row must respect its backoff deadline", len(again))
	}
}

// TestMeetupsCompletedStore_RetentionDeletesTerminalRows covers the halves
// the shared Retention job drives. The job itself is unchanged and already
// took a store rather than a table name, which is why this table needed a
// second instance and no new logic.
func TestMeetupsCompletedStore_RetentionDeletesTerminalRows_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	seedCompletedOutboxRows(t, h, 2)
	rows, err := h.completedOutbox.ClaimBatch(ctx, 2)
	if err != nil {
		t.Fatalf("ClaimBatch: %v", err)
	}
	if err := h.completedOutbox.MarkProcessed(ctx, rows[0].ID); err != nil {
		t.Fatalf("MarkProcessed: %v", err)
	}
	if err := h.completedOutbox.MarkDeadLettered(ctx, rows[1].ID, "hopeless"); err != nil {
		t.Fatalf("MarkDeadLettered: %v", err)
	}

	// Age both terminal rows past every retention window.
	if _, err := h.pool.Exec(ctx, `
		UPDATE meetup.meetups_completed_outbox
		SET processed_at = processed_at - interval '60 days',
		    dead_lettered_at = dead_lettered_at - interval '60 days'`); err != nil {
		t.Fatalf("age rows: %v", err)
	}

	deleted, err := h.completedOutbox.DeleteProcessedOlderThan(ctx, 7*24*time.Hour, 100)
	if err != nil {
		t.Fatalf("DeleteProcessedOlderThan: %v", err)
	}
	if deleted != 1 {
		t.Errorf("deleted %d processed rows, want 1", deleted)
	}

	deleted, err = h.completedOutbox.DeleteDeadLetteredOlderThan(ctx, 30*24*time.Hour, 100)
	if err != nil {
		t.Fatalf("DeleteDeadLetteredOlderThan: %v", err)
	}
	if deleted != 1 {
		t.Errorf("deleted %d dead-lettered rows, want 1", deleted)
	}
}

// --- the handler -----------------------------------------------------------

// TestCompletedRecompute_PublishesForEveryParticipant drives the poller's
// process function directly, over a row naming two real completed meetups.
func TestCompletedRecompute_PublishesForEveryParticipant_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	first := closeAMeetup(t, h, host)
	second := closeAMeetup(t, h, host)

	// No reset needed: closing publishes nothing on this topic any more —
	// it only schedules. Anything seen below came from Process.
	payload, err := json.Marshal(meetuprepo.MeetupsCompletedPayload{
		MeetupIDs: []string{first, second},
	})
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	processor := meetup.NewCompletedRecompute(h.completedOutbox, h.bus, slog.New(slog.DiscardHandler))
	if err := processor.Process(ctx, outbox.Row{ID: "row-1", Payload: payload}); err != nil {
		t.Fatalf("Process: %v", err)
	}

	published := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated)
	if len(published) != 1 {
		t.Fatalf("published %d events, want 1 (one host, de-duplicated across both meetups)", len(published))
	}
	event := published[0].(eventbus.MeetupsCompletedUpdatedPayload)
	if event.UserID != host {
		t.Errorf("event user = %q, want the host %q", event.UserID, host)
	}
	if event.MeetupsCompleted != 2 {
		t.Errorf("count = %d, want 2 — the recompute must derive the total from both meetups, not one event each", event.MeetupsCompleted)
	}
}

// TestCompletedRecompute_UndecodablePayloadIsPermanent proves a structurally
// broken row is dead-lettered on the first attempt rather than burning its
// whole retry budget on something that can never parse.
func TestCompletedRecompute_UndecodablePayloadIsPermanent_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	processor := meetup.NewCompletedRecompute(h.completedOutbox, h.bus, slog.New(slog.DiscardHandler))
	err := processor.Process(ctx, outbox.Row{ID: "row-1", Payload: []byte(`{not json`)})
	if err == nil {
		t.Fatal("Process accepted an undecodable payload")
	}
	if !errors.Is(err, outbox.ErrPermanent) {
		t.Errorf("error = %v, want one wrapping outbox.ErrPermanent so the poller dead-letters it immediately", err)
	}
}

// TestCompletedRecompute_InvalidMeetupIDIsPermanent — same reasoning one
// level down: an id that cannot be parsed will never parse.
func TestCompletedRecompute_InvalidMeetupIDIsPermanent_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	payload, err := json.Marshal(meetuprepo.MeetupsCompletedPayload{MeetupIDs: []string{"not-a-uuid"}})
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	processor := meetup.NewCompletedRecompute(h.completedOutbox, h.bus, slog.New(slog.DiscardHandler))
	processErr := processor.Process(ctx, outbox.Row{ID: "row-1", Payload: payload})
	if processErr == nil {
		t.Fatal("Process accepted an unparseable meetup id")
	}
	if !errors.Is(processErr, outbox.ErrPermanent) {
		t.Errorf("error = %v, want one wrapping outbox.ErrPermanent", processErr)
	}
	if got := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated); len(got) != 0 {
		t.Errorf("published %d events despite failing, want 0", len(got))
	}
}

// TestCompletedRecompute_EmptyPayloadSucceeds — nothing to do is success, not
// a failure to retry ten times and dead-letter.
func TestCompletedRecompute_EmptyPayloadSucceeds_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()

	payload, err := json.Marshal(meetuprepo.MeetupsCompletedPayload{})
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	processor := meetup.NewCompletedRecompute(h.completedOutbox, h.bus, slog.New(slog.DiscardHandler))
	if err := processor.Process(ctx, outbox.Row{ID: "row-1", Payload: payload}); err != nil {
		t.Errorf("Process on an empty payload = %v, want nil", err)
	}
}

// --- the handoff -----------------------------------------------------------

// TestCloseMeetup_SchedulesRecomputeWithoutRunningIt is THE test for this
// plan: it proves the two halves are actually connected, which neither half's
// own tests can.
//
// It asserts the whole sequence — close writes an outbox row naming the right
// meetup, the profile cache is NOT yet updated, the poller runs, and only
// then is it updated.
func TestCloseMeetup_SchedulesRecomputeWithoutRunningIt_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	closedID := closeAMeetup(t, h, host)

	// 1. The intent is durable, and names the right meetup.
	if got := h.pendingCompletedRows(t, ctx); got != 1 {
		t.Fatalf("pending outbox rows = %d, want 1 — the close must schedule the recompute", got)
	}
	ids := h.completedOutboxMeetupIDs(t, ctx)
	if len(ids) != 1 || ids[0] != closedID {
		t.Errorf("outbox row names %v, want exactly [%s]", ids, closedID)
	}

	// 2. The expensive work has NOT happened yet — that is the entire point
	//    of the change, so it is asserted rather than assumed.
	if got := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated); len(got) != 0 {
		t.Errorf("close published %d events itself, want 0", len(got))
	}

	// 3. The close DID nudge the poller. A poller built but never woken was
	//    a real self-found bug in the original notification outbox work, so
	//    this is checked explicitly at the call site rather than assumed
	//    from the wiring.
	if got := h.completedWakes.Load(); got != 1 {
		t.Errorf("CloseMeetup woke the recompute poller %d times, want 1 — without the wake the profile figure waits for the safety-net tick", got)
	}

	// 4. One poller pass does the work.
	h.drainCompletedOutbox(t, ctx)

	if got := h.pendingCompletedRows(t, ctx); got != 0 {
		t.Errorf("pending outbox rows = %d after a drain, want 0", got)
	}
	published := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated)
	if len(published) != 1 {
		t.Fatalf("poller published %d events, want 1", len(published))
	}
	event := published[0].(eventbus.MeetupsCompletedUpdatedPayload)
	if event.UserID != host || event.MeetupsCompleted != 1 {
		t.Errorf("event = %+v, want the host at 1", event)
	}
}

// TestAutoCloseSweep_SchedulesOneRowForTheWholeBatchAndWakes covers the other
// completion path. The sweep closes many meetups in one transaction, so it
// must produce ONE row naming all of them (not one per meetup) and wake once.
func TestAutoCloseSweep_SchedulesOneRowForTheWholeBatchAndWakes_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	// Three meetups whose windows have elapsed, left open for the sweep.
	// Created with a valid future window and then backdated directly, the way
	// TestAutoCloseSweep does — CreateMeetup deliberately refuses a
	// window_start in the past beyond its short grace period, so an
	// already-ended meetup can only be set up by writing the row.
	var want []string
	for i := 0; i < 3; i++ {
		m := h.createMeetup(t, host, meetup.IntentCoffee, colomboLat, colomboLng)
		if _, err := h.pool.Exec(ctx,
			`UPDATE meetup.meetups SET window_start = now() - interval '3 hours', window_end = now() - interval '1 hour' WHERE id = $1`,
			m.ID); err != nil {
			t.Fatalf("backdate meetup: %v", err)
		}
		want = append(want, m.ID)
	}

	closed, err := h.svc.AutoCloseSweep(ctx)
	if err != nil {
		t.Fatalf("AutoCloseSweep: %v", err)
	}
	if closed != 3 {
		t.Fatalf("swept %d meetups, want 3", closed)
	}

	if got := h.pendingCompletedRows(t, ctx); got != 1 {
		t.Errorf("pending outbox rows = %d, want 1 — the sweep's whole batch belongs on ONE row, or a shared participant is recounted once per meetup", got)
	}
	got := h.completedOutboxMeetupIDs(t, ctx)
	if len(got) != len(want) {
		t.Fatalf("outbox row names %d meetups, want %d", len(got), len(want))
	}
	for _, id := range want {
		if !contains(got, id) {
			t.Errorf("outbox row is missing meetup %s: %v", id, got)
		}
	}

	if wakes := h.completedWakes.Load(); wakes != 1 {
		t.Errorf("the sweep woke the recompute poller %d times, want 1", wakes)
	}

	h.drainCompletedOutbox(t, ctx)
	published := h.bus.payloadsOf(eventbus.TopicMeetupsCompletedUpdated)
	if len(published) != 1 {
		t.Fatalf("poller published %d events, want 1 (one host across all three)", len(published))
	}
	event := published[0].(eventbus.MeetupsCompletedUpdatedPayload)
	if event.MeetupsCompleted != 3 {
		t.Errorf("count = %d, want 3", event.MeetupsCompleted)
	}
}

// TestStartingSoonSweep_SchedulesNoRecompute — the starting-soon sweep shares
// claimSweep with auto-close but completes nothing, so it must neither write
// a row nor wake the poller. Without the `completes` guard it would schedule
// a guaranteed-empty recompute on every reminder tick.
func TestStartingSoonSweep_SchedulesNoRecompute_Integration(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	host := newUserID(t, h)

	if _, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(30 * time.Minute), WindowEnd: time.Now().Add(90 * time.Minute),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
	}); err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}

	if _, err := h.svc.NotifyStartingSoonSweep(ctx); err != nil {
		t.Fatalf("NotifyStartingSoonSweep: %v", err)
	}

	if got := h.pendingCompletedRows(t, ctx); got != 0 {
		t.Errorf("the starting-soon sweep scheduled %d recomputes, want 0 — it completes nothing", got)
	}
	if got := h.completedWakes.Load(); got != 0 {
		t.Errorf("the starting-soon sweep woke the recompute poller %d times, want 0", got)
	}
}

// closeAMeetup creates a meetup whose window has started and closes it,
// returning its id.
func closeAMeetup(t *testing.T, h *harness, host string) string {
	t.Helper()
	ctx := context.Background()
	m, err := h.svc.CreateMeetup(ctx, meetup.CreateMeetupRequest{
		HostUserID: host, HostTrustLevel: 4, Intent: meetup.IntentCoffee,
		WindowStart: time.Now().Add(-time.Minute), WindowEnd: time.Now().Add(time.Hour),
		LocationLat: colomboLat, LocationLng: colomboLng, LocationLabel: "Cafe", Capacity: 2,
	})
	if err != nil {
		t.Fatalf("CreateMeetup: %v", err)
	}
	if _, err := h.svc.CloseMeetup(ctx, meetup.CloseMeetupRequest{MeetupID: m.ID, HostUserID: host}); err != nil {
		t.Fatalf("CloseMeetup: %v", err)
	}
	return m.ID
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
