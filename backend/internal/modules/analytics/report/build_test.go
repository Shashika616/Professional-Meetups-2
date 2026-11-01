package report

import (
	"bytes"
	"testing"
	"time"

	"github.com/xuri/excelize/v2"
)

func open(t *testing.T, data *Data) *excelize.File {
	t.Helper()
	body, err := Build(data, time.Date(2026, 11, 1, 1, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	f, err := excelize.OpenReader(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.Close() })
	return f
}

func value(t *testing.T, f *excelize.File, sheet, cell string) string {
	t.Helper()
	v, err := f.GetCellValue(sheet, cell)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestSmallGroupsAreSuppressedEverywhere(t *testing.T) {
	day := time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)
	data := &Data{
		Date:      day,
		Today:     Day{DAU: 3, WAU: 40, D1Cohort: 4, D1Retained: 2, D7Cohort: 20, D7Retained: 5},
		PrevDay:   Day{DAU: 10, WAU: 38},
		LastWeek:  Day{DAU: 50, WAU: 60},
		DAUSeries: []DayCount{{day.AddDate(0, 0, -2), 0}, {day.AddDate(0, 0, -1), 3}, {day, 12}},
		Screens:   []ScreenRow{{Screen: "home", Views: 9, Users: 2, ViewsLastWeek: 20}},
		Features:  []FeatureRow{{Feature: "sos", Uses: 4, Users: 4}},
		Credits:   []CreditRow{{Event: "credits_spent", Detail: "capture", Events: 3, Users: 3, Credit: 42}},
	}
	f := open(t, data)
	for _, c := range []struct{ sheet, cell, want string }{
		{SheetSummary, "B4", FewerThan5},  // DAU 3
		{SheetSummary, "B5", "40"},        // WAU 40
		{SheetSummary, "D4", ""},          // no change from a suppressed value
		{SheetSummary, "F4", ""},          // nor against last week
		{SheetSummary, "B12", FewerThan5}, // D1 from a cohort of 4
		{SheetSummary, "B13", "25.0%"},    // D7 5 of 20
		{SheetSummary, "I4", "0"},         // a zero day is shown
		{SheetSummary, "I5", ""},          // a day of 3 is blank
		{SheetSummary, "I6", "12"},
		{SheetScreens, "B4", "9"}, // views are events, shown
		{SheetScreens, "C4", FewerThan5},
		{SheetFeatures, "C4", FewerThan5},
		{SheetFeatures, "D4", FewerThan5}, // a share of a small group
		{SheetCredits, "D4", FewerThan5},
		{SheetCredits, "E4", "42"},
	} {
		if got := value(t, f, c.sheet, c.cell); got != c.want {
			t.Errorf("%s!%s = %q, want %q", c.sheet, c.cell, got, c.want)
		}
	}
}

func TestADropOfMoreThanTwentyPercentIsRed(t *testing.T) {
	day := time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)
	f := open(t, &Data{
		Date:     day,
		Today:    Day{Sessions: 70, Errors: 81},
		LastWeek: Day{Sessions: 100, Errors: 100},
		Screens:  []ScreenRow{{Screen: "home", Views: 79, Users: 50, ViewsLastWeek: 100}, {Screen: "events", Views: 81, Users: 50, ViewsLastWeek: 100}},
	})
	fill := func(sheet, cell string) string {
		id, err := f.GetCellStyle(sheet, cell)
		if err != nil {
			t.Fatal(err)
		}
		st, err := f.GetStyle(id)
		if err != nil {
			t.Fatal(err)
		}
		if len(st.Fill.Color) == 0 {
			return ""
		}
		return st.Fill.Color[0]
	}
	if fill(SheetSummary, "F9") == "" { // sessions -30%
		t.Error("a 30% fall in sessions is not coloured")
	}
	if fill(SheetSummary, "F14") != "" { // errors -19%
		t.Error("a 19% fall is coloured")
	}
	if fill(SheetScreens, "I4") == "" || fill(SheetScreens, "I5") != "" {
		t.Error("screen drops: -21% must be red, -19% not")
	}
}

func TestEverySheetHasAFrozenHeader(t *testing.T) {
	f := open(t, &Data{Date: time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)})
	for _, sheet := range Sheets {
		panes, err := f.GetPanes(sheet)
		if err != nil {
			t.Fatal(err)
		}
		if !panes.Freeze || panes.YSplit != headerRow {
			t.Errorf("%s: panes %+v", sheet, panes)
		}
	}
}
