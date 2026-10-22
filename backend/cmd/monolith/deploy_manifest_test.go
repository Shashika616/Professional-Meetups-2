package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This project must stay inside Cloud Run's always-free tier (Shashika,
// 2026-10-22). Two annotations can leave it, and both have been set in this
// repository before, so this test pins them.
//
//   - minScale "1" reserves an instance that bills continuously, whether or
//     not anybody is using the app.
//   - cpu-throttling "false" bills that instance's CPU at the
//     always-allocated rate rather than only while a request is in flight.
//
// Together, for this service's 2 vCPU / 1.5 GiB container pair, that is
// 2 x 2.59M vCPU-seconds a month against a free allowance of 180,000 —
// roughly US$120-130/mo. They were set on 2026-10-21 for tracker #77 and
// reverted on 2026-10-22.
//
// #77's concern was real and is not solved by reverting: the monolith runs
// background loops (the notification outbox poller, the lifecycle poller,
// the user-deleted purge, the retention sweeps) that do not tick at minScale
// 0. The driver for those is now Cloud Scheduler calling
// POST /internal/cron/tick — see TestCronTickRunsEverySweep and §10 of the
// runbook. If that endpoint is ever removed, this test is not the one that
// should start passing again.
//
// It reads the manifests as text rather than parsing YAML on purpose. The
// thing that regresses is a line being edited back in, and a literal check
// needs no dependency and names the exact string in the failure.
func TestDeployManifestsStayInsideTheFreeTier(t *testing.T) {
	const (
		billedMinScale     = `autoscaling.knative.dev/minScale: "1"`
		billedNoThrottling = `run.googleapis.com/cpu-throttling: "false"`
		freeMinScale       = `autoscaling.knative.dev/minScale: "0"`
	)

	// Repository root, from backend/cmd/monolith.
	root := filepath.Join("..", "..", "..")
	for _, manifest := range []string{
		filepath.Join(root, "backend", "service.yaml"),
		filepath.Join(root, "docs", "deploy", "service.yaml.template"),
	} {
		body, err := os.ReadFile(manifest)
		if err != nil {
			t.Fatalf("read %s: %v", manifest, err)
		}
		text := string(body)

		// Comments in these files quote both strings while explaining why
		// they are not set, so look only at lines that are not comments.
		for _, line := range strings.Split(text, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			if strings.Contains(line, billedMinScale) {
				t.Errorf("%s sets %s.\n"+
					"That reserves an always-on instance and leaves the free "+
					"tier. Background work is driven by Cloud Scheduler "+
					"(POST /internal/cron/tick), not by a reserved instance.",
					manifest, billedMinScale)
			}
			if strings.Contains(line, billedNoThrottling) {
				t.Errorf("%s sets %s.\n"+
					"That bills CPU for the whole life of the instance "+
					"rather than per request, and leaves the free tier.",
					manifest, billedNoThrottling)
			}
		}

		if !strings.Contains(text, freeMinScale) {
			t.Errorf("%s does not set %s.\n"+
				"Leaving minScale unset inherits Cloud Run's default of 0, "+
				"which is the value we want — but state it, so a future "+
				"edit has to argue with this line rather than add one.",
				manifest, freeMinScale)
		}
	}
}

// Three settings in the live manifest fail SILENTLY if they are dropped,
// which is why they are pinned here rather than left to review:
//
//   - CRON_SHARED_SECRET on the gateway. Without it /internal/cron/tick is
//     not mounted, and since the service scales to zero, no periodic work
//     runs at all — reminders, auto-close, outbox retries, retention.
//   - TRUSTED_PROXY_HOPS "1" on the gateway. Without it the rate limiter
//     keys every user on Cloud Run's proxy: one shared bucket per route for
//     the whole user base (#81).
//   - PUBLIC_BASE_URL on the monolith, pointing at the service. Without it
//     every trusted-contact invitation texts a localhost link (#80).
func TestServiceManifestKeepsTheSilentFailureSettings(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "service.yaml"))
	if err != nil {
		t.Fatalf("read service.yaml: %v", err)
	}
	text := string(body)

	// Split on the container boundary so each check looks only at the
	// container that must carry the setting.
	monolithAt := strings.Index(text, "- name: monolith\n")
	if monolithAt < 0 {
		t.Fatal("service.yaml has no monolith container")
	}
	gateway, monolith := text[:monolithAt], text[monolithAt:]

	for _, want := range []string{
		"- name: CRON_SHARED_SECRET",
		"secretKeyRef: { name: cron-shared-secret, key: latest }",
		"- name: TRUSTED_PROXY_HOPS\n          value: \"1\"",
	} {
		if !strings.Contains(gateway, want) {
			t.Errorf("the gateway container is missing %q", want)
		}
	}

	if !strings.Contains(monolith, "- name: PUBLIC_BASE_URL\n          value: \"https://") {
		t.Error("the monolith container has no https PUBLIC_BASE_URL")
	}
	if strings.Contains(monolith, "value: \"http://localhost") {
		t.Error("the monolith container points a URL at localhost")
	}
}

// Every periodic sweep must be on the scheduled tick's list as well as on
// its in-process ticker: at minScale 0 the ticker rarely runs, and the tick
// is what does the work. The contact-invitation trim was once added to the
// ticker alone.
func TestScheduledTickRunsEveryAuthSweep(t *testing.T) {
	main, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	sweeper, err := os.ReadFile(filepath.Join("..", "..", "internal", "modules", "auth", "sweeper.go"))
	if err != nil {
		t.Fatal(err)
	}
	// Each method the auth ticker calls: s.svc.SweepXxx(ctx).
	for _, line := range strings.Split(string(sweeper), "\n") {
		i := strings.Index(line, "s.svc.Sweep")
		if i < 0 {
			continue
		}
		name := line[i+len("s.svc."):]
		name = name[:strings.IndexByte(name, '(')]
		if !strings.Contains(string(main), "authService."+name+")") {
			t.Errorf("the auth ticker runs %s, but the scheduled tick does not", name)
		}
	}
}
