package main

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// deployManifest is one manifest the deploy checks run against.
type deployManifest struct {
	path, text string
}

// renderedMarker is the first line scripts/render-service-yaml.sh writes.
const renderedMarker = "# Rendered from docs/deploy/service.yaml.template by scripts/render-service-yaml.sh."

// deployManifests returns the template, which is in git and is what the
// deploy workflow renders (#100), and backend/service.yaml when it is a
// rendered one. A clean checkout has no backend/service.yaml (it is
// gitignored), so the template alone is checked there. A hand-written
// service.yaml from before the render script is not deployed by anything
// any more and is left out.
func deployManifests(t *testing.T) []deployManifest {
	t.Helper()
	root := filepath.Join("..", "..", "..")
	template := filepath.Join(root, "docs", "deploy", "service.yaml.template")
	body, err := os.ReadFile(template)
	if err != nil {
		t.Fatalf("read %s: %v", template, err)
	}
	out := []deployManifest{{template, string(body)}}
	rendered := filepath.Join(root, "backend", "service.yaml")
	if body, err := os.ReadFile(rendered); err == nil {
		if strings.HasPrefix(string(body), renderedMarker) {
			out = append(out, deployManifest{rendered, string(body)})
		} else {
			t.Logf("%s was not rendered by scripts/render-service-yaml.sh; checking the template only", rendered)
		}
	}
	return out
}

// placeholder matches the template's ${NAME} placeholders.
var placeholder = regexp.MustCompile(`\$\{([A-Z0-9_]+)\}`)

// containerEnv parses a manifest (placeholders filled with dummy values)
// and returns each container's env var names.
func containerEnv(t *testing.T, m deployManifest) map[string][]string {
	t.Helper()
	text := placeholder.ReplaceAllString(m.text, "placeholder")
	var svc struct {
		Spec struct {
			Template struct {
				Spec struct {
					Containers []struct {
						Name string `yaml:"name"`
						Env  []struct {
							Name string `yaml:"name"`
						} `yaml:"env"`
					} `yaml:"containers"`
				} `yaml:"spec"`
			} `yaml:"template"`
		} `yaml:"spec"`
	}
	if err := yaml.Unmarshal([]byte(text), &svc); err != nil {
		t.Fatalf("%s is not valid YAML: %v", m.path, err)
	}
	env := map[string][]string{}
	for _, c := range svc.Spec.Template.Spec.Containers {
		for _, e := range c.Env {
			env[c.Name] = append(env[c.Name], e.Name)
		}
	}
	return env
}

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

	for _, m := range deployManifests(t) {
		manifest, text := m.path, m.text

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

// Two settings in the manifest fail SILENTLY if they are dropped, which is
// why they are pinned here rather than left to review:
//
//   - CRON_SHARED_SECRET on the gateway. Without it /internal/cron/tick is
//     not mounted, and since the service scales to zero, no periodic work
//     runs at all — reminders, auto-close, outbox retries, retention.
//   - TRUSTED_PROXY_HOPS "1" on the gateway. Without it the rate limiter
//     keys every user on Cloud Run's proxy: one shared bucket per route for
//     the whole user base (#81).
func TestServiceManifestKeepsTheSilentFailureSettings(t *testing.T) {
	for _, m := range deployManifests(t) {
		text := m.text
		// Split on the container boundary so each check looks only at the
		// container that must carry the setting.
		monolithAt := strings.Index(text, "- name: monolith\n")
		if monolithAt < 0 {
			t.Fatalf("%s has no monolith container", m.path)
		}
		gateway, monolith := text[:monolithAt], text[monolithAt:]

		for _, want := range []string{
			"- name: CRON_SHARED_SECRET",
			"secretKeyRef: { name: cron-shared-secret, key: latest }",
			"- name: TRUSTED_PROXY_HOPS\n          value: \"1\"",
		} {
			if !strings.Contains(gateway, want) {
				t.Errorf("%s: the gateway container is missing %q", m.path, want)
			}
		}

		if strings.Contains(monolith, "value: \"http://localhost") {
			t.Errorf("%s: the monolith container points a URL at localhost", m.path)
		}
	}
}

// Every setting the code needs in production (#105). Most of these do not
// stop the process when missing: they turn a feature off with a warning
// (analytics disabled, purchases 503, Google notifications refused, metrics
// unserved), which is exactly the kind of failure nobody notices from a
// green deploy. Remove one from here only together with the code that
// reads it.
var requiredManifestEnv = map[string][]string{
	"gateway": {
		"MONOLITH_ADDR", "JWT_PRIVATE_KEY_PATH", "JWT_PUBLIC_KEY_PATH",
		"MONOLITH_SHARED_SECRET", "TRUSTED_PROXY_HOPS", "CRON_SHARED_SECRET",
		"METRICS_TOKEN", "OTEL_EXPORTER",
	},
	"monolith": {
		"MONOLITH_PORT", "DATABASE_URL", "INTERNAL_GRPC_SHARED_SECRET",
		"GOOGLE_CLIENT_ID", "APPLE_SERVICES_ID",
		"LINKEDIN_CLIENT_ID", "LINKEDIN_REDIRECT_URI", "LINKEDIN_CLIENT_SECRET",
		"FIREBASE_SERVICE_ACCOUNT_JSON",
		"TWILIO_ACCOUNT_SID", "TWILIO_PHONE_NUMBER", "TWILIO_AUTH_TOKEN",
		"GMAIL_ADDRESS", "GMAIL_APP_PASSWORD", "WORK_EMAIL_HMAC_KEY_PATH",
		"ALLOW_TEST_OTP_BYPASS", "TEST_OTP_BYPASS_PHONES", "TEST_OTP_BYPASS_EMAILS",
		// Plan 29.
		"ANALYTICS_USER_KEY_SECRET", "ANALYTICS_ARCHIVE_BUCKET", "ANALYTICS_REPORT_RECIPIENTS",
		"OTEL_EXPORTER", "MIN_CREDITS_APP_VERSION", "MIN_SUPPORTED_APP_VERSION",
		"APPLE_APP_STORE_ISSUER_ID", "APPLE_APP_STORE_KEY_ID", "APPLE_APP_STORE_PRIVATE_KEY",
		"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON",
		"GOOGLE_PUBSUB_PUSH_AUDIENCE", "GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT",
	},
}

func TestServiceManifestDeclaresEveryProductionSetting(t *testing.T) {
	for _, m := range deployManifests(t) {
		env := containerEnv(t, m)
		for container, names := range requiredManifestEnv {
			for _, name := range names {
				if !slices.Contains(env[container], name) {
					t.Errorf("%s: the %s container does not set %s", m.path, container, name)
				}
			}
		}
	}
}

// The template is what gets deployed now, so it must not carry anything
// from the Cloud SQL era or a fixed revision: a fixed name is reused by
// `services replace` and a fixed image tag deploys old code.
func TestServiceTemplateIsRenderedPerRevision(t *testing.T) {
	m := deployManifests(t)[0]
	for _, stale := range []string{"cloudsql-instances", ":r22", "-r22"} {
		if strings.Contains(m.text, stale) {
			t.Errorf("%s still contains %q", m.path, stale)
		}
	}
	for _, want := range []string{
		"name: meetups-backend-${REVISION}",
		"meetups-repo/gateway:${REVISION}",
		"meetups-repo/monolith:${REVISION}",
		"timeoutSeconds: 600",
	} {
		if !strings.Contains(m.text, want) {
			t.Errorf("%s does not contain %q", m.path, want)
		}
	}
	if old := regexp.MustCompile(`<[A-Z_]+>`).FindString(m.text); old != "" {
		t.Errorf("%s still has an old-style placeholder %s; use ${NAME}", m.path, old)
	}
}

// Every placeholder in the template is either required or optional in the
// render script, and the script lists nothing the template does not use.
func TestRenderScriptCoversEveryPlaceholder(t *testing.T) {
	template := deployManifests(t)[0].text
	script, err := os.ReadFile(filepath.Join("..", "..", "scripts", "render-service-yaml.sh"))
	if err != nil {
		t.Fatal(err)
	}
	listed := map[string]bool{}
	for _, block := range []string{"REQUIRED=(", "OPTIONAL=("} {
		at := strings.Index(string(script), block)
		if at < 0 {
			t.Fatalf("the render script has no %s list", block)
		}
		body := string(script)[at+len(block):]
		body = body[:strings.Index(body, "\n)")]
		for _, line := range strings.Split(body, "\n") {
			name := strings.Trim(strings.TrimSpace(line), `"`)
			if i := strings.IndexByte(name, ':'); i >= 0 {
				name = name[:i]
			}
			if name != "" {
				listed[name] = true
			}
		}
	}
	used := map[string]bool{}
	for _, match := range placeholder.FindAllStringSubmatch(template, -1) {
		used[match[1]] = true
	}
	for name := range used {
		if !listed[name] {
			t.Errorf("${%s} is in the template but not in the render script's lists", name)
		}
	}
	for name := range listed {
		if !used[name] {
			t.Errorf("the render script lists %s, which the template does not use", name)
		}
	}
	if len(used) < 10 {
		t.Fatalf("found %d placeholders; the parse is broken", len(used))
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

// The billing sweeps have no ticker of their own: the scheduled tick is the
// only thing that runs them while the service scales to zero. A sweep added
// to billing/sweeps.go and not to the tick would never run in production —
// holds would never expire and the daily reconciliation would never happen.
func TestScheduledTickRunsEveryBillingSweep(t *testing.T) {
	main, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	sweeps, err := os.ReadFile(filepath.Join("..", "..", "internal", "modules", "billing", "sweeps.go"))
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, line := range strings.Split(string(sweeps), "\n") {
		const prefix = "func (s *Service) "
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		name := strings.TrimPrefix(line, prefix)
		name = name[:strings.IndexByte(name, '(')]
		if !strings.HasPrefix(name, "Sweep") && name != "Reconcile" {
			continue
		}
		found++
		if !strings.Contains(string(main), "billingService."+name+")") {
			t.Errorf("billing has sweep %s, but the scheduled tick does not run it", name)
		}
	}
	if found < 3 {
		t.Fatalf("found %d billing sweeps; the parse is broken", found)
	}
	// And both billing outboxes are drained by the tick.
	for _, drain := range []string{"meetupBillingPoller.Drain", "billingPoller.Drain"} {
		if !strings.Contains(string(main), drain+")") {
			t.Errorf("the scheduled tick does not drain %s", drain)
		}
	}
}

// The analytics sweeps (plan 29D) also run only from the scheduled tick:
// without it, partitions stop being made ahead, days stop being aggregated,
// and raw events are never archived or dropped, so the database outgrows
// the free tier.
func TestScheduledTickRunsEveryAnalyticsSweep(t *testing.T) {
	main, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	var sweeps []byte
	for _, name := range []string{"sweeps.go", "report_run.go"} {
		src, err := os.ReadFile(filepath.Join("..", "..", "internal", "modules", "analytics", name))
		if err != nil {
			t.Fatal(err)
		}
		sweeps = append(sweeps, src...)
	}
	found := 0
	for _, line := range strings.Split(string(sweeps), "\n") {
		const prefix = "func (s *Service) Sweep"
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		name := strings.TrimPrefix(line, "func (s *Service) ")
		name = name[:strings.IndexByte(name, '(')]
		found++
		if !strings.Contains(string(main), "analyticsService."+name+")") {
			t.Errorf("analytics has sweep %s, but the scheduled tick does not run it", name)
		}
	}
	if found < 4 {
		t.Fatalf("found %d analytics sweeps; the parse is broken", found)
	}
	// And the meetup activity outbox (join requests and accepts) is drained
	// and kept bounded by the tick.
	for _, want := range []string{"activityPoller.Drain)", "retentionSweep(activityRetention)"} {
		if !strings.Contains(string(main), want) {
			t.Errorf("the scheduled tick does not run %s", want)
		}
	}
}

// Tracker #102: the analytics tick's sweeps must fit, budget for budget,
// inside the total the gateway gives that tick, or the last one is always
// starved. The total is read from the gateway's source, so changing either
// side without the other fails here.
func TestTheAnalyticsSweepBudgetsFitTheAnalyticsTick(t *testing.T) {
	main, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	cron, err := os.ReadFile(filepath.Join("..", "..", "internal", "gateway", "handlers", "cron.go"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`analyticsTickTimeout = (\d+) \* time\.Second`).FindSubmatch(cron)
	if m == nil {
		t.Fatal("cannot find analyticsTickTimeout in the gateway's cron.go")
	}
	seconds, err := strconv.Atoi(string(m[1]))
	if err != nil {
		t.Fatal(err)
	}
	total := time.Duration(seconds) * time.Second
	n := strings.Count(string(main), "Group: grpcapi.GroupAnalytics, Budget: analyticsSweepBudget")
	if n < 3 {
		t.Fatalf("found %d analytics-group sweeps in main.go; the parse is broken", n)
	}
	if strings.Count(string(main), "grpcapi.GroupAnalytics") != n {
		t.Fatal("an analytics-group sweep in main.go has a budget this test does not know")
	}
	if need := time.Duration(n)*analyticsSweepBudget + 5*time.Second; need > total {
		t.Errorf("%d analytics sweeps x %v need %v, but the analytics tick allows %v", n, analyticsSweepBudget, need, total)
	}
}
