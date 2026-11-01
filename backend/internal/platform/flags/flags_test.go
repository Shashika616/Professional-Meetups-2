package flags

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"
)

func boolPtr(b bool) *bool { return &b }

const (
	alice = "00000000-0000-4000-8000-0000000000a1"
	bob   = "00000000-0000-4000-8000-0000000000b0"
)

func TestEvaluate(t *testing.T) {
	tests := []struct {
		name string
		flag Flag
		subj Subject
		want bool
	}{
		{"no rules, off", Flag{Key: "k"}, Subject{UserID: alice}, false},
		{"no rules, on", Flag{Key: "k", Enabled: true}, Subject{UserID: alice}, true},
		{
			"user allowlist matches",
			Flag{Key: "k", Rules: []Rule{{Type: RuleUserIDs, Values: []string{alice}}}},
			Subject{UserID: alice}, true,
		},
		{
			"user allowlist is case-insensitive",
			Flag{Key: "k", Rules: []Rule{{Type: RuleUserIDs, Values: []string{"00000000-0000-4000-8000-0000000000A1"}}}},
			Subject{UserID: alice}, true,
		},
		{
			"user allowlist misses, falls back to enabled",
			Flag{Key: "k", Rules: []Rule{{Type: RuleUserIDs, Values: []string{alice}}}},
			Subject{UserID: bob}, false,
		},
		{
			"anonymous never matches a user allowlist",
			Flag{Key: "k", Rules: []Rule{{Type: RuleUserIDs, Values: []string{alice}}}},
			Subject{}, false,
		},
		{
			"email domain matches",
			Flag{Key: "k", Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"meetups.test"}}}},
			Subject{UserID: alice, Email: "L3.A@Meetups.TEST"}, true,
		},
		{
			"email domain with a leading @ in the rule",
			Flag{Key: "k", Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"@meetups.test"}}}},
			Subject{Email: "x@meetups.test"}, true,
		},
		{
			"a subdomain is not the domain",
			Flag{Key: "k", Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"meetups.test"}}}},
			Subject{Email: "x@evil.meetups.test.example"}, false,
		},
		{
			"no email never matches a domain rule",
			Flag{Key: "k", Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"meetups.test"}}}},
			Subject{UserID: alice}, false,
		},
		{
			"min app version: newer matches",
			Flag{Key: "k", Rules: []Rule{{Type: RuleMinAppVersion, Version: "1.4.0"}}},
			Subject{AppVersion: "1.10.0"}, true,
		},
		{
			"min app version: equal matches",
			Flag{Key: "k", Rules: []Rule{{Type: RuleMinAppVersion, Version: "1.4"}}},
			Subject{AppVersion: "1.4.0+12"}, true,
		},
		{
			"min app version: older misses",
			Flag{Key: "k", Rules: []Rule{{Type: RuleMinAppVersion, Version: "1.4.0"}}},
			Subject{AppVersion: "1.3.9"}, false,
		},
		{
			"min app version: no version misses",
			Flag{Key: "k", Rules: []Rule{{Type: RuleMinAppVersion, Version: "1.4.0"}}},
			Subject{}, false,
		},
		{
			"percentage 100 includes everyone with an id",
			Flag{Key: "k", Rules: []Rule{{Type: RulePercentage, Percent: 100}}},
			Subject{UserID: alice}, true,
		},
		{
			"percentage 0 includes nobody",
			Flag{Key: "k", Rules: []Rule{{Type: RulePercentage, Percent: 0}}},
			Subject{UserID: alice}, false,
		},
		{
			"first match wins: an exclusion before an allowlist",
			Flag{Key: "k", Rules: []Rule{
				{Type: RuleUserIDs, Values: []string{alice}, Result: boolPtr(false)},
				{Type: RulePercentage, Percent: 100},
			}},
			Subject{UserID: alice}, false,
		},
		{
			"an exclusion switches off a flag that is on",
			Flag{Key: "k", Enabled: true, Rules: []Rule{
				{Type: RuleMinAppVersion, Version: "2.0.0", Result: boolPtr(true)},
				{Type: RulePercentage, Percent: 100, Result: boolPtr(false)},
			}},
			Subject{UserID: alice, AppVersion: "1.0.0"}, false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Evaluate(tt.flag, tt.subj); got != tt.want {
				t.Fatalf("Evaluate() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCompareVersions(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"1.0.0", "1.0.0", 0},
		{"1.4", "1.4.0", 0},
		{"1.10.0", "1.9.9", 1},
		{"1.0.0+6", "1.0.0", 0},
		{"2.0.0-beta", "2.0.0", 0},
		{"v1.2.3", "1.2.3", 0},
		{"", "0.0.1", -1},
		{"garbage", "0.0.0", -1},
		{"1.2.3.4", "1.0.0", -1},
		{"1.0.0", "", 1},
	}
	for _, tt := range tests {
		if got := CompareVersions(tt.a, tt.b); got != tt.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
	}
	if AtLeast("", "0.0.0") {
		t.Error("an empty version must never be AtLeast anything")
	}
}

func TestBucketIsStableAndSpread(t *testing.T) {
	first, second := Bucket("k", alice), Bucket("k", alice)
	if first != second {
		t.Fatal("Bucket is not stable")
	}
	counts := make([]int, 10)
	for i := 0; i < 10000; i++ {
		counts[Bucket("analytics.enabled", fmt.Sprintf("user-%d", i))/10]++
	}
	for decile, n := range counts {
		if n < 800 || n > 1200 {
			t.Errorf("decile %d holds %d of 10000 users; the hash is badly skewed", decile, n)
		}
	}
	// A different flag puts the same users in different buckets.
	same := 0
	for i := 0; i < 1000; i++ {
		u := fmt.Sprintf("user-%d", i)
		if Bucket("a", u) == Bucket("b", u) {
			same++
		}
	}
	if same > 50 {
		t.Errorf("%d of 1000 users share a bucket across two flags; rollouts would correlate", same)
	}
}

func TestValidate(t *testing.T) {
	bad := [][]Rule{
		{{Type: "nope"}},
		{{Type: RuleUserIDs}},
		{{Type: RuleEmailDomains}},
		{{Type: RuleMinAppVersion, Version: "x"}},
		{{Type: RulePercentage, Percent: 101}},
	}
	for _, rules := range bad {
		if err := Validate(rules); err == nil {
			t.Errorf("Validate(%+v) accepted an invalid rule", rules)
		}
	}
	if err := Validate([]Rule{{Type: RulePercentage, Percent: 5}}); err != nil {
		t.Errorf("Validate rejected a valid rule: %v", err)
	}
}

type countingStore struct {
	flags []Flag
	err   error
	reads atomic.Int32
}

func (c *countingStore) All(context.Context) ([]Flag, error) {
	c.reads.Add(1)
	return c.flags, c.err
}

func TestServiceCachesFor30Seconds(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	store := &countingStore{flags: []Flag{{Key: AnalyticsEnabled, Enabled: true}}}
	svc := NewService(store, WithClock(func() time.Time { return now }))
	ctx := context.Background()

	for i := 0; i < 5; i++ {
		on, err := svc.Enabled(ctx, AnalyticsEnabled, Subject{})
		if err != nil || !on {
			t.Fatalf("Enabled = %v, %v", on, err)
		}
	}
	if n := store.reads.Load(); n != 1 {
		t.Fatalf("store read %d times inside the TTL, want 1", n)
	}

	now = now.Add(29 * time.Second)
	_, _ = svc.Enabled(ctx, AnalyticsEnabled, Subject{})
	if n := store.reads.Load(); n != 1 {
		t.Fatalf("store read %d times at 29s, want 1", n)
	}
	now = now.Add(2 * time.Second)
	_, _ = svc.Enabled(ctx, AnalyticsEnabled, Subject{})
	if n := store.reads.Load(); n != 2 {
		t.Fatalf("store read %d times after the TTL, want 2", n)
	}
}

func TestServiceServesThePreviousCopyWhenAReloadFails(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	store := &countingStore{flags: []Flag{{Key: AnalyticsEnabled, Enabled: true}}}
	svc := NewService(store, WithClock(func() time.Time { return now }))
	ctx := context.Background()
	if on, _ := svc.Enabled(ctx, AnalyticsEnabled, Subject{}); !on {
		t.Fatal("expected on")
	}
	store.err = errors.New("database down")
	now = now.Add(time.Minute)
	on, err := svc.Enabled(ctx, AnalyticsEnabled, Subject{})
	if err != nil || !on {
		t.Fatalf("after a failed reload Enabled = %v, %v; want the previous copy", on, err)
	}
}

func TestServiceFailsWithNothingCached(t *testing.T) {
	svc := NewService(&countingStore{err: errors.New("down")})
	if _, err := svc.Enabled(context.Background(), AnalyticsEnabled, Subject{}); err == nil {
		t.Fatal("Enabled with no table and a failing store must return an error, not a default")
	}
}

func TestUnknownAndInvalidFlagsAreOff(t *testing.T) {
	store := &countingStore{flags: []Flag{
		{Key: "broken", Enabled: true, Rules: []Rule{{Type: "nope"}}},
	}}
	svc := NewService(store)
	for _, key := range []string{"broken", "never.defined"} {
		on, err := svc.Enabled(context.Background(), key, Subject{UserID: alice})
		if err != nil || on {
			t.Errorf("Enabled(%q) = %v, %v; want off", key, on, err)
		}
	}
}

func TestEmailIsLookedUpOnlyWhenARuleNeedsIt(t *testing.T) {
	var lookups atomic.Int32
	resolver := func(_ context.Context, userID string) (string, error) {
		lookups.Add(1)
		return "l3.a@meetups.test", nil
	}
	store := &countingStore{flags: []Flag{
		{Key: AnalyticsEnabled},
		{Key: BillingPlansVisible, Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"meetups.test"}}}},
		{Key: AnalyticsSampleRate, Enabled: true, Value: json.RawMessage(`100`)},
	}}
	svc := NewService(store, WithEmailResolver(resolver))
	ctx := context.Background()

	if on, _ := svc.Enabled(ctx, AnalyticsEnabled, Subject{UserID: alice}); on {
		t.Fatal("analytics.enabled should be off")
	}
	if n := lookups.Load(); n != 0 {
		t.Fatalf("looked up the email %d times for a flag with no email rule", n)
	}

	all, err := svc.EvaluateAll(ctx, Subject{UserID: alice})
	if err != nil {
		t.Fatal(err)
	}
	if !all[BillingPlansVisible].Enabled {
		t.Error("plans should be visible to a @meetups.test account")
	}
	if string(all[AnalyticsSampleRate].Value) != "100" {
		t.Errorf("sample rate value = %s, want 100", all[AnalyticsSampleRate].Value)
	}
	if n := lookups.Load(); n != 1 {
		t.Fatalf("EvaluateAll looked up the email %d times, want 1", n)
	}
}

func TestAFailedEmailLookupFailsClosed(t *testing.T) {
	store := &countingStore{flags: []Flag{
		{Key: BillingPlansVisible, Rules: []Rule{{Type: RuleEmailDomains, Values: []string{"meetups.test"}}}},
	}}
	svc := NewService(store, WithEmailResolver(func(context.Context, string) (string, error) {
		return "", errors.New("auth unavailable")
	}))
	on, err := svc.Enabled(context.Background(), BillingPlansVisible, Subject{UserID: alice})
	if err != nil || on {
		t.Fatalf("Enabled = %v, %v; want off with no error", on, err)
	}
}

// Allowlisted is "a rule matched", not "the flag is on": turning the flag on
// for everyone must not put everyone on the list.
func TestAllowlistedIgnoresTheDefault(t *testing.T) {
	store := &countingStore{flags: []Flag{
		{Key: BillingPlansVisible, Enabled: true, Rules: []Rule{{Type: RuleUserIDs, Values: []string{"listed"}}}},
	}}
	svc := NewService(store)
	ctx := context.Background()
	if on, err := svc.Allowlisted(ctx, BillingPlansVisible, Subject{UserID: "listed"}); err != nil || !on {
		t.Fatalf("listed user: %v, %v; want true", on, err)
	}
	if on, _ := svc.Allowlisted(ctx, BillingPlansVisible, Subject{UserID: "someone"}); on {
		t.Fatal("an unlisted user is allowlisted because the flag is on for everyone")
	}
	if on, _ := svc.Enabled(ctx, BillingPlansVisible, Subject{UserID: "someone"}); !on {
		t.Fatal("the flag itself should be on for everyone")
	}
	if on, _ := svc.Allowlisted(ctx, "no.such.flag", Subject{UserID: "listed"}); on {
		t.Fatal("an unknown flag allowlists nobody")
	}
}
