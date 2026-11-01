// Package report builds the daily analytics workbook (plan 29 §4.5, 29F)
// from the analytics.daily_* aggregates: nine sheets, aggregates only.
//
// # NOTHING ABOUT A PERSON
//
// Every figure is a count, a sum, a median or a ratio. No user key, id,
// name or free text reaches a cell (a test scans every cell of a generated
// workbook). A count of fewer than five accounts is printed as "fewer than
// 5", and so is anything derived from one (a share, a retention rate), so a
// small group cannot be singled out.
package report

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/analytics/registry"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository/sqlcgen"
)

// SmallGroup is the smallest number of accounts a cell may show (plan 29F).
const SmallGroup = 5

// Reconciliation is billing's daily check, as the report shows it: counts
// only, never which wallets.
type Reconciliation struct {
	Checked    int64
	Mismatches int64
}

// ReconciliationSource reads billing's run for a day (an adapter over the
// billing module; analytics never reads its schema). found is false when no
// run exists for the day.
type ReconciliationSource interface {
	Reconciliation(ctx context.Context, day time.Time) (r Reconciliation, found bool, err error)
}

// Day is one day's headline figures.
type Day struct {
	DAU, WAU, MAU, NewUsers      int64
	ActiveInstalls, Sessions     int64
	MedianSessionMs, MeanSession int64
	D1Cohort, D1Retained         int64
	D7Cohort, D7Retained         int64
	Errors                       int64
	CreditsGranted, CreditsSpent int64
	CreditsExpired, Purchases    int64
}

type ScreenRow struct {
	Screen          string
	Views, Users    int64
	MedianMs, P90Ms *int64
	Bounces, Exits  int64
	ViewsLastWeek   int64
}

type FeatureRow struct {
	Feature      string
	Uses, Users  int64
	UsesLastWeek int64
}

type FunnelRow struct {
	Flow, Step                    string
	Entered, Completed, Abandoned int64
	MedianStepMs                  *int64
}

type ErrorRow struct {
	Kind, Screen, Detail string
	Count                int64
}

type AbandonRow struct {
	Flow, Step, Reason string
	Count              int64
}

type CreditRow struct {
	Event, Detail         string
	Events, Users, Credit int64
}

type BandRow struct {
	Band            string
	Events, Credits int64
}

type DayCount struct {
	Day   time.Time
	Count int64
}

// Data is everything one report shows.
type Data struct {
	Date                     time.Time // the Colombo day reported
	Today, PrevDay, LastWeek Day
	DAUSeries                []DayCount // the 28 days ending on Date
	Screens                  []ScreenRow
	Features                 []FeatureRow
	UnusedFeatures           []string // catalogued, not used in the last 7 days
	Funnels                  []FunnelRow
	Errors                   []ErrorRow
	Abandons                 []AbandonRow
	Credits                  []CreditRow
	Bands                    []BandRow
	Reconciliation           *Reconciliation
	CohortWeeks              []time.Time
	CohortSizes              map[time.Time]int64
	Cohorts                  map[time.Time]map[int]int64 // week → week offset → active accounts
}

// CohortWeeksShown is how many weekly cohorts the report shows.
const CohortWeeksShown = 8

func d(t time.Time) pgtype.Date { return pgtype.Date{Time: t, Valid: true} }

// Load reads one day's report data. recon may be nil.
func Load(ctx context.Context, q *sqlcgen.Queries, reg *registry.Registry, date time.Time, recon ReconciliationSource) (*Data, error) {
	data := &Data{Date: date}
	var err error
	if data.Today, err = loadDay(ctx, q, date); err != nil {
		return nil, err
	}
	if data.PrevDay, err = loadDay(ctx, q, date.AddDate(0, 0, -1)); err != nil {
		return nil, err
	}
	if data.LastWeek, err = loadDay(ctx, q, date.AddDate(0, 0, -7)); err != nil {
		return nil, err
	}

	series, err := q.ReportDailyActive(ctx, sqlcgen.ReportDailyActiveParams{FromDay: d(date.AddDate(0, 0, -27)), ToDay: d(date)})
	if err != nil {
		return nil, fmt.Errorf("report: daily active: %w", err)
	}
	byDay := map[time.Time]int64{}
	for _, r := range series {
		byDay[r.Day.Time] = r.Users
	}
	for i := 27; i >= 0; i-- {
		day := date.AddDate(0, 0, -i)
		data.DAUSeries = append(data.DAUSeries, DayCount{Day: day, Count: byDay[day]})
	}

	screens, err := q.ReportScreens(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: screens: %w", err)
	}
	lastScreens, err := q.ReportScreens(ctx, d(date.AddDate(0, 0, -7)))
	if err != nil {
		return nil, fmt.Errorf("report: screens last week: %w", err)
	}
	lastViews := map[string]int64{}
	for _, r := range lastScreens {
		lastViews[r.Screen] = r.Views
	}
	for _, r := range screens {
		data.Screens = append(data.Screens, ScreenRow{
			Screen: r.Screen, Views: r.Views, Users: r.UniqueUsers,
			MedianMs: ptr(r.MedianMs), P90Ms: ptr(r.P90Ms), Bounces: r.Bounces, Exits: r.Exits,
			ViewsLastWeek: lastViews[r.Screen],
		})
	}

	features, err := q.ReportFeatures(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: features: %w", err)
	}
	lastFeatures, err := q.ReportFeatures(ctx, d(date.AddDate(0, 0, -7)))
	if err != nil {
		return nil, fmt.Errorf("report: features last week: %w", err)
	}
	lastUses := map[string]int64{}
	for _, r := range lastFeatures {
		lastUses[r.Feature] = r.Uses
	}
	for _, r := range features {
		data.Features = append(data.Features, FeatureRow{Feature: r.Feature, Uses: r.Uses, Users: r.UniqueUsers, UsesLastWeek: lastUses[r.Feature]})
	}
	used, err := q.ReportFeaturesUsed(ctx, sqlcgen.ReportFeaturesUsedParams{FromDay: d(date.AddDate(0, 0, -6)), ToDay: d(date)})
	if err != nil {
		return nil, fmt.Errorf("report: features used: %w", err)
	}
	usedSet := map[string]bool{}
	for _, f := range used {
		usedSet[f] = true
	}
	for _, cta := range reg.CTAs {
		if !usedSet[cta] {
			data.UnusedFeatures = append(data.UnusedFeatures, cta)
		}
	}

	funnels, err := q.ReportFunnels(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: funnels: %w", err)
	}
	for _, r := range funnels {
		data.Funnels = append(data.Funnels, FunnelRow{
			Flow: r.FlowID, Step: r.Step, Entered: r.Entered, Completed: r.Completed,
			Abandoned: r.Abandoned, MedianStepMs: ptr(r.MedianStepMs),
		})
	}
	sortFunnels(data.Funnels, reg)

	errs, err := q.ReportErrors(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: errors: %w", err)
	}
	for _, r := range errs {
		data.Errors = append(data.Errors, ErrorRow{Kind: r.Kind, Screen: r.Screen, Detail: r.Detail, Count: r.Count})
	}

	abandons, err := q.ReportAbandons(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: abandons: %w", err)
	}
	for _, r := range abandons {
		data.Abandons = append(data.Abandons, AbandonRow{Flow: r.FlowID, Step: r.Step, Reason: r.Reason, Count: r.Count})
	}

	credits, err := q.ReportCredits(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: credits: %w", err)
	}
	for _, r := range credits {
		data.Credits = append(data.Credits, CreditRow{Event: r.EventName, Detail: r.Detail, Events: r.Events, Users: r.Users, Credit: r.Credits})
	}
	bands, err := q.ReportCreditBands(ctx, d(date))
	if err != nil {
		return nil, fmt.Errorf("report: credit bands: %w", err)
	}
	for _, r := range bands {
		data.Bands = append(data.Bands, BandRow{Band: r.Band, Events: r.Events, Credits: r.Credits})
	}
	if recon != nil {
		r, found, err := recon.Reconciliation(ctx, date)
		if err != nil {
			return nil, fmt.Errorf("report: reconciliation: %w", err)
		}
		if found {
			data.Reconciliation = &r
		}
	}

	// Cohorts: the last CohortWeeksShown weeks, Monday-based.
	monday := date.AddDate(0, 0, -((int(date.Weekday()) + 6) % 7))
	from := monday.AddDate(0, 0, -7*(CohortWeeksShown-1))
	sizes, err := q.ReportCohortSizes(ctx, sqlcgen.ReportCohortSizesParams{FromWeek: d(from), ToDay: d(date)})
	if err != nil {
		return nil, fmt.Errorf("report: cohort sizes: %w", err)
	}
	cells, err := q.ReportCohorts(ctx, sqlcgen.ReportCohortsParams{FromWeek: d(from), ToDay: d(date)})
	if err != nil {
		return nil, fmt.Errorf("report: cohorts: %w", err)
	}
	data.CohortSizes = map[time.Time]int64{}
	data.Cohorts = map[time.Time]map[int]int64{}
	for i := 0; i < CohortWeeksShown; i++ {
		data.CohortWeeks = append(data.CohortWeeks, from.AddDate(0, 0, 7*i))
	}
	for _, r := range sizes {
		data.CohortSizes[r.CohortWeek.Time] = r.Users
	}
	for _, r := range cells {
		if data.Cohorts[r.CohortWeek.Time] == nil {
			data.Cohorts[r.CohortWeek.Time] = map[int]int64{}
		}
		data.Cohorts[r.CohortWeek.Time][int(r.WeekOffset)] = r.Users
	}
	return data, nil
}

func loadDay(ctx context.Context, q *sqlcgen.Queries, day time.Time) (Day, error) {
	var out Day
	var err error
	active := func(from time.Time) (int64, error) {
		return q.ReportActiveUsers(ctx, sqlcgen.ReportActiveUsersParams{FromDay: d(from), ToDay: d(day)})
	}
	if out.DAU, err = active(day); err != nil {
		return out, fmt.Errorf("report: dau: %w", err)
	}
	if out.WAU, err = active(day.AddDate(0, 0, -6)); err != nil {
		return out, fmt.Errorf("report: wau: %w", err)
	}
	if out.MAU, err = active(day.AddDate(0, 0, -29)); err != nil {
		return out, fmt.Errorf("report: mau: %w", err)
	}
	if out.NewUsers, err = q.ReportNewUsers(ctx, d(day)); err != nil {
		return out, fmt.Errorf("report: new users: %w", err)
	}
	sessions, err := q.ReportSessions(ctx, d(day))
	if err != nil {
		return out, fmt.Errorf("report: sessions: %w", err)
	}
	if len(sessions) == 1 {
		s := sessions[0]
		out.ActiveInstalls, out.Sessions = s.Users, s.Sessions
		out.MedianSessionMs, out.MeanSession = s.MedianSessionMs.Int64, s.MeanSessionMs.Int64
	}
	d1, err := q.ReportRetention(ctx, sqlcgen.ReportRetentionParams{CohortDay: d(day.AddDate(0, 0, -1)), ActiveDay: d(day)})
	if err != nil {
		return out, fmt.Errorf("report: d1: %w", err)
	}
	d7, err := q.ReportRetention(ctx, sqlcgen.ReportRetentionParams{CohortDay: d(day.AddDate(0, 0, -7)), ActiveDay: d(day)})
	if err != nil {
		return out, fmt.Errorf("report: d7: %w", err)
	}
	out.D1Cohort, out.D1Retained, out.D7Cohort, out.D7Retained = d1.Cohort, d1.Retained, d7.Cohort, d7.Retained
	errs, err := q.ReportErrors(ctx, d(day))
	if err != nil {
		return out, fmt.Errorf("report: errors: %w", err)
	}
	for _, e := range errs {
		out.Errors += e.Count
	}
	credits, err := q.ReportCredits(ctx, d(day))
	if err != nil {
		return out, fmt.Errorf("report: credits: %w", err)
	}
	for _, c := range credits {
		switch c.EventName {
		case "credits_granted":
			out.CreditsGranted += c.Credits
		case "credits_spent":
			out.CreditsSpent += c.Credits
		case "credits_expired":
			out.CreditsExpired += c.Credits
		case "purchase_verified":
			out.Purchases += c.Events
		}
	}
	return out, nil
}

// sortFunnels orders rows by flow name, then the flow's own row (”) first
// and the steps in the registry's order.
func sortFunnels(rows []FunnelRow, reg *registry.Registry) {
	order := map[string]map[string]int{}
	for flow, steps := range reg.Flows {
		order[flow] = map[string]int{"": -1}
		for i, s := range steps {
			order[flow][s] = i
		}
	}
	rank := func(r FunnelRow) int {
		if o, ok := order[r.Flow][r.Step]; ok {
			return o
		}
		return 1 << 20
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].Flow != rows[j].Flow {
			return rows[i].Flow < rows[j].Flow
		}
		return rank(rows[i]) < rank(rows[j])
	})
}

func ptr(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	n := v.Int64
	return &n
}
