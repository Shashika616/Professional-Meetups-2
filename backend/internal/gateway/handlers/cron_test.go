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

	"professional-meetups-monolith/backend/internal/gateway/monolithclient"
)

const testCronSecret = "s3cret-cron-value"

type fakeScheduledWorkRunner struct {
	report monolithclient.ScheduledWorkReport
	err    error
	calls  int
}

func (f *fakeScheduledWorkRunner) RunScheduledWork(context.Context) (monolithclient.ScheduledWorkReport, error) {
	f.calls++
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
	req, err := http.NewRequest(http.MethodPost, srv.URL+"/internal/cron/tick", nil)
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
