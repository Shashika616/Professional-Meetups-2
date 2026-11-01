package main

import (
	"bytes"
	"context"
	"net"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/platform/db"
)

// Every changing command refuses to run without an operator and a reason,
// before it connects to anything.
func TestChangesNeedAnOperatorAndAReason(t *testing.T) {
	noDB := func(string) string { return "" }
	for _, args := range [][]string{
		{"grant", "--user", "u", "--amount", "5"},
		{"grant", "--user", "u", "--amount", "5", "--operator", "me"},
		{"adjust", "--user", "u", "--delta", "-5", "--reason", "why"},
		{"set-plan", "--user", "u", "--plan", "pro", "--until", "2030-01-01"},
		{"flags", "set", "--flag", "billing.plans.visible", "--enabled", "true"},
	} {
		err := run(context.Background(), args, noDB, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "--operator and --reason are required") {
			t.Errorf("%v: err = %v, want the operator/reason refusal", args, err)
		}
	}
}

func TestBadArguments(t *testing.T) {
	noDB := func(string) string { return "" }
	for _, args := range [][]string{
		{},
		{"refund-everyone"},
		{"grant", "--user", "u", "--amount", "0", "--operator", "o", "--reason", "r"},
		{"adjust", "--user", "u", "--delta", "0", "--operator", "o", "--reason", "r"},
		{"set-plan", "--user", "u", "--plan", "pro", "--operator", "o", "--reason", "r"},
		{"flags", "set", "--flag", "x", "--enabled", "maybe", "--operator", "o", "--reason", "r"},
		{"flags"},
	} {
		if err := run(context.Background(), args, noDB, &bytes.Buffer{}); err == nil {
			t.Errorf("%v: accepted", args)
		}
	}
}

func testDatabase(t *testing.T) func(string) string {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		dbURL = "postgres://app:app@localhost:5432/monolith_db?sslmode=disable"
	}
	parsed, _ := url.Parse(dbURL)
	conn, err := net.DialTimeout("tcp", parsed.Host, 500*time.Millisecond)
	if err != nil {
		t.Skipf("postgres not reachable: %v", err)
	}
	_ = conn.Close()
	testURL, err := db.EnsureTestDatabase(context.Background(), dbURL)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Migrate(testURL, "file://../../migrations"); err != nil {
		t.Fatal(err)
	}
	pool, err := db.New(context.Background(), testURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	release, err := db.AcquireIntegrationTestLock(context.Background(), pool)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(release)
	return func(k string) string {
		if k == "DATABASE_URL" {
			return testURL
		}
		return ""
	}
}

// The identical grant run twice applies once, and lands in the ledger with
// the operator's name.
func TestGrantIsIdempotentAndAudited(t *testing.T) {
	env := testDatabase(t)
	ctx := context.Background()
	user := uuid.NewString()
	args := []string{"grant", "--user", user, "--amount", "25", "--operator", "shashika", "--reason", "support ticket 12"}
	for i := 0; i < 2; i++ {
		var out bytes.Buffer
		if err := run(ctx, args, env, &out); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), `"Balance": 25`) {
			t.Fatalf("run %d output:\n%s", i+1, out.String())
		}
	}
	var out bytes.Buffer
	if err := run(ctx, []string{"adjust", "--user", user, "--delta", "-5", "--operator", "shashika", "--reason", "correction"}, env, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"Balance": 20`) {
		t.Fatalf("after adjust:\n%s", out.String())
	}
	if err := run(ctx, []string{"adjust", "--user", user, "--delta", "-500", "--operator", "s", "--reason", "too much", "--key", "k2"}, env, &out); err == nil {
		t.Fatal("removing more than the balance succeeded")
	}
	if err := run(ctx, []string{"set-plan", "--user", user, "--plan", "enterprise", "--until", "2099-01-01",
		"--operator", "shashika", "--reason", "contract"}, env, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"PlanCode": "enterprise"`) {
		t.Fatalf("after set-plan:\n%s", out.String())
	}
}

func TestFlagsSetAndShow(t *testing.T) {
	env := testDatabase(t)
	ctx := context.Background()
	var out bytes.Buffer
	err := run(ctx, []string{"flags", "set", "--flag", "test.cli", "--enabled", "false",
		"--rules", `[{"type":"percentage","percent":10}]`, "--operator", "shashika", "--reason", "rollout"}, env, &out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "test.cli") || !strings.Contains(out.String(), `"percent":10`) {
		t.Fatalf("flags output:\n%s", out.String())
	}
	if err := run(ctx, []string{"flags", "set", "--flag", "test.cli", "--enabled", "true",
		"--rules", `[{"type":"nope"}]`, "--operator", "s", "--reason", "r"}, env, &out); err == nil {
		t.Fatal("an invalid rule was accepted")
	}
}
