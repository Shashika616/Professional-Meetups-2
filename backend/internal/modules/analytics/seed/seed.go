// Package seed generates realistic analytics events for local runs, the
// report tests and the scalability check (plan 29F). Never used in
// production: it writes synthetic events straight into analytics.events.
//
// The shape follows how the app behaves: accounts first seen across the
// period and returning less over time, installs that never sign in,
// sessions of screens with real-looking durations, the catalogued controls,
// funnels with drop-off at each step, friction, and the server's own credit
// and purchase events. One rare screen is viewed by only a couple of
// accounts a day, so the report's small-group suppression has something to
// suppress.
package seed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"math/rand/v2"
	"time"

	"github.com/google/uuid"

	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository"
)

// Options sizes a run.
type Options struct {
	Accounts     int       // signed-in accounts
	Anonymous    int       // installs that never sign in
	Days         int       // days of activity, ending on End
	End          time.Time // the last day (a date, Asia/Colombo)
	Seed         uint64    // the random seed: the same seed gives the same events
	BatchSize    int       // events per write
	RareAccounts int       // accounts that view the rare screen each day (keep under 5)
}

// Writer stores events (repository.Store).
type Writer interface {
	Write(ctx context.Context, events []repository.Event) (repository.WriteResult, error)
}

// PartitionMaker makes sure a UTC day's partition exists.
type PartitionMaker func(ctx context.Context, day time.Time) error

// RareScreen is the screen only RareAccounts accounts view.
const RareScreen = "sos_confirm"

var colombo = func() *time.Location {
	if loc, err := time.LoadLocation("Asia/Colombo"); err == nil {
		return loc
	}
	return time.FixedZone("Asia/Colombo", 5*3600+30*60)
}()

type actor struct {
	key       string // user_key, "" for anonymous
	install   string
	firstDay  int     // index of the first active day
	stickness float64 // chance of coming back each later day
}

type gen struct {
	r     *rand.Rand
	reg   *registry.Registry
	out   []repository.Event
	flush func([]repository.Event) error
}

// Run generates and writes the events, and returns how many it wrote.
func Run(ctx context.Context, w Writer, partitions PartitionMaker, opt Options) (int, error) {
	if opt.BatchSize == 0 {
		opt.BatchSize = 5000
	}
	if opt.Days == 0 {
		opt.Days = 7
	}
	g := &gen{r: rand.New(rand.NewPCG(opt.Seed, opt.Seed^0x9e3779b97f4a7c15)), reg: registry.Default()}
	written := 0
	g.flush = func(evs []repository.Event) error {
		if len(evs) == 0 {
			return nil
		}
		if _, err := w.Write(ctx, evs); err != nil {
			return err
		}
		written += len(evs)
		return nil
	}

	start := opt.End.AddDate(0, 0, -(opt.Days - 1))
	// Partitions for every UTC day the Colombo days touch.
	for i := -1; i <= opt.Days; i++ {
		if err := partitions(ctx, start.AddDate(0, 0, i)); err != nil {
			return 0, err
		}
	}

	actors := make([]actor, 0, opt.Accounts+opt.Anonymous)
	for i := 0; i < opt.Accounts; i++ {
		actors = append(actors, actor{
			key:       userKey(opt.Seed, i),
			install:   uuidFor(opt.Seed, "install", i),
			firstDay:  g.r.IntN(opt.Days),
			stickness: 0.25 + 0.6*g.r.Float64(),
		})
	}
	for i := 0; i < opt.Anonymous; i++ {
		actors = append(actors, actor{
			install:   uuidFor(opt.Seed, "anon", i),
			firstDay:  g.r.IntN(opt.Days),
			stickness: 0.1 + 0.2*g.r.Float64(),
		})
	}

	for d := 0; d < opt.Days; d++ {
		day := start.AddDate(0, 0, d)
		rare := 0
		for i, a := range actors {
			if d < a.firstDay || (d > a.firstDay && g.r.Float64() > a.stickness) {
				continue
			}
			wantRare := a.key != "" && rare < opt.RareAccounts && i%7 == 0
			if wantRare {
				rare++
			}
			if err := g.day(a, day, d == a.firstDay, wantRare); err != nil {
				return written, err
			}
			if len(g.out) >= opt.BatchSize {
				if err := g.flush(g.out); err != nil {
					return written, err
				}
				g.out = g.out[:0]
			}
		}
	}
	if err := g.flush(g.out); err != nil {
		return written, err
	}
	return written, nil
}

// userKey is a stable, user_key-shaped (64 hex) key for synthetic account i.
func userKey(seed uint64, i int) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("seed-%d-account-%d", seed, i)))
	return hex.EncodeToString(sum[:])
}

func uuidFor(seed uint64, kind string, i int) string {
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte(fmt.Sprintf("%d-%s-%d", seed, kind, i))).String()
}

var screens = []string{"home", "events", "meetup_detail", "profile", "credits", "safety", "notifications", "location_view", "participants", "premium"}

// day emits one actor's activity for one Colombo day.
func (g *gen) day(a actor, day time.Time, first, rare bool) error {
	// Somewhere between 07:00 and 22:00 Colombo.
	t := time.Date(day.Year(), day.Month(), day.Day(), 7, 0, 0, 0, colombo).Add(time.Duration(g.r.IntN(15*3600)) * time.Second)
	sessions := 1 + g.r.IntN(3)
	for s := 0; s < sessions; s++ {
		session := uuid.NewString()
		sessionStart := t
		g.emit(a, t, "app_opened", session, "", "", "", attrs("cold_start", s == 0))
		g.emit(a, t, "session_started", session, "", "", "", nil)
		if first && s == 0 {
			if a.key != "" {
				g.server(a, t, "credits_granted", attrs("reason", "grant", "credits", int64(60)))
			}
		}
		n := 3 + g.r.IntN(8)
		for i := 0; i < n; i++ {
			screen := screens[weighted(g.r, len(screens))]
			if rare && i == 0 && s == 0 {
				screen = RareScreen
			}
			dur := int64(math.Min(math.Exp(8+1.2*g.r.NormFloat64()), 600000)) // median ~3 s
			g.emit(a, t, "screen_viewed", session, screen, "", "", nil)
			t = t.Add(time.Duration(dur) * time.Millisecond)
			if g.r.Float64() < 0.35 {
				cta := g.reg.CTAs[weighted(g.r, len(g.reg.CTAs))]
				g.emit(a, t, "cta_tapped", session, screen, "", "", attrs("cta", cta))
			}
			if g.r.Float64() < 0.03 {
				g.emit(a, t, "error_shown", session, screen, "", "", attrs("kind", []string{"load_failed_offline", "load_failed_server", "error_toast"}[g.r.IntN(3)]))
			}
			if g.r.Float64() < 0.02 {
				g.emit(a, t, "api_error", session, screen, "", "", attrs("route", "get:v1.meetups.mine", "status_class", []string{"4xx", "5xx", "network"}[g.r.IntN(3)]))
			}
			if g.r.Float64() < 0.005 {
				g.emit(a, t, "rage_tap", session, screen, "", "", attrs("taps", int64(3+g.r.IntN(3))))
			}
			g.emit(a, t, "screen_left", session, screen, "", "", attrs("duration_ms", dur))
		}
		if g.r.Float64() < 0.5 {
			g.emit(a, t, "filter_changed", session, "home", "", "", attrs("filter", "intent_coffee", "active", true))
		}
		if a.key != "" && g.r.Float64() < 0.3 {
			t = g.scheduleFlow(a, t, session)
		}
		if a.key != "" && g.r.Float64() < 0.25 {
			t = g.simpleFlow(a, t, session, "join_meetup", []string{"detail", "request"}, 0.6)
		}
		if a.key != "" && g.r.Float64() < 0.05 {
			g.emit(a, t, "credits_insufficient_shown", session, "schedule_meetup", "", "", attrs("required_credits", int64(14)))
			if g.r.Float64() < 0.5 {
				t = g.buy(a, t, session)
			}
		}
		g.emit(a, t, "session_ended", session, "", "", "", attrs("duration_ms", t.Sub(sessionStart).Milliseconds()))
		t = t.Add(time.Duration(30+g.r.IntN(240)) * time.Minute)
		if t.In(colombo).Day() != day.Day() {
			break
		}
	}
	return nil
}

func (g *gen) scheduleFlow(a actor, t time.Time, session string) time.Time {
	steps := []string{"intent", "timing", "location", "capacity", "review"}
	g.emit(a, t, "flow_started", session, "schedule_meetup", "schedule_meetup", "", nil)
	start := t
	for i, step := range steps {
		g.emit(a, t, "flow_step_viewed", session, "schedule_meetup", "schedule_meetup", step, nil)
		dur := int64(2000 + g.r.IntN(30000))
		t = t.Add(time.Duration(dur) * time.Millisecond)
		if g.r.Float64() < 0.12 {
			reason := "back"
			if g.r.Float64() < 0.25 {
				reason = "backgrounded"
			}
			if g.r.Float64() < 0.1 {
				g.emit(a, t, "long_dwell", session, "schedule_meetup", "", "", attrs("duration_ms", int64(60000)))
			}
			g.emit(a, t, "flow_abandoned", session, "schedule_meetup", "schedule_meetup", step, attrs("reason", reason))
			return t
		}
		g.emit(a, t, "flow_step_completed", session, "schedule_meetup", "schedule_meetup", step, attrs("duration_ms", dur))
		_ = i
	}
	g.emit(a, t, "flow_completed", session, "schedule_meetup", "schedule_meetup", "review", attrs("duration_ms", t.Sub(start).Milliseconds()))
	credits := []int64{6, 8, 10, 14, 18, 24, 36, 60}[g.r.IntN(8)]
	g.server(a, t, "meetup_created", nil)
	g.server(a, t, "credits_spent", attrs("reason", "capture", "credits", credits))
	return t
}

func (g *gen) simpleFlow(a actor, t time.Time, session, flow string, steps []string, pass float64) time.Time {
	g.emit(a, t, "flow_started", session, "meetup_detail", flow, "", nil)
	for _, step := range steps {
		g.emit(a, t, "flow_step_viewed", session, "meetup_detail", flow, step, nil)
		dur := int64(1000 + g.r.IntN(8000))
		t = t.Add(time.Duration(dur) * time.Millisecond)
		if g.r.Float64() > pass {
			g.emit(a, t, "flow_abandoned", session, "meetup_detail", flow, step, attrs("reason", "closed"))
			return t
		}
		g.emit(a, t, "flow_step_completed", session, "meetup_detail", flow, step, attrs("duration_ms", dur))
	}
	g.emit(a, t, "flow_completed", session, "meetup_detail", flow, steps[len(steps)-1], nil)
	return t
}

func (g *gen) buy(a actor, t time.Time, session string) time.Time {
	t = g.simpleFlow(a, t, session, "buy_credits", []string{"choose_pack", "store_sheet", "confirmed"}, 0.8)
	pack := []string{"credits_50", "credits_120", "credits_300"}[g.r.IntN(3)]
	g.server(a, t, "purchase_verified", attrs("platform", "android", "kind", "consumable", "product_id", pack))
	g.server(a, t, "credits_granted", attrs("reason", "grant", "credits", int64(map[string]int{"credits_50": 50, "credits_120": 120, "credits_300": 300}[pack])))
	return t
}

// weighted picks an index with a long tail (the first items most often).
func weighted(r *rand.Rand, n int) int {
	i := int(math.Abs(r.NormFloat64()) * float64(n) / 2.5)
	if i >= n {
		i = r.IntN(n)
	}
	return i
}

func attrs(kv ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	return m
}

func (g *gen) emit(a actor, t time.Time, name, session, screen, flow, step string, attributes map[string]any) {
	g.out = append(g.out, repository.Event{
		ReceivedAt: t.Add(time.Duration(g.r.IntN(30)) * time.Second), EventID: uuidV7(g.r, t),
		Name: name, SchemaVersion: 1, Source: registry.SourceApp, OccurredAt: t,
		UserKey: a.key, InstallID: a.install, SessionID: session, AppVersion: "1.1.0+7",
		OSName: "android", DeviceClass: "phone", Locale: "en-LK",
		Screen: screen, FlowID: flow, FlowStep: step, Attributes: attributes,
	})
}

func (g *gen) server(a actor, t time.Time, name string, attributes map[string]any) {
	g.out = append(g.out, repository.Event{
		ReceivedAt: t.Add(time.Second), EventID: uuidV7(g.r, t), Name: name, SchemaVersion: 1,
		Source: registry.SourceServer, OccurredAt: t, UserKey: a.key, Attributes: attributes,
	})
}

func uuidV7(r *rand.Rand, t time.Time) uuid.UUID {
	var u uuid.UUID
	ms := uint64(t.UnixMilli())
	for i := 0; i < 6; i++ {
		u[i] = byte(ms >> (8 * (5 - i)))
	}
	for i := 6; i < 16; i++ {
		u[i] = byte(r.Uint32())
	}
	u[6] = (u[6] & 0x0f) | 0x70
	u[8] = (u[8] & 0x3f) | 0x80
	return u
}
