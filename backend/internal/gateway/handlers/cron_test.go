package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

const testCronSecret = "s3cret-cron-value"

type fakeScheduledWorkRunner struct {
	report monolithclient.ScheduledWorkReport
	err    error
	calls  int
	groups []string
	// delay makes the tick slow, like a sweep that takes minutes.
	delay time.Duration
	// deadline is how long the runner's context had left when called.
	deadline time.Duration
}

func (f *fakeScheduledWorkRunner) RunScheduledWork(ctx context.Context, group string) (monolithclient.ScheduledWorkReport, error) {
	f.calls++
	f.groups = append(f.groups, group)
	if d, ok := ctx.Deadline(); ok {
		f.deadline = time.Until(d)
	}
	if f.delay > 0 {
		select {
		case <-time.After(f.delay):
		case <-ctx.Done():
			return monolithclient.ScheduledWorkReport{}, ctx.Err()
		}
	}
	return f.report, f.err
}

func cronTestServer(t *testing.T, runner ScheduledWorkRunner, secret string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	RegisterCron(mux, runner, secret, slog.New(slog.NewTextHandler(io.Discard, nil)))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func postTick(t *testing.T, srv *httptest.Server, secret string) *http.Response {
	t.Helper()
	return postTickTo(t, srv, "/internal/cron/tick", secret)
}

func postTickTo(t *testing.T, srv *httptest.Server, path, secret string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if secret != "" {
		req.Header.Set(cronSecretHeader, secret)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST tick: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// This route runs database writes and is reachable from the public internet
// — Cloud Scheduler calls it over the service's own URL, so it is as exposed
// as /v1 is. Anything without the secret must not reach the monolith.
func TestCronTickRejectsCallersWithoutTheSecret(t *testing.T) {
	for _, tc := range []struct {
		name   string
		secret string
	}{
		{"no header at all", ""},
		{"wrong value", "not-the-secret"},
		{"right length, wrong bytes", "s3cret-cron-valuX"},
		{"prefix of the real secret", "s3cret"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runner := &fakeScheduledWorkRunner{}
			srv := cronTestServer(t, runner, testCronSecret)

			resp := postTick(t, srv, tc.secret)

			if resp.StatusCode != http.StatusNotFound {
				t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusNotFound)
			}
			if runner.calls != 0 {
				t.Errorf("the monolith was called %d times for an "+
					"unauthenticated request, want 0", runner.calls)
			}
		})
	}
}

// An unauthenticated endpoint that runs database writes is worse than no
// endpoint. With no secret configured the route must not exist at all,
// rather than exist and accept everyone.
func TestCronTickIsNotMountedWithoutASecret(t *testing.T) {
	runner := &fakeScheduledWorkRunner{}

	mux := http.NewServeMux()
	mounted := RegisterCron(mux, runner, "", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if mounted {
		t.Error("RegisterCron reported the route mounted with an empty secret")
	}

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	resp := postTick(t, srv, "")
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusNotFound)
	}
	if runner.calls != 0 {
		t.Errorf("the monolith was called %d times, want 0", runner.calls)
	}
}

func TestCronTickRunsTheSweepsAndReportsThem(t *testing.T) {
	runner := &fakeScheduledWorkRunner{
		report: monolithclient.ScheduledWorkReport{
			Results: []monolithclient.SweepOutcome{
				{Name: "lifecycle: starting-soon", Affected: 2},
				{Name: "retention: notifications", Affected: 0},
			},
		},
	}
	srv := cronTestServer(t, runner, testCronSecret)

	resp := postTick(t, srv, testCronSecret)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	if runner.calls != 1 {
		t.Errorf("the monolith was called %d times, want 1", runner.calls)
	}

	var got monolithclient.ScheduledWorkReport
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(got.Results) != 2 || got.Results[0].Affected != 2 {
		t.Errorf("body = %+v, want the runner's two results", got)
	}
}

// Cloud Scheduler decides whether to retry from the status code alone, so a
// tick where a sweep failed has to be non-2xx. A 200 here would mean a
// permanently broken sweep is never retried and never alerted on — the same
// silence that let 27 failed backups go unnoticed.
func TestCronTickIsAFailureWhenASweepFailed(t *testing.T) {
	runner := &fakeScheduledWorkRunner{
		report: monolithclient.ScheduledWorkReport{
			Results: []monolithclient.SweepOutcome{
				{Name: "ok", Affected: 1},
				{Name: "broken", Error: "fcm unreachable"},
			},
			Failed: 1,
		},
	}
	srv := cronTestServer(t, runner, testCronSecret)

	resp := postTick(t, srv, testCronSecret)

	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusInternalServerError)
	}
}

func TestCronTickReports503WhenTheMonolithIsUnreachable(t *testing.T) {
	runner := &fakeScheduledWorkRunner{err: errors.New("connection refused")}
	srv := cronTestServer(t, runner, testCronSecret)

	resp := postTick(t, srv, testCronSecret)

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}

	// The reason must not carry the underlying error: this endpoint is
	// reachable from the internet and the gRPC error names internal hosts
	// and ports.
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if strings.Contains(string(body), "connection refused") {
		t.Errorf("the response leaks the underlying error: %s", body)
	}
}

// GET must not drive the sweeps: a crawler, a link preview or a browser
// address bar would otherwise start database writes.
func TestCronTickRejectsGet(t *testing.T) {
	runner := &fakeScheduledWorkRunner{}
	srv := cronTestServer(t, runner, testCronSecret)

	req, err := http.NewRequest(http.MethodGet, srv.URL+"/internal/cron/tick", nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set(cronSecretHeader, testCronSecret)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET tick: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusOK {
		t.Error("GET was accepted")
	}
	if runner.calls != 0 {
		t.Errorf("the monolith was called %d times for a GET, want 0", runner.calls)
	}
}

// Tracker #102: the server's WriteTimeout (30s in cmd/gateway) is far
// shorter than a tick, so without its own write deadline the tick's report
// could never be written: Scheduler saw a dropped connection and retried
// the whole tick. Here the server allows 100ms and the tick takes 300ms.
func TestCronTickOutlivesTheServerWriteTimeout(t *testing.T) {
	runner := &fakeScheduledWorkRunner{
		delay:  300 * time.Millisecond,
		report: monolithclient.ScheduledWorkReport{Results: []monolithclient.SweepOutcome{{Name: "slow", Affected: 1}}},
	}
	mux := http.NewServeMux()
	RegisterCron(mux, runner, testCronSecret, slog.New(slog.NewTextHandler(io.Discard, nil)))
	srv := httptest.NewUnstartedServer(mux)
	srv.Config.WriteTimeout = 100 * time.Millisecond
	srv.Start()
	t.Cleanup(srv.Close)

	resp := postTick(t, srv, testCronSecret)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want 200", resp.StatusCode)
	}
	var report monolithclient.ScheduledWorkReport
	if err := json.NewDecoder(resp.Body).Decode(&report); err != nil {
		t.Fatalf("the report did not arrive: %v", err)
	}
	if len(report.Results) != 1 {
		t.Errorf("report %+v", report)
	}
}

// Each route runs its own group within its own total, and both totals sit
// under the Cloud Scheduler attempt deadlines in runbook §10 (300s core,
// 540s analytics) and Cloud Run's 600s request timeout (service.yaml).
func TestCronTicksRunTheirOwnGroupWithinTheirOwnDeadline(t *testing.T) {
	for _, tc := range []struct {
		path, group string
		total       time.Duration
	}{
		{"/internal/cron/tick", "", coreTickTimeout},
		{"/internal/cron/tick/analytics", "analytics", analyticsTickTimeout},
	} {
		runner := &fakeScheduledWorkRunner{}
		srv := cronTestServer(t, runner, testCronSecret)
		resp := postTickTo(t, srv, tc.path, testCronSecret)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: status %d", tc.path, resp.StatusCode)
		}
		if len(runner.groups) != 1 || runner.groups[0] != tc.group {
			t.Errorf("%s ran groups %q, want %q", tc.path, runner.groups, tc.group)
		}
		if runner.deadline > tc.total || runner.deadline < tc.total-time.Second {
			t.Errorf("%s gave the monolith %v, want about %v", tc.path, runner.deadline, tc.total)
		}
	}
	if coreTickTimeout > 300*time.Second-30*time.Second {
		t.Errorf("the core tick (%v) does not leave room under Scheduler's 300s attempt deadline", coreTickTimeout)
	}
	if analyticsTickTimeout > 540*time.Second-30*time.Second {
		t.Errorf("the analytics tick (%v) does not leave room under Scheduler's 540s attempt deadline", analyticsTickTimeout)
	}
}

// The analytics route is guarded by the same secret.
func TestCronAnalyticsTickRejectsCallersWithoutTheSecret(t *testing.T) {
	runner := &fakeScheduledWorkRunner{}
	srv := cronTestServer(t, runner, testCronSecret)
	resp := postTickTo(t, srv, "/internal/cron/tick/analytics", "wrong")
	if resp.StatusCode != http.StatusNotFound || runner.calls != 0 {
		t.Errorf("status %d, %d calls", resp.StatusCode, runner.calls)
	}
}
