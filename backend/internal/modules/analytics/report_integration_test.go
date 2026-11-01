package analytics_test

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"

	"professional-meetups-monolith/backend/internal/modules/analytics"
	"professional-meetups-monolith/backend/internal/modules/analytics/report"
	"professional-meetups-monolith/backend/internal/modules/analytics/seed"
)

// The week the report tests seed, ending on reportDay (Asia/Colombo).
var reportDay = time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)

// colomboWindow is the SQL for one Colombo day, the same window the
// aggregates use, written out again here so the test checks the report
// against an independent query.
const colomboWindow = `received_at >= ($1::date)::timestamp AT TIME ZONE 'Asia/Colombo'
	AND received_at < ($1::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'`

type fakeMailer struct {
	mu   sync.Mutex
	sent []analytics.ReportMail
	fail error
}

func (m *fakeMailer) SendReport(_ context.Context, r analytics.ReportMail) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		return m.fail
	}
	m.sent = append(m.sent, r)
	return nil
}

func (m *fakeMailer) count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sent)
}

// seedWeek writes the seeded week and aggregates every day of it.
func seedWeek(t *testing.T, h *harness) {
	t.Helper()
	ctx := context.Background()
	n, err := seed.Run(ctx, h.store, func(ctx context.Context, d time.Time) error {
		_, err := h.store.Q.EnsurePartition(ctx, date(d))
		return err
	}, seed.Options{Accounts: 300, Anonymous: 60, Days: 10, End: reportDay, Seed: 29, RareAccounts: 2})
	if err != nil {
		t.Fatal(err)
	}
	if n < 5000 {
		t.Fatalf("seeded only %d events", n)
	}
	for i := 9; i >= 0; i-- {
		if _, err := h.store.Aggregate(ctx, reportDay.AddDate(0, 0, -i)); err != nil {
			t.Fatal(err)
		}
	}
}

func (h *harness) sqlInt(t *testing.T, query string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := h.pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("%v: %s", err, query)
	}
	return n
}

// rowWith finds the row whose column-A text is label.
func rowWith(t *testing.T, rows [][]string, label string) []string {
	t.Helper()
	for _, r := range rows {
		if len(r) > 0 && r[0] == label {
			return r
		}
	}
	t.Fatalf("no row %q", label)
	return nil
}

func num(t *testing.T, s string) int64 {
	t.Helper()
	n, err := strconv.ParseFloat(strings.ReplaceAll(s, ",", ""), 64)
	if err != nil {
		t.Fatalf("%q is not a number", s)
	}
	return int64(n)
}

func TestTheReportFromSeededDataMatchesSQL(t *testing.T) {
	h := newHarness(t)
	h.clock.Set(time.Date(2026, 10, 26, 7, 0, 0, 0, analytics.Colombo))
	seedWeek(t, h)
	ctx := context.Background()

	body, err := h.svc.BuildReport(ctx, reportDay, false)
	if err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenReader(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()

	if got := f.GetSheetList(); strings.Join(got, "|") != strings.Join(report.Sheets, "|") {
		t.Fatalf("sheets = %v", got)
	}
	sheets := map[string][][]string{}
	for _, name := range report.Sheets {
		rows, err := f.GetRows(name)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) < 5 {
			t.Errorf("sheet %s has no data (%d rows)", name, len(rows))
		}
		sheets[name] = rows
	}

	// Summary: DAU, credits spent, purchases.
	summary := sheets[report.SheetSummary]
	dau := h.sqlInt(t, `SELECT count(DISTINCT user_key) FROM analytics.events WHERE user_key IS NOT NULL AND `+colomboWindow, reportDay)
	if got := num(t, rowWith(t, summary, "Accounts active (DAU)")[1]); got != dau {
		t.Errorf("DAU %d, SQL %d", got, dau)
	}
	spent := h.sqlInt(t, `SELECT coalesce(sum((attributes->>'credits')::bigint),0) FROM analytics.events WHERE event_name='credits_spent' AND `+colomboWindow, reportDay)
	if got := num(t, rowWith(t, summary, "Credits spent")[1]); got != spent || spent == 0 {
		t.Errorf("credits spent %d, SQL %d", got, spent)
	}
	purchases := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='purchase_verified' AND `+colomboWindow, reportDay)
	if got := num(t, rowWith(t, summary, "Purchases verified")[1]); got != purchases {
		t.Errorf("purchases %d, SQL %d", got, purchases)
	}
	wau := h.sqlInt(t, `SELECT count(DISTINCT user_key) FROM analytics.events WHERE user_key IS NOT NULL
		AND received_at >= ($1::date - 6)::timestamp AT TIME ZONE 'Asia/Colombo'
		AND received_at < ($1::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'`, reportDay)
	if got := num(t, rowWith(t, summary, "Accounts active in 7 days (WAU)")[1]); got != wau {
		t.Errorf("WAU %d, SQL %d", got, wau)
	}

	// Screens: every row's views, and the rare screen's viewers suppressed.
	screens := sheets[report.SheetScreens]
	checked := 0
	for _, r := range screens[3:] {
		views := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='screen_viewed' AND screen=$2 AND `+colomboWindow, reportDay, r[0])
		if num(t, r[1]) != views {
			t.Errorf("screen %s: %s views, SQL %d", r[0], r[1], views)
		}
		checked++
	}
	if checked < 5 {
		t.Errorf("only %d screens", checked)
	}
	if rare := rowWith(t, screens, seed.RareScreen); rare[2] != report.FewerThan5 {
		t.Errorf("rare screen viewers = %q, want %q", rare[2], report.FewerThan5)
	}

	// Funnels: the schedule flow's whole-flow entries and completions.
	for _, r := range sheets[report.SheetFunnels][3:] {
		if len(r) < 4 || r[0] != "schedule_meetup" || r[1] != "(whole flow)" {
			continue
		}
		started := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='flow_started' AND flow_id='schedule_meetup' AND `+colomboWindow, reportDay)
		completed := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='flow_completed' AND flow_id='schedule_meetup' AND `+colomboWindow, reportDay)
		if num(t, r[2]) != started || num(t, r[3]) != completed {
			t.Errorf("schedule funnel %s/%s, SQL %d/%d", r[2], r[3], started, completed)
		}
		checked = -1
	}
	if checked != -1 {
		t.Error("no schedule_meetup row on the Funnels sheet")
	}

	// Stuck: the counts add up to the friction events.
	var stuck int64
	for _, r := range sheets[report.SheetStuck][3:] {
		stuck += num(t, r[3])
	}
	friction := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name IN ('error_shown','api_error','request_timeout','rage_tap','long_dwell','credits_insufficient_shown') AND `+colomboWindow, reportDay)
	if stuck != friction {
		t.Errorf("stuck total %d, SQL %d", stuck, friction)
	}

	// Features: the most used control's uses.
	top := sheets[report.SheetFeatures][3]
	uses := h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='cta_tapped' AND attributes->>'cta'=$2 AND `+colomboWindow, reportDay, top[0])
	if strings.HasPrefix(top[0], "filter:") {
		uses = h.sqlInt(t, `SELECT count(*) FROM analytics.events WHERE event_name='filter_changed' AND `+colomboWindow, reportDay)
	}
	if num(t, top[1]) != uses {
		t.Errorf("feature %s: %s uses, SQL %d", top[0], top[1], uses)
	}

	// The two charts are in the package, pointing at their tables.
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatal(err)
	}
	charts := map[string]string{}
	for _, file := range zr.File {
		if strings.HasPrefix(file.Name, "xl/charts/chart") {
			rc, _ := file.Open()
			raw, _ := io.ReadAll(rc)
			_ = rc.Close()
			charts[file.Name] = string(raw)
		}
	}
	if len(charts) != 2 {
		t.Fatalf("charts: %v", len(charts))
	}
	all := strings.Join([]string{charts["xl/charts/chart1.xml"], charts["xl/charts/chart2.xml"]}, "")
	for _, ref := range []string{"<lineChart", "Summary&#39;!$I$4:$I$31", "<barChart", "Funnels&#39;!$J$4"} {
		if !strings.Contains(all, ref) {
			t.Errorf("no %q in the charts", ref)
		}
	}

	// No personal data, no key, no id in any cell.
	keyLike := regexp.MustCompile(`[0-9a-f]{32,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-`)
	for name, rows := range sheets {
		for i, r := range rows {
			for j, c := range r {
				if keyLike.MatchString(c) || strings.Contains(c, "@") {
					t.Errorf("%s!R%dC%d holds %q", name, i+1, j+1, c)
				}
			}
		}
	}
}

func TestTheDailyRunIsIdempotentAndRetriesOnlyWhatFailed(t *testing.T) {
	// The relay's refusal echoes the address, as Gmail's do.
	mailer := &fakeMailer{fail: errors.New("550 5.1.1 <ops@example.com>: recipient rejected")}
	h := newHarness(t, func(d *analytics.Deps) {
		d.Mailer = mailer
		d.Config.ReportRecipients = []string{"ops@example.com"}
	})
	seedWeek(t, h)
	ctx := context.Background()

	// Before 06:00 Colombo: nothing.
	h.clock.Set(time.Date(2026, 10, 26, 5, 59, 0, 0, analytics.Colombo))
	if n, err := h.svc.SweepReport(ctx); err != nil || n != 0 {
		t.Fatalf("before six: %d, %v", n, err)
	}
	var runs int
	_ = h.pool.QueryRow(ctx, `SELECT count(*) FROM analytics.report_runs`).Scan(&runs)
	if runs != 0 || len(h.upload.objects) != 0 {
		t.Fatalf("before six it claimed %d runs and uploaded %d", runs, len(h.upload.objects))
	}
	// After: built and uploaded, but the email fails.
	h.clock.Set(time.Date(2026, 10, 26, 6, 5, 0, 0, analytics.Colombo))
	if n, err := h.svc.SweepReport(ctx); err != nil || n != 0 {
		t.Fatalf("first run: %d, %v", n, err)
	}
	if len(h.upload.objects) != 1 || h.upload.objects["tiehere-test-bucket/analytics/reports/2026-10-25.xlsx"] == nil {
		t.Fatalf("uploads: %v", keys(h.upload.objects))
	}
	var status string
	_ = h.pool.QueryRow(ctx, `SELECT status FROM analytics.report_runs WHERE day='2026-10-25'`).Scan(&status)
	if status != "failed" {
		t.Fatalf("status %q after a failed email", status)
	}
	var detail string
	_ = h.pool.QueryRow(ctx, `SELECT detail FROM analytics.report_runs WHERE day='2026-10-25'`).Scan(&detail)
	if strings.Contains(detail, "@") || !strings.Contains(detail, "recipient rejected") {
		t.Errorf("detail %q: the address must be redacted, the reason kept", detail)
	}

	// Next tick: only the email is retried; the upload is not repeated.
	mailer.fail = nil
	h.upload.objects = map[string][]byte{}
	if n, err := h.svc.SweepReport(ctx); err != nil || n != 1 {
		t.Fatalf("retry: %d, %v", n, err)
	}
	if mailer.count() != 1 || len(h.upload.objects) != 0 {
		t.Errorf("retry sent %d emails and %d uploads, want 1 and 0", mailer.count(), len(h.upload.objects))
	}
	m := mailer.sent[0]
	if m.Filename != "tiehere-report-2026-10-25.xlsx" || m.ContentType != analytics.XLSXType || len(m.Data) == 0 || m.To[0] != "ops@example.com" {
		t.Errorf("mail %+v", m.Filename)
	}

	// Done: later ticks do nothing.
	h.clock.Set(time.Date(2026, 10, 26, 12, 0, 0, 0, analytics.Colombo))
	if n, err := h.svc.SweepReport(ctx); err != nil || n != 0 {
		t.Errorf("after done: %d, %v", n, err)
	}
	if mailer.count() != 1 {
		t.Errorf("emailed %d times", mailer.count())
	}
}

func TestRegenerationOverwritesCleanly(t *testing.T) {
	h := newHarness(t)
	seedWeek(t, h)
	ctx := context.Background()
	h.clock.Set(time.Date(2026, 10, 27, 9, 0, 0, 0, analytics.Colombo))
	first, err := h.svc.RegenerateReport(ctx, reportDay, true)
	if err != nil {
		t.Fatal(err)
	}
	object := "tiehere-test-bucket/analytics/reports/2026-10-25.xlsx"
	if !bytes.Equal(h.upload.objects[object], first) {
		t.Fatal("the upload is not the report")
	}
	second, err := h.svc.RegenerateReport(ctx, reportDay, true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(h.upload.objects[object], second) {
		t.Error("the second run did not replace the stored report")
	}
	var status string
	var attempts int
	_ = h.pool.QueryRow(ctx, `SELECT status, attempts FROM analytics.report_runs WHERE day='2026-10-25'`).Scan(&status, &attempts)
	if status != "done" || attempts != 2 {
		t.Errorf("run = %s after %d", status, attempts)
	}
	// The aggregates were rebuilt, not doubled.
	var views int64
	_ = h.pool.QueryRow(ctx, `SELECT count(*) FROM analytics.daily_screen_stats WHERE day='2026-10-25' AND screen='home'`).Scan(&views)
	if views != 1 {
		t.Errorf("%d home rows for the day after two regenerations", views)
	}
}

// An email that went out is not sent again when only the upload failed.
func TestAnEmailAlreadySentIsNotSentAgain(t *testing.T) {
	mailer := &fakeMailer{}
	h := newHarness(t, func(d *analytics.Deps) {
		d.Mailer = mailer
		d.Config.ReportRecipients = []string{"ops@example.com"}
	})
	seedWeek(t, h)
	ctx := context.Background()
	h.upload.fail = errors.New("bucket unavailable")
	h.clock.Set(time.Date(2026, 10, 26, 6, 30, 0, 0, analytics.Colombo))
	if n, _ := h.svc.SweepReport(ctx); n != 0 {
		t.Fatal("finished despite a failed upload")
	}
	h.upload.fail = nil
	if n, err := h.svc.SweepReport(ctx); err != nil || n != 1 {
		t.Fatalf("retry: %d, %v", n, err)
	}
	if mailer.count() != 1 {
		t.Errorf("emailed %d times, want once", mailer.count())
	}
	if h.upload.objects["tiehere-test-bucket/analytics/reports/2026-10-25.xlsx"] == nil {
		t.Error("the retry did not upload")
	}
}

// Regenerating a day that is not over would record it as aggregated and
// reported, so neither would be redone once it is complete: refused.
func TestRegeneratingADayThatIsNotOverIsRefused(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	h.clock.Set(time.Date(2026, 10, 25, 18, 0, 0, 0, analytics.Colombo))
	if _, err := h.svc.RegenerateReport(ctx, reportDay, false); !errors.Is(err, analytics.ErrDayNotOver) {
		t.Fatalf("today: err = %v, want ErrDayNotOver", err)
	}
	if _, err := h.svc.RegenerateReport(ctx, reportDay.AddDate(0, 0, 1), false); !errors.Is(err, analytics.ErrDayNotOver) {
		t.Fatalf("tomorrow: err = %v, want ErrDayNotOver", err)
	}
	var runs, aggregated int
	_ = h.pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM analytics.report_runs), (SELECT count(*) FROM analytics.aggregate_runs)`).Scan(&runs, &aggregated)
	if runs != 0 || aggregated != 0 {
		t.Errorf("a refused regeneration recorded %d runs and %d aggregates", runs, aggregated)
	}
}
