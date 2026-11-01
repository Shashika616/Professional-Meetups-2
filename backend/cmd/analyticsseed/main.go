// Command analyticsseed writes a realistic week (or more) of synthetic
// analytics events into a LOCAL database and aggregates it, for trying the
// daily report and for the scalability check (plan 29F). It refuses to run
// against anything that is not localhost.
//
//	DATABASE_URL=postgres://app:app@localhost:5432/monolith_db?sslmode=disable \
//	  analyticsseed --accounts=500 --days=7 --end=2026-10-31
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	analyticsrepo "professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/modules/analytics/seed"
	"professional-meetups-monolith/backend/internal/platform/db"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "analyticsseed:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, out io.Writer) error {
	fs := flag.NewFlagSet("analyticsseed", flag.ContinueOnError)
	accounts := fs.Int("accounts", 500, "signed-in accounts")
	anonymous := fs.Int("anonymous", 0, "signed-out installs (default: a fifth of --accounts)")
	days := fs.Int("days", 7, "days of activity")
	end := fs.String("end", "", "the last day, YYYY-MM-DD (default: yesterday in Colombo)")
	seedFlag := fs.Uint64("seed", 29, "random seed (the same seed gives the same events)")
	noAggregate := fs.Bool("no-aggregate", false, "write events only")
	if err := fs.Parse(args); err != nil {
		return err
	}
	dbURL := getenv("DATABASE_URL")
	u, err := url.Parse(dbURL)
	if err != nil || dbURL == "" {
		return errors.New("DATABASE_URL is not set")
	}
	if h := u.Hostname(); h != "localhost" && h != "127.0.0.1" && h != "::1" {
		return fmt.Errorf("refusing to seed %s: synthetic data goes into local databases only", h)
	}
	loc, _ := time.LoadLocation("Asia/Colombo")
	if loc == nil {
		loc = time.FixedZone("Asia/Colombo", 5*3600+30*60)
	}
	last := time.Now().In(loc).AddDate(0, 0, -1)
	lastDay := time.Date(last.Year(), last.Month(), last.Day(), 0, 0, 0, 0, time.UTC)
	if *end != "" {
		if lastDay, err = time.Parse(time.DateOnly, *end); err != nil {
			return errors.New("--end must be YYYY-MM-DD")
		}
	}
	if *anonymous == 0 {
		*anonymous = *accounts / 5
	}
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	store := analyticsrepo.New(pool)
	started := time.Now()
	n, err := seed.Run(ctx, store, func(ctx context.Context, d time.Time) error {
		_, err := store.Q.EnsurePartition(ctx, pgtype.Date{Time: d, Valid: true})
		return err
	}, seed.Options{Accounts: *accounts, Anonymous: *anonymous, Days: *days, End: lastDay, Seed: *seedFlag, RareAccounts: 2})
	if err != nil {
		return err
	}
	_, _ = fmt.Fprintf(out, "wrote %d events for %d accounts and %d installs over %d days ending %s (%s)\n",
		n, *accounts, *anonymous, *days, lastDay.Format(time.DateOnly), time.Since(started).Round(time.Millisecond))
	if *noAggregate {
		return nil
	}
	for i := *days - 1; i >= 0; i-- {
		d := lastDay.AddDate(0, 0, -i)
		if _, err := store.Aggregate(ctx, d); err != nil {
			return err
		}
	}
	_, _ = fmt.Fprintf(out, "aggregated %d days\n", *days)
	return nil
}
