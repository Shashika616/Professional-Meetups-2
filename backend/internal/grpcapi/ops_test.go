package grpcapi

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	opsv1 "professional-meetups-monolith/backend/internal/proto/ops/v1"
)

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// The whole reason this RPC exists is that the service scales to zero and
// something outside it has to drive every sweep. "Every" is the load-bearing
// word: a tick that silently skipped one would leave that sweep's table to
// grow without bound, and in the account-deletion purge's case miss a legal
// deadline.
func TestRunScheduledWorkRunsEverySweepInOrder(t *testing.T) {
	var ran []string
	sweep := func(name string, affected int64) Sweep {
		return Sweep{Name: name, Run: func(context.Context) (int64, error) {
			ran = append(ran, name)
			return affected, nil
		}}
	}

	server := NewOpsServer(quietLogger(),
		sweep("first", 3),
		sweep("second", 0),
		sweep("third", 7),
	)

	resp, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{})
	if err != nil {
		t.Fatalf("RunScheduledWork: %v", err)
	}

	want := []string{"first", "second", "third"}
	if len(ran) != len(want) {
		t.Fatalf("ran %v, want %v", ran, want)
	}
	for i := range want {
		if ran[i] != want[i] {
			t.Errorf("sweep %d ran %q, want %q.\n"+
				"Order is load-bearing: the refresh-token sweep must run "+
				"before the abandoned-guest sweep.", i, ran[i], want[i])
		}
	}

	if resp.GetFailed() != 0 {
		t.Errorf("failed = %d, want 0", resp.GetFailed())
	}
	if got := len(resp.GetResults()); got != 3 {
		t.Fatalf("got %d results, want 3", got)
	}
	if got := resp.GetResults()[2].GetAffected(); got != 7 {
		t.Errorf("third sweep reported %d affected, want 7", got)
	}
}

// One broken sweep must not become eleven skipped ones. The sweeps are
// unrelated to each other — an outbox that cannot reach FCM has no bearing
// on whether expired refresh tokens get deleted.
func TestRunScheduledWorkContinuesAfterASweepFails(t *testing.T) {
	ranLast := false
	server := NewOpsServer(quietLogger(),
		Sweep{Name: "ok", Run: func(context.Context) (int64, error) { return 1, nil }},
		Sweep{Name: "broken", Run: func(context.Context) (int64, error) {
			return 0, errors.New("fcm unreachable")
		}},
		Sweep{Name: "last", Run: func(context.Context) (int64, error) {
			ranLast = true
			return 2, nil
		}},
	)

	resp, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{})
	if err != nil {
		t.Fatalf("RunScheduledWork returned an error for a failing SWEEP: %v.\n"+
			"The error return means the tick could not be run at all; a "+
			"sweep that failed belongs in the response.", err)
	}
	if !ranLast {
		t.Error("the sweep after the failing one did not run")
	}
	if resp.GetFailed() != 1 {
		t.Errorf("failed = %d, want 1", resp.GetFailed())
	}

	results := resp.GetResults()
	if len(results) != 3 {
		t.Fatalf("got %d results, want 3", len(results))
	}
	if results[1].GetError() == "" {
		t.Error("the failing sweep's result carries no error text")
	}
	if results[0].GetError() != "" || results[2].GetError() != "" {
		t.Error("a succeeding sweep's result carries error text")
	}
}

// A tick whose caller has gone away should stop rather than keep holding
// database connections for a result nobody will read.
func TestRunScheduledWorkStopsWhenTheCallerGoesAway(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	ran := 0
	count := func(context.Context) (int64, error) {
		ran++
		return 0, nil
	}

	server := NewOpsServer(quietLogger(),
		Sweep{Name: "first", Run: func(c context.Context) (int64, error) {
			ran++
			cancel() // the caller hangs up while the first sweep is running
			return 0, nil
		}},
		Sweep{Name: "second", Run: count},
		Sweep{Name: "third", Run: count},
	)

	if _, err := server.RunScheduledWork(ctx, &opsv1.RunScheduledWorkRequest{}); err != nil {
		t.Fatalf("RunScheduledWork: %v", err)
	}
	if ran != 1 {
		t.Errorf("%d sweeps ran after the caller went away, want 1", ran)
	}
}

// Tracker #102: a sweep's own budget, not one fixed cap for all. The
// analytics aggregation is allowed 120s of statements; a 30s cap on its
// sweep cut it off.
func TestRunScheduledWorkGivesEachSweepItsOwnBudget(t *testing.T) {
	budgets := map[string]time.Duration{}
	record := func(name string) func(context.Context) (int64, error) {
		return func(ctx context.Context) (int64, error) {
			deadline, ok := ctx.Deadline()
			if !ok {
				t.Errorf("%s ran without a deadline", name)
			}
			budgets[name] = time.Until(deadline)
			return 0, nil
		}
	}
	server := NewOpsServer(quietLogger(),
		Sweep{Name: "default", Run: record("default")},
		Sweep{Name: "long", Run: record("long"), Budget: 2 * time.Minute},
	)
	if _, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{}); err != nil {
		t.Fatal(err)
	}
	if got := budgets["default"]; got > DefaultSweepBudget || got < DefaultSweepBudget-time.Second {
		t.Errorf("a sweep without a budget got %v, want about %v", got, DefaultSweepBudget)
	}
	if got := budgets["long"]; got < 2*time.Minute-time.Second {
		t.Errorf("a sweep with a 2m budget got %v", got)
	}
}

// Tracker #102: the tick must answer before the caller's deadline, however
// long the sweeps are allowed, so Cloud Scheduler sees our report (naming
// what was cut short) rather than its own timeout. A slow sweep is cut at
// the deadline less the reply margin, and the sweeps after it are reported
// as skipped, which counts as a failure so the tick is retried.
func TestRunScheduledWorkAnswersBeforeTheCallersDeadline(t *testing.T) {
	defer func(m time.Duration) { replyMargin = m }(replyMargin)
	replyMargin = 50 * time.Millisecond

	ranAfter := false
	server := NewOpsServer(quietLogger(),
		Sweep{Name: "slow", Budget: time.Hour, Run: func(ctx context.Context) (int64, error) {
			<-ctx.Done() // a wedged query: runs until its context ends
			return 0, ctx.Err()
		}},
		Sweep{Name: "after", Run: func(context.Context) (int64, error) {
			ranAfter = true
			return 0, nil
		}},
	)

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	deadline, _ := ctx.Deadline()
	resp, err := server.RunScheduledWork(ctx, &opsv1.RunScheduledWorkRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if left := time.Until(deadline); left < 20*time.Millisecond {
		t.Errorf("answered %v before the caller's deadline; the reply would not arrive in time", left)
	}
	if ranAfter {
		t.Error("a sweep started with no time left")
	}
	if resp.GetFailed() != 2 {
		t.Errorf("failed = %d, want 2 (the cut sweep and the skipped one)", resp.GetFailed())
	}
	if got := len(resp.GetResults()); got != 2 {
		t.Fatalf("got %d results, want 2: a skipped sweep must still be reported", got)
	}
	if e := resp.GetResults()[1].GetError(); !strings.Contains(e, "skipped") {
		t.Errorf("the skipped sweep reports %q", e)
	}
}

// Tracker #102: the heavy analytics sweeps have their own group, run by
// their own Scheduler job.
func TestRunScheduledWorkRunsOnlyTheRequestedGroup(t *testing.T) {
	var ran []string
	sweep := func(name, group string) Sweep {
		return Sweep{Name: name, Group: group, Run: func(context.Context) (int64, error) {
			ran = append(ran, name)
			return 0, nil
		}}
	}
	server := NewOpsServer(quietLogger(),
		sweep("core one", GroupCore),
		sweep("aggregate", GroupAnalytics),
		sweep("core two", GroupCore),
	)

	if _, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(ran, ",") != "core one,core two" {
		t.Errorf("the core tick ran %v", ran)
	}

	ran = nil
	if _, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{Group: GroupAnalytics}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(ran, ",") != "aggregate" {
		t.Errorf("the analytics tick ran %v", ran)
	}

	ran = nil
	if _, err := server.RunScheduledWork(context.Background(), &opsv1.RunScheduledWorkRequest{Group: "nope"}); err == nil {
		t.Error("an unknown group was accepted")
	}
	if len(ran) != 0 {
		t.Errorf("an unknown group ran %v", ran)
	}
}
