package grpcapi

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"

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
