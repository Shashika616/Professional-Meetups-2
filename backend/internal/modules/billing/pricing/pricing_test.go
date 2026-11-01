package pricing

import (
	"errors"
	"math/rand/v2"
	"os"
	"regexp"
	"testing"
	"time"
)

// defaultDocument is read from the migration that seeds it, so these tests
// price exactly what production will.
func defaultRules(t *testing.T) Rules {
	t.Helper()
	raw, err := os.ReadFile("../../../../migrations/0026_billing_schema.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)VALUES \(1, '(\{.*?\})', true\)`).FindSubmatch(raw)
	if m == nil {
		t.Fatal("could not find the seeded price document in the migration")
	}
	r, err := Parse(1, m[1])
	if err != nil {
		t.Fatalf("the seeded document does not parse: %v", err)
	}
	return r
}

func TestPriceWithTheDefaultRules(t *testing.T) {
	r := defaultRules(t)
	h := time.Hour
	tests := []struct {
		name     string
		capacity int
		lead     time.Duration
		want     Breakdown
	}{
		{"host plus 3, tonight", 4, 5 * h, Breakdown{Base: 10}},
		{"capacity 1, starting now", 1, 0, Breakdown{Base: 10}},
		{"in the creation grace period", 4, -2 * time.Minute, Breakdown{Base: 10}},
		{"5 people pays for 1 extra", 5, h, Breakdown{Base: 10, People: 2}},
		{"20 people pays for 16 extra", 20, h, Breakdown{Base: 10, People: 32}},
		{"exactly 48h is the first band", 4, 48 * h, Breakdown{Base: 10}},
		{"just past 48h", 4, 48*h + time.Minute, Breakdown{Base: 10, LeadTime: 3}},
		{"7 days", 4, 7 * 24 * h, Breakdown{Base: 10, LeadTime: 3}},
		{"8 days", 4, 8 * 24 * h, Breakdown{Base: 10, LeadTime: 6}},
		{"14 days", 4, 14 * 24 * h, Breakdown{Base: 10, LeadTime: 6}},
		{"15 days", 4, 15 * 24 * h, Breakdown{Base: 10, LeadTime: 10}},
		{"30 people, 30 days", 30, 30 * 24 * h, Breakdown{Base: 10, People: 52, LeadTime: 10}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Price(r, Input{Capacity: tt.capacity, Lead: tt.lead})
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("Price = %+v (total %d), want %+v", got, got.Total(), tt.want)
			}
		})
	}
}

func TestPriceOutsideTheRange(t *testing.T) {
	r := defaultRules(t)
	for _, in := range []Input{
		{Capacity: 0, Lead: time.Hour},
		{Capacity: 4, Lead: 31 * 24 * time.Hour},
	} {
		if _, err := Price(r, in); !errors.Is(err, ErrBeyondPricing) {
			t.Errorf("Price(%+v) err = %v, want ErrBeyondPricing", in, err)
		}
	}
}

// The property plan 29 §3.3 asks for: cost never goes down when capacity or
// lead time goes up — over the default rules and over random valid ones.
func TestPriceIsMonotonic(t *testing.T) {
	rng := rand.New(rand.NewPCG(29, 1))
	check := func(t *testing.T, r Rules) {
		t.Helper()
		maxLead := r.MaxPricedLead()
		for i := 0; i < 2000; i++ {
			c := 1 + rng.IntN(29)
			lead := time.Duration(rng.Int64N(int64(maxLead)))
			a, errA := Price(r, Input{Capacity: c, Lead: lead})
			moreCap, errB := Price(r, Input{Capacity: c + 1, Lead: lead})
			later := lead + time.Duration(rng.Int64N(int64(maxLead-lead)+1))
			moreLead, errC := Price(r, Input{Capacity: c, Lead: later})
			if errA != nil || errB != nil || errC != nil {
				t.Fatalf("unexpected errors %v %v %v", errA, errB, errC)
			}
			if moreCap.Total() < a.Total() {
				t.Fatalf("capacity %d->%d at %s: cost fell %d->%d", c, c+1, lead, a.Total(), moreCap.Total())
			}
			if moreLead.Total() < a.Total() {
				t.Fatalf("lead %s->%s at capacity %d: cost fell %d->%d", lead, later, c, a.Total(), moreLead.Total())
			}
		}
	}

	t.Run("default rules", func(t *testing.T) { check(t, defaultRules(t)) })

	for n := 0; n < 50; n++ {
		r := defaultRules(t)
		r.Doc.Base.Credits = rng.Int64N(50)
		r.Doc.Base.IncludesCapacity = 1 + rng.IntN(10)
		r.Doc.PerExtraPerson = rng.Int64N(10)
		bands := 1 + rng.IntN(6)
		r.Doc.LeadTime = nil
		hours, credits := 0, int64(0)
		for b := 0; b < bands; b++ {
			hours += 1 + rng.IntN(200)
			credits += rng.Int64N(8)
			r.Doc.LeadTime = append(r.Doc.LeadTime, LeadBand{UpToHours: hours, Credits: credits})
		}
		if err := validate(r.Doc); err != nil {
			t.Fatalf("generated an invalid document: %v", err)
		}
		check(t, r)
	}
}

func TestParseRejectsBadDocuments(t *testing.T) {
	good := `{"base":{"credits":10,"includes_capacity":4},"per_extra_person":2,
		"lead_time":[{"up_to_hours":48,"credits":0}],
		"free":{"max_capacity":20,"max_advance_days":14},
		"welcome":{"credits":60,"decay_percent":10,"decay_every_days":7},
		"refunds":{"full_if_cancelled_hours_before":24,"no_participants_percent":50,"max_per_30_days":3},
		"hold_ttl_minutes":120}`
	if _, err := Parse(9, []byte(good)); err != nil {
		t.Fatalf("a valid document was rejected: %v", err)
	}
	bad := map[string]string{
		"unknown field":       `{"base":{"credits":10,"includes_capacity":4},"bogus":1}`,
		"negative base":       replace(good, `"credits":10,"includes`, `"credits":-1,"includes`),
		"cheaper later band":  replace(good, `[{"up_to_hours":48,"credits":0}]`, `[{"up_to_hours":48,"credits":5},{"up_to_hours":96,"credits":4}]`),
		"band not widening":   replace(good, `[{"up_to_hours":48,"credits":0}]`, `[{"up_to_hours":48,"credits":0},{"up_to_hours":48,"credits":1}]`),
		"no bands":            replace(good, `[{"up_to_hours":48,"credits":0}]`, `[]`),
		"capacity over 30":    replace(good, `"max_capacity":20`, `"max_capacity":31`),
		"decay over 100":      replace(good, `"decay_percent":10`, `"decay_percent":101`),
		"refund percent over": replace(good, `"no_participants_percent":50`, `"no_participants_percent":150`),
		"zero hold ttl":       replace(good, `"hold_ttl_minutes":120`, `"hold_ttl_minutes":0`),
		"not json":            `{`,
		"fractional credits":  replace(good, `"per_extra_person":2`, `"per_extra_person":2.5`),
	}
	for name, doc := range bad {
		if _, err := Parse(9, []byte(doc)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func replace(s, old, new string) string {
	out := []byte(s)
	i := indexOf(s, old)
	if i < 0 {
		panic("replace: " + old + " not found")
	}
	return string(out[:i]) + new + string(out[i+len(old):])
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
