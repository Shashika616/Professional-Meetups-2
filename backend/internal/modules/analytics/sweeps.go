package analytics

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// PartitionsAhead is how many days past today get a partition in advance.
const PartitionsAhead = 3

// ActivityRetentionDays is how long the per-day active-account rows stay
// (WAU, MAU, D7 retention and twelve weeks of cohorts need them).
const ActivityRetentionDays = 120

// Colombo is the report's time zone (plan 29 §4.5). Aggregates and the
// report are by Asia/Colombo calendar day; raw partitions are UTC days.
var Colombo = mustZone("Asia/Colombo")

func mustZone(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		// No tz database in the image: Sri Lanka has had no daylight
		// saving since 2006, so a fixed +05:30 is exact.
		return time.FixedZone(name, 5*3600+30*60)
	}
	return loc
}

// day is t's UTC calendar day (a partition).
func day(t time.Time) time.Time {
	y, m, d := t.UTC().Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// LocalDay is t's Asia/Colombo calendar day, as a date.
func LocalDay(t time.Time) time.Time {
	y, m, d := t.In(Colombo).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

func date(t time.Time) pgtype.Date { return pgtype.Date{Time: t, Valid: true} }

// SweepPartitions makes sure today and the next PartitionsAhead days have a
// partition, and returns how many it created. Idempotent; also run once at
// start-up so a fresh database never writes into the default partition.
func (s *Service) SweepPartitions(ctx context.Context) (int, error) {
	today := day(s.now())
	made := 0
	for i := 0; i <= PartitionsAhead; i++ {
		ok, err := s.store.Q.EnsurePartition(ctx, date(today.AddDate(0, 0, i)))
		if err != nil {
			return made, fmt.Errorf("analytics: ensure partition: %w", err)
		}
		if ok {
			made++
		}
	}
	return made, nil
}

// SweepAggregate aggregates every complete day (before today in Colombo)
// not aggregated yet, and returns how many days it did. Idempotent by date
// (analytics.aggregate_runs): a day is done once, and redoing one replaces
// its rows rather than adding to them.
func (s *Service) SweepAggregate(ctx context.Context) (int, error) {
	days, err := s.store.Q.ListDaysToAggregate(ctx, date(LocalDay(s.now())))
	if err != nil {
		return 0, fmt.Errorf("analytics: days to aggregate: %w", err)
	}
	for i, d := range days {
		if _, err := s.store.Aggregate(ctx, d.Time); err != nil {
			return i, err
		}
	}
	return len(days), nil
}

// ArchiveObject is where a day's raw events go in the bucket.
func ArchiveObject(d time.Time) string {
	return fmt.Sprintf("analytics/raw/%04d/%02d/%02d.ndjson.gz", d.Year(), int(d.Month()), d.Day())
}

// SweepRetention archives and then drops every partition older than the
// raw retention, oldest first, and returns how many it dropped.
//
// A day is always aggregated before its partition goes, so the daily
// tables never lose a day. With a bucket, a day is dropped only once its
// archive is written; a failed upload leaves the partition for the next
// tick. Without a bucket the archive is skipped with a warning and the
// partition is still dropped: the retention is what keeps the database
// inside the free tier.
func (s *Service) SweepRetention(ctx context.Context) (int, error) {
	cutoff := day(s.now()).AddDate(0, 0, -s.cfg.RawRetentionDays)
	parts, err := s.store.Q.ListPartitionsBefore(ctx, date(cutoff))
	if err != nil {
		return 0, fmt.Errorf("analytics: partitions to retire: %w", err)
	}
	dropped := 0
	for _, p := range parts {
		d := p.Day.Time
		// A UTC partition holds part of two Colombo days, its own and the
		// next: both are aggregated before it goes.
		for _, cd := range []time.Time{d, d.AddDate(0, 0, 1)} {
			aggregated, err := s.store.Q.IsAggregated(ctx, date(cd))
			if err != nil {
				return dropped, fmt.Errorf("analytics: aggregated check: %w", err)
			}
			if !aggregated {
				if _, err := s.store.Aggregate(ctx, cd); err != nil {
					return dropped, err
				}
			}
		}
		if !p.ArchivedAt.Valid {
			if s.cfg.ArchiveBucket == "" || s.archive == nil {
				s.logger.Warn("analytics: archive skipped, ANALYTICS_ARCHIVE_BUCKET is not set; dropping the raw partition anyway",
					"day", d.Format(time.DateOnly))
			} else if err := s.archiveDay(ctx, d); err != nil {
				return dropped, err
			}
		}
		if _, err := s.store.Q.DropPartition(ctx, p.Day); err != nil {
			return dropped, fmt.Errorf("analytics: drop partition: %w", err)
		}
		dropped++
	}
	if _, err := s.store.Q.DeleteActivityBefore(ctx, date(LocalDay(s.now()).AddDate(0, 0, -ActivityRetentionDays))); err != nil {
		return dropped, fmt.Errorf("analytics: activity retention: %w", err)
	}
	return dropped, nil
}

func (s *Service) archiveDay(ctx context.Context, d time.Time) error {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	n, err := s.store.ExportDay(ctx, d, zw)
	if err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	object := ArchiveObject(d)
	if err := s.archive.Upload(ctx, s.cfg.ArchiveBucket, object, buf.Bytes(), UploadOptions{
		ContentType: "application/gzip", CreateOnly: true,
	}); err != nil {
		return fmt.Errorf("analytics: archive %s: %w", d.Format(time.DateOnly), err)
	}
	uri := "gs://" + s.cfg.ArchiveBucket + "/" + object
	if err := s.store.Q.MarkPartitionArchived(ctx, markArchived(d, uri)); err != nil {
		return fmt.Errorf("analytics: mark archived: %w", err)
	}
	s.logger.Info("analytics: archived a day of raw events", "day", d.Format(time.DateOnly), "events", n, "uri", uri)
	return nil
}
