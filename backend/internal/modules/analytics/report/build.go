package report

import (
	"fmt"
	"time"

	"github.com/xuri/excelize/v2"
)

// The sheets, in plan 29 §4.5's order.
const (
	SheetSummary   = "Summary"
	SheetScreens   = "Screens"
	SheetFeatures  = "Features"
	SheetFunnels   = "Funnels"
	SheetStuck     = "Stuck"
	SheetAbandoned = "Abandoned"
	SheetCredits   = "Credits and revenue"
	SheetCohorts   = "Cohorts"
	SheetGlossary  = "Glossary"
)

// Sheets lists every sheet, in order.
var Sheets = []string{SheetSummary, SheetScreens, SheetFeatures, SheetFunnels, SheetStuck, SheetAbandoned, SheetCredits, SheetCohorts, SheetGlossary}

// FewerThan5 is what a suppressed count shows.
const FewerThan5 = "fewer than 5"

// DropThreshold colours a fall of more than 20% against the same day last
// week.
const DropThreshold = -0.20

// headerRow is the frozen table header on every sheet (rows 1-2 are the
// title and a note).
const headerRow = 3

type styles struct {
	title, note, header, integer, decimal, percent, drop, dropPct, text int
}

type book struct {
	f *excelize.File
	s styles
}

// Build renders data as an .xlsx workbook. generated is when it was made.
func Build(data *Data, generated time.Time) ([]byte, error) {
	f := excelize.NewFile()
	defer func() { _ = f.Close() }()
	b := &book{f: f}
	if err := b.styles(); err != nil {
		return nil, err
	}
	if err := f.SetSheetName("Sheet1", SheetSummary); err != nil {
		return nil, err
	}
	for _, name := range Sheets[1:] {
		if _, err := f.NewSheet(name); err != nil {
			return nil, err
		}
	}
	subtitle := fmt.Sprintf("%s (Asia/Colombo). Generated %s. Aggregates only; groups of fewer than 5 accounts are shown as \"%s\".",
		data.Date.Format("Monday 2 January 2006"), generated.In(colombo).Format("2006-01-02 15:04"), FewerThan5)
	for _, step := range []func(*Data, string) error{
		b.summary, b.screens, b.features, b.funnels, b.stuck, b.abandoned, b.credits, b.cohorts, b.glossary,
	} {
		if err := step(data, subtitle); err != nil {
			return nil, err
		}
	}
	f.SetActiveSheet(0)
	buf, err := f.WriteToBuffer()
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

var colombo = func() *time.Location {
	if loc, err := time.LoadLocation("Asia/Colombo"); err == nil {
		return loc
	}
	return time.FixedZone("Asia/Colombo", 5*3600+30*60)
}()

func (b *book) styles() error {
	var err error
	mk := func(s *excelize.Style) int {
		if err != nil {
			return 0
		}
		var id int
		id, err = b.f.NewStyle(s)
		return id
	}
	fmt0 := "#,##0"
	fmt1 := "#,##0.0"
	fmtPct := "0.0%"
	red := excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"F8CBAD"}}
	b.s.title = mk(&excelize.Style{Font: &excelize.Font{Bold: true, Size: 14}})
	b.s.note = mk(&excelize.Style{Font: &excelize.Font{Italic: true, Color: "595959"}})
	b.s.header = mk(&excelize.Style{
		Font:      &excelize.Font{Bold: true, Color: "FFFFFF"},
		Fill:      excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"1F4E79"}},
		Alignment: &excelize.Alignment{WrapText: true, Vertical: "center"},
	})
	b.s.integer = mk(&excelize.Style{CustomNumFmt: &fmt0})
	b.s.decimal = mk(&excelize.Style{CustomNumFmt: &fmt1})
	b.s.percent = mk(&excelize.Style{CustomNumFmt: &fmtPct})
	b.s.drop = mk(&excelize.Style{CustomNumFmt: &fmt0, Fill: red, Font: &excelize.Font{Color: "9C0006"}})
	b.s.dropPct = mk(&excelize.Style{CustomNumFmt: &fmtPct, Fill: red, Font: &excelize.Font{Color: "9C0006", Bold: true}})
	b.s.text = mk(&excelize.Style{Alignment: &excelize.Alignment{WrapText: true, Vertical: "top"}})
	return err
}

func cell(col, row int) string {
	name, _ := excelize.CoordinatesToCellName(col, row)
	return name
}

func (b *book) set(sheet string, col, row int, v any, style int) error {
	c := cell(col, row)
	if err := b.f.SetCellValue(sheet, c, v); err != nil {
		return err
	}
	if style != 0 {
		return b.f.SetCellStyle(sheet, c, c, style)
	}
	return nil
}

// start writes the title, the note and the frozen header row, and sets
// the column widths.
func (b *book) start(sheet, title, note string, headers []string, widths []float64) error {
	if err := b.set(sheet, 1, 1, title, b.s.title); err != nil {
		return err
	}
	if err := b.set(sheet, 1, 2, note, b.s.note); err != nil {
		return err
	}
	if err := b.headers(sheet, headerRow, 1, headers); err != nil {
		return err
	}
	for i, w := range widths {
		col, _ := excelize.ColumnNumberToName(i + 1)
		if err := b.f.SetColWidth(sheet, col, col, w); err != nil {
			return err
		}
	}
	return b.f.SetPanes(sheet, &excelize.Panes{
		Freeze: true, YSplit: headerRow, TopLeftCell: cell(1, headerRow+1), ActivePane: "bottomLeft",
	})
}

func (b *book) headers(sheet string, row, col int, headers []string) error {
	for i, h := range headers {
		if err := b.set(sheet, col+i, row, h, b.s.header); err != nil {
			return err
		}
	}
	return nil
}

// users writes an account count, suppressed below SmallGroup.
func (b *book) users(sheet string, col, row int, n int64) error {
	if n > 0 && n < SmallGroup {
		return b.set(sheet, col, row, FewerThan5, 0)
	}
	return b.set(sheet, col, row, n, b.s.integer)
}

// ratio writes num/den as a percentage, or "fewer than 5" when den counts
// accounts and is a small group, or blank when den is 0.
func (b *book) ratio(sheet string, col, row int, num, den int64, denIsUsers bool) error {
	switch {
	case den == 0:
		return nil
	case denIsUsers && den < SmallGroup:
		return b.set(sheet, col, row, FewerThan5, 0)
	default:
		return b.set(sheet, col, row, float64(num)/float64(den), b.s.percent)
	}
}

// change writes (now-then)/then as a percentage, coloured when it is a
// fall of more than 20% and colour is set. Blank when then is 0.
func (b *book) change(sheet string, col, row int, now, then float64, colour bool) error {
	if then == 0 {
		return nil
	}
	v := (now - then) / then
	style := b.s.percent
	if colour && v < DropThreshold {
		style = b.s.dropPct
	}
	return b.set(sheet, col, row, v, style)
}

// --- Summary ---

type metric struct {
	name  string
	users bool                              // an account count: suppressed when small
	ratio bool                              // a rate: value is num/den
	value func(Day) (float64, int64, int64) // value, or (num, den) for a rate
	scale string
}

func (b *book) summary(data *Data, note string) error {
	sh := SheetSummary
	if err := b.start(sh, "TieHere daily report", note,
		[]string{"Metric", "Value", "Previous day", "Change vs previous day", "Same day last week", "Change vs last week"},
		[]float64{38, 14, 14, 16, 16, 16, 3, 13, 12}); err != nil {
		return err
	}
	n := func(f func(Day) int64) func(Day) (float64, int64, int64) {
		return func(d Day) (float64, int64, int64) { return float64(f(d)), 0, 0 }
	}
	minutes := func(f func(Day) int64) func(Day) (float64, int64, int64) {
		return func(d Day) (float64, int64, int64) { return float64(f(d)) / 60000, 0, 0 }
	}
	rate := func(num, den func(Day) int64) func(Day) (float64, int64, int64) {
		return func(d Day) (float64, int64, int64) { return 0, num(d), den(d) }
	}
	metrics := []metric{
		{name: "Accounts active (DAU)", users: true, value: n(func(d Day) int64 { return d.DAU })},
		{name: "Accounts active in 7 days (WAU)", users: true, value: n(func(d Day) int64 { return d.WAU })},
		{name: "Accounts active in 30 days (MAU)", users: true, value: n(func(d Day) int64 { return d.MAU })},
		{name: "New accounts (first seen)", users: true, value: n(func(d Day) int64 { return d.NewUsers })},
		{name: "Active installs (signed in or not)", users: true, value: n(func(d Day) int64 { return d.ActiveInstalls })},
		{name: "Sessions", value: n(func(d Day) int64 { return d.Sessions })},
		{name: "Median session length (minutes)", scale: "decimal", value: minutes(func(d Day) int64 { return d.MedianSessionMs })},
		{name: "Mean session length (minutes)", scale: "decimal", value: minutes(func(d Day) int64 { return d.MeanSession })},
		{name: "D1 retention", ratio: true, value: rate(func(d Day) int64 { return d.D1Retained }, func(d Day) int64 { return d.D1Cohort })},
		{name: "D7 retention", ratio: true, value: rate(func(d Day) int64 { return d.D7Retained }, func(d Day) int64 { return d.D7Cohort })},
		{name: "Errors (shown, API, timeouts, rage taps, dwell)", value: n(func(d Day) int64 { return d.Errors })},
		{name: "Credits granted", value: n(func(d Day) int64 { return d.CreditsGranted })},
		{name: "Credits spent", value: n(func(d Day) int64 { return d.CreditsSpent })},
		{name: "Credits expired", value: n(func(d Day) int64 { return d.CreditsExpired })},
		{name: "Purchases verified", value: n(func(d Day) int64 { return d.Purchases })},
	}
	days := []Day{data.Today, data.PrevDay, data.LastWeek}
	row := headerRow + 1
	for _, m := range metrics {
		if err := b.set(sh, 1, row, m.name, 0); err != nil {
			return err
		}
		vals := make([]float64, 3)
		suppressed := make([]bool, 3)
		for i, day := range days {
			col := []int{2, 3, 5}[i]
			v, num, den := m.value(day)
			switch {
			case m.ratio:
				if den > 0 && den >= SmallGroup {
					vals[i] = float64(num) / float64(den)
				} else {
					suppressed[i] = true
				}
				if err := b.ratio(sh, col, row, num, den, true); err != nil {
					return err
				}
			case m.users:
				vals[i] = v
				suppressed[i] = v > 0 && v < SmallGroup
				if err := b.users(sh, col, row, int64(v)); err != nil {
					return err
				}
			default:
				vals[i] = v
				style := b.s.integer
				if m.scale == "decimal" {
					style = b.s.decimal
				}
				if err := b.set(sh, col, row, v, style); err != nil {
					return err
				}
			}
		}
		if !suppressed[0] && !suppressed[1] {
			if err := b.change(sh, 4, row, vals[0], vals[1], false); err != nil {
				return err
			}
		}
		if !suppressed[0] && !suppressed[2] {
			if err := b.change(sh, 6, row, vals[0], vals[2], true); err != nil {
				return err
			}
		}
		row++
	}
	if err := b.set(sh, 1, row, "Reconciliation mismatches (wallets checked)", 0); err != nil {
		return err
	}
	if r := data.Reconciliation; r != nil {
		style := b.s.integer
		if r.Mismatches > 0 {
			style = b.s.drop
		}
		if err := b.set(sh, 2, row, r.Mismatches, style); err != nil {
			return err
		}
		if err := b.set(sh, 3, row, fmt.Sprintf("of %d", r.Checked), 0); err != nil {
			return err
		}
	} else if err := b.set(sh, 2, row, "no run recorded", 0); err != nil {
		return err
	}

	// DAU over 28 days, and its chart.
	if err := b.headers(sh, headerRow, 8, []string{"Day", "DAU"}); err != nil {
		return err
	}
	for i, p := range data.DAUSeries {
		r := headerRow + 1 + i
		if err := b.set(sh, 8, r, p.Day.Format("02 Jan"), 0); err != nil {
			return err
		}
		// Small days are left blank (a gap in the line), never a number.
		// Zero is not a small group: it is shown.
		if p.Count == 0 || p.Count >= SmallGroup {
			if err := b.set(sh, 9, r, p.Count, b.s.integer); err != nil {
				return err
			}
		}
	}
	last := headerRow + len(data.DAUSeries)
	if err := b.set(sh, 8, last+1, "Blank: fewer than 5 accounts active.", b.s.note); err != nil {
		return err
	}
	return b.f.AddChart(sh, cell(11, headerRow), &excelize.Chart{
		Type: excelize.Line,
		Series: []excelize.ChartSeries{{
			Name:       fmt.Sprintf("'%s'!$I$%d", sh, headerRow),
			Categories: fmt.Sprintf("'%s'!$H$%d:$H$%d", sh, headerRow+1, last),
			Values:     fmt.Sprintf("'%s'!$I$%d:$I$%d", sh, headerRow+1, last),
		}},
		Title:     excelize.ChartTitle{Paragraph: []excelize.RichTextRun{{Text: "Accounts active per day (DAU), last 28 days"}}},
		Legend:    excelize.ChartLegend{Position: "none"},
		Dimension: excelize.ChartDimension{Width: 640, Height: 320},
	})
}

// --- Screens ---

func (b *book) screens(data *Data, note string) error {
	sh := SheetScreens
	if err := b.start(sh, "Screens", note,
		[]string{"Screen", "Views", "Unique viewers", "Median time (s)", "P90 time (s)", "Exits (last screen)", "Bounces (left within 3 s)", "Views same day last week", "Change vs last week"},
		[]float64{30, 10, 14, 14, 13, 14, 16, 16, 14}); err != nil {
		return err
	}
	for i, r := range data.Screens {
		row := headerRow + 1 + i
		if err := b.set(sh, 1, row, r.Screen, 0); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, r.Views, b.s.integer); err != nil {
			return err
		}
		if err := b.users(sh, 3, row, r.Users); err != nil {
			return err
		}
		for j, ms := range []*int64{r.MedianMs, r.P90Ms} {
			if ms != nil {
				if err := b.set(sh, 4+j, row, float64(*ms)/1000, b.s.decimal); err != nil {
					return err
				}
			}
		}
		if err := b.set(sh, 6, row, r.Exits, b.s.integer); err != nil {
			return err
		}
		if err := b.set(sh, 7, row, r.Bounces, b.s.integer); err != nil {
			return err
		}
		if err := b.set(sh, 8, row, r.ViewsLastWeek, b.s.integer); err != nil {
			return err
		}
		if err := b.change(sh, 9, row, float64(r.Views), float64(r.ViewsLastWeek), true); err != nil {
			return err
		}
	}
	return nil
}

// --- Features ---

func (b *book) features(data *Data, note string) error {
	sh := SheetFeatures
	if err := b.start(sh, "Features", note,
		[]string{"Feature", "Uses", "Accounts", "Share of active accounts", "Uses same day last week", "Change vs last week"},
		[]float64{30, 10, 12, 16, 16, 14}); err != nil {
		return err
	}
	row := headerRow + 1
	for _, r := range data.Features {
		if err := b.set(sh, 1, row, r.Feature, 0); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, r.Uses, b.s.integer); err != nil {
			return err
		}
		if err := b.users(sh, 3, row, r.Users); err != nil {
			return err
		}
		if r.Users >= SmallGroup {
			if err := b.ratio(sh, 4, row, r.Users, data.Today.DAU, true); err != nil {
				return err
			}
		} else if r.Users > 0 {
			if err := b.set(sh, 4, row, FewerThan5, 0); err != nil {
				return err
			}
		}
		if err := b.set(sh, 5, row, r.UsesLastWeek, b.s.integer); err != nil {
			return err
		}
		if err := b.change(sh, 6, row, float64(r.Uses), float64(r.UsesLastWeek), true); err != nil {
			return err
		}
		row++
	}
	row++
	if err := b.headers(sh, row, 1, []string{"Not used in the last 7 days"}); err != nil {
		return err
	}
	for _, f := range data.UnusedFeatures {
		row++
		if err := b.set(sh, 1, row, f, 0); err != nil {
			return err
		}
	}
	return nil
}

// --- Funnels ---

func (b *book) funnels(data *Data, note string) error {
	sh := SheetFunnels
	if err := b.start(sh, "Funnels", note,
		[]string{"Flow", "Step", "Entered", "Completed", "Conversion", "Drop-off", "Median time on step (s)", "", "Flow", "Whole-flow conversion"},
		[]float64{18, 20, 10, 11, 12, 10, 16, 3, 18, 14}); err != nil {
		return err
	}
	row := headerRow + 1
	chartRow := headerRow + 1
	for _, r := range data.Funnels {
		step := r.Step
		if step == "" {
			step = "(whole flow)"
		}
		if err := b.set(sh, 1, row, r.Flow, 0); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, step, 0); err != nil {
			return err
		}
		if err := b.set(sh, 3, row, r.Entered, b.s.integer); err != nil {
			return err
		}
		if err := b.set(sh, 4, row, r.Completed, b.s.integer); err != nil {
			return err
		}
		if r.Entered > 0 {
			conv := float64(r.Completed) / float64(r.Entered)
			if err := b.set(sh, 5, row, conv, b.s.percent); err != nil {
				return err
			}
			if err := b.set(sh, 6, row, 1-conv, b.s.percent); err != nil {
				return err
			}
			if r.Step == "" {
				if err := b.set(sh, 9, chartRow, r.Flow, 0); err != nil {
					return err
				}
				if err := b.set(sh, 10, chartRow, conv, b.s.percent); err != nil {
					return err
				}
				chartRow++
			}
		}
		if r.MedianStepMs != nil {
			if err := b.set(sh, 7, row, float64(*r.MedianStepMs)/1000, b.s.decimal); err != nil {
				return err
			}
		}
		row++
	}
	if chartRow == headerRow+1 {
		return nil
	}
	return b.f.AddChart(sh, cell(12, headerRow), &excelize.Chart{
		Type: excelize.Col,
		Series: []excelize.ChartSeries{{
			Name:       fmt.Sprintf("'%s'!$J$%d", sh, headerRow),
			Categories: fmt.Sprintf("'%s'!$I$%d:$I$%d", sh, headerRow+1, chartRow-1),
			Values:     fmt.Sprintf("'%s'!$J$%d:$J$%d", sh, headerRow+1, chartRow-1),
		}},
		Title:     excelize.ChartTitle{Paragraph: []excelize.RichTextRun{{Text: "Funnel conversion (started to completed)"}}},
		Legend:    excelize.ChartLegend{Position: "none"},
		Dimension: excelize.ChartDimension{Width: 560, Height: 320},
	})
}

// --- Stuck ---

var kindLabels = map[string]string{
	"error":                "Error shown",
	"api_error":            "API error",
	"timeout":              "Request timeout",
	"rage_tap":             "Rage tap",
	"long_dwell":           "Long dwell on a form step",
	"insufficient_credits": "Not enough credits shown",
}

func (b *book) stuck(data *Data, note string) error {
	sh := SheetStuck
	if err := b.start(sh, "Where people get stuck", note+" Back-and-forth loops are not measured yet.",
		[]string{"Kind", "Screen", "Detail (error kind, or route and status class)", "Count"},
		[]float64{26, 26, 44, 10}); err != nil {
		return err
	}
	for i, r := range data.Errors {
		row := headerRow + 1 + i
		label := kindLabels[r.Kind]
		if label == "" {
			label = r.Kind
		}
		for j, v := range []any{label, r.Screen, r.Detail} {
			if err := b.set(sh, 1+j, row, v, 0); err != nil {
				return err
			}
		}
		if err := b.set(sh, 4, row, r.Count, b.s.integer); err != nil {
			return err
		}
	}
	return nil
}

// --- Abandoned ---

func (b *book) abandoned(data *Data, note string) error {
	sh := SheetAbandoned
	if err := b.start(sh, "Abandoned flows", note,
		[]string{"Flow", "Started", "Completed", "Abandoned", "Left open", "Abandoned while backgrounded"},
		[]float64{20, 12, 12, 12, 12, 18}); err != nil {
		return err
	}
	background := map[string]int64{}
	for _, a := range data.Abandons {
		if a.Reason == "backgrounded" {
			background[a.Flow] += a.Count
		}
	}
	row := headerRow + 1
	for _, r := range data.Funnels {
		if r.Step != "" {
			continue
		}
		open := r.Entered - r.Completed - r.Abandoned
		if open < 0 {
			open = 0
		}
		if err := b.set(sh, 1, row, r.Flow, 0); err != nil {
			return err
		}
		for j, v := range []int64{r.Entered, r.Completed, r.Abandoned, open} {
			if err := b.set(sh, 2+j, row, v, b.s.integer); err != nil {
				return err
			}
		}
		if err := b.ratio(sh, 6, row, background[r.Flow], r.Abandoned, false); err != nil {
			return err
		}
		row++
	}
	row++
	if err := b.headers(sh, row, 1, []string{"Flow", "Stopped at step", "Reason", "Count"}); err != nil {
		return err
	}
	for _, a := range data.Abandons {
		row++
		step := a.Step
		if step == "" {
			step = "(before the first step)"
		}
		for j, v := range []any{a.Flow, step, a.Reason} {
			if err := b.set(sh, 1+j, row, v, 0); err != nil {
				return err
			}
		}
		if err := b.set(sh, 4, row, a.Count, b.s.integer); err != nil {
			return err
		}
	}
	return nil
}

// --- Credits and revenue ---

var creditLabels = map[string]string{
	"credits_granted":            "Credits granted",
	"credits_spent":              "Credits spent",
	"credits_refunded":           "Credits refunded",
	"credits_expired":            "Credits expired",
	"credits_revoked":            "Credits taken back",
	"purchase_verified":          "Purchases verified",
	"credits_insufficient_shown": "Not enough credits shown",
	"insufficient_then_purchase": "…then bought credits the same day",
}

func (b *book) credits(data *Data, note string) error {
	sh := SheetCredits
	if err := b.start(sh, "Credits and revenue", note+" Prices are the stores'; credits are whole numbers.",
		[]string{"Event", "Detail (reason or product)", "Events", "Accounts", "Credits"},
		[]float64{34, 30, 10, 12, 12}); err != nil {
		return err
	}
	row := headerRow + 1
	var shown, converted int64
	for _, r := range data.Credits {
		label := creditLabels[r.Event]
		if label == "" {
			label = r.Event
		}
		switch r.Event {
		case "credits_insufficient_shown":
			shown = r.Users
		case "insufficient_then_purchase":
			converted = r.Users
		}
		for j, v := range []any{label, r.Detail} {
			if err := b.set(sh, 1+j, row, v, 0); err != nil {
				return err
			}
		}
		if err := b.set(sh, 3, row, r.Events, b.s.integer); err != nil {
			return err
		}
		if err := b.users(sh, 4, row, r.Users); err != nil {
			return err
		}
		if err := b.set(sh, 5, row, r.Credit, b.s.integer); err != nil {
			return err
		}
		row++
	}
	row++
	if err := b.headers(sh, row, 1, []string{"Spend band (credits per meetup)", "Spends", "Credits"}); err != nil {
		return err
	}
	for _, band := range data.Bands {
		row++
		if err := b.set(sh, 1, row, band.Band, 0); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, band.Events, b.s.integer); err != nil {
			return err
		}
		if err := b.set(sh, 3, row, band.Credits, b.s.integer); err != nil {
			return err
		}
	}
	row += 2
	if err := b.headers(sh, row, 1, []string{"Not enough credits: did a purchase follow?", "Accounts"}); err != nil {
		return err
	}
	row++
	if err := b.set(sh, 1, row, "Accounts shown the prompt", 0); err != nil {
		return err
	}
	if err := b.users(sh, 2, row, shown); err != nil {
		return err
	}
	row++
	if err := b.set(sh, 1, row, "Share that bought the same day", 0); err != nil {
		return err
	}
	if err := b.ratio(sh, 2, row, converted, shown, true); err != nil {
		return err
	}
	row += 2
	if err := b.headers(sh, row, 1, []string{"Reconciliation (wallets against the ledger)", "Count"}); err != nil {
		return err
	}
	row++
	if r := data.Reconciliation; r != nil {
		if err := b.set(sh, 1, row, "Wallets checked", 0); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, r.Checked, b.s.integer); err != nil {
			return err
		}
		row++
		style := b.s.integer
		if r.Mismatches > 0 {
			style = b.s.drop
		}
		if err := b.set(sh, 1, row, "Mismatches", 0); err != nil {
			return err
		}
		return b.set(sh, 2, row, r.Mismatches, style)
	}
	return b.set(sh, 1, row, "No reconciliation run recorded for this day.", 0)
}

// --- Cohorts ---

func (b *book) cohorts(data *Data, note string) error {
	sh := SheetCohorts
	headers := []string{"Week first seen (Monday)", "Accounts"}
	for i := 0; i < CohortWeeksShown; i++ {
		headers = append(headers, fmt.Sprintf("Week %d", i))
	}
	widths := []float64{24, 11}
	for range CohortWeeksShown {
		widths = append(widths, 11)
	}
	if err := b.start(sh, "Weekly cohorts: accounts active in each week after the one they were first seen", note, headers, widths); err != nil {
		return err
	}
	row := headerRow + 1
	for _, w := range data.CohortWeeks {
		size := data.CohortSizes[w]
		if err := b.set(sh, 1, row, w.Format("2006-01-02"), 0); err != nil {
			return err
		}
		if err := b.users(sh, 2, row, size); err != nil {
			return err
		}
		for off := 0; off < CohortWeeksShown; off++ {
			if w.AddDate(0, 0, 7*off).After(data.Date) {
				break
			}
			if err := b.users(sh, 3+off, row, data.Cohorts[w][off]); err != nil {
				return err
			}
		}
		row++
	}
	row++
	if err := b.headers(sh, row, 1, append([]string{"Same, as a share of the cohort", ""}, headers[2:]...)); err != nil {
		return err
	}
	for _, w := range data.CohortWeeks {
		row++
		size := data.CohortSizes[w]
		if err := b.set(sh, 1, row, w.Format("2006-01-02"), 0); err != nil {
			return err
		}
		for off := 0; off < CohortWeeksShown; off++ {
			if w.AddDate(0, 0, 7*off).After(data.Date) {
				break
			}
			n := data.Cohorts[w][off]
			if n > 0 && n < SmallGroup {
				if err := b.set(sh, 3+off, row, FewerThan5, 0); err != nil {
					return err
				}
				continue
			}
			if err := b.ratio(sh, 3+off, row, n, size, true); err != nil {
				return err
			}
		}
	}
	return nil
}

// --- Glossary ---

// Glossary is every metric's exact definition.
var Glossary = [][2]string{
	{"Day", "An Asia/Colombo calendar day, midnight to midnight. Events count on the day the server received them."},
	{"Account", "A signed-in user, counted by a pseudonymous key. Never shown individually."},
	{"Active install", "An app installation that sent anything that day, signed in or not."},
	{"DAU / WAU / MAU", "Accounts with at least one event on the day, in the 7 days, in the 30 days ending on it."},
	{"New accounts (first seen)", "Accounts whose first event ever was on the day. Close to sign-ups, but an account that signed up and sent nothing is not counted."},
	{"Session", "App use until 30 minutes in the background. Length is from the session start to the moment the app went away."},
	{"D1 / D7 retention", "Of the accounts first seen 1 (or 7) days earlier, the share active on the day."},
	{"View", "A screen becoming visible. Coming back to a screen (closing a page or sheet over it) counts as another view."},
	{"Unique viewers", "Accounts and signed-out installs that viewed the screen."},
	{"Median / P90 time", "Time the screen was visible, excluding time in the background: half (or 90%) of visits were shorter."},
	{"Exit", "The last screen viewed in a session."},
	{"Bounce", "A screen left within 3 seconds."},
	{"Feature use", "A tap on a catalogued control (cta_tapped), a filter change, a toggle or a search."},
	{"Share of active accounts", "Accounts that used the feature divided by DAU."},
	{"Funnel: entered / completed", "For a whole flow: started and completed. For a step: viewed and completed."},
	{"Conversion / drop-off", "Completed divided by entered, and one minus that."},
	{"Median time on step", "Median time from a step being viewed to it being completed."},
	{"Left open", "Flows started but neither completed nor abandoned on the day (the app was closed, or it finishes another day)."},
	{"Abandoned while backgrounded", "Abandonments because the app spent 30 minutes or more in the background."},
	{"Error kinds", "Error shown (a failure screen or error message, by kind, never its text), API error (route pattern and status class), request timeout (no answer in 15 s), rage tap (3+ taps in a second on one spot with no screen change), long dwell (a form step a minute without input)."},
	{"Credits", "Whole credits. Granted includes welcome and admin grants; spent is meetup creation; taken back is store refunds of packs and negative adjustments."},
	{"Spend band", "Credits charged per meetup created."},
	{"Not enough credits, then bought", "Accounts shown the not-enough-credits prompt that verified a purchase later the same day."},
	{"Reconciliation", "Billing's daily check that every wallet matches its ledger. A mismatch is red and needs a look."},
	{"Cohort", "Accounts grouped by the week (Monday to Sunday) they were first seen; Week N is the Nth week after that."},
	{"Change vs last week", "Against the same weekday a week earlier. A fall of more than 20% is red."},
	{FewerThan5, "A group of 1 to 4 accounts, or a rate computed from one, is not shown so that no one can be singled out."},
}

func (b *book) glossary(_ *Data, note string) error {
	sh := SheetGlossary
	if err := b.start(sh, "Glossary", note, []string{"Term", "Definition"}, []float64{32, 100}); err != nil {
		return err
	}
	for i, g := range Glossary {
		row := headerRow + 1 + i
		if err := b.set(sh, 1, row, g[0], b.s.text); err != nil {
			return err
		}
		if err := b.set(sh, 2, row, g[1], b.s.text); err != nil {
			return err
		}
	}
	return nil
}
