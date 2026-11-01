package analytics

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"professional-meetups-monolith/backend/internal/modules/analytics/report"
	"professional-meetups-monolith/backend/internal/modules/analytics/repository/sqlcgen"
	"professional-meetups-monolith/backend/internal/platform/metrics"
)

// The daily report (plan 29 §4.5, 29F).
const (
	// ReportHour is when, in Colombo, the previous day's report is made.
	ReportHour = 6
	// MaxReportAttempts bounds the retries for one day: a report still
	// failing after a day of ticks needs a person, not another try.
	MaxReportAttempts = 24
	// XLSXType is the report's content type.
	XLSXType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
)

// ReportMail is the report as the mailer sends it.
type ReportMail struct {
	To                    []string
	Subject, Body         string
	Filename, ContentType string
	Data                  []byte
}

// ReportMailer sends the report (an adapter over the email sender; the
// analytics module never imports another module's packages).
type ReportMailer interface {
	SendReport(ctx context.Context, m ReportMail) error
}

// ReportObject is where a day's report goes in the bucket.
func ReportObject(day time.Time) string {
	return "analytics/reports/" + day.Format("2006-01-02") + ".xlsx"
}

// ReportFilename is the attachment's name.
func ReportFilename(day time.Time) string {
	return "tiehere-report-" + day.Format("2006-01-02") + ".xlsx"
}

// BuildReport aggregates day if it has not been (or always, with fresh),
// and renders its workbook.
func (s *Service) BuildReport(ctx context.Context, day time.Time, fresh bool) ([]byte, error) {
	if !fresh {
		done, err := s.store.Q.IsAggregated(ctx, date(day))
		if err != nil {
			return nil, fmt.Errorf("analytics: report: aggregated check: %w", err)
		}
		fresh = !done
	}
	if fresh {
		if _, err := s.store.Aggregate(ctx, day); err != nil {
			return nil, err
		}
	}
	data, err := report.Load(ctx, s.store.Q, s.registry, day, s.reconciliation)
	if err != nil {
		return nil, err
	}
	return report.Build(data, s.now())
}

// SweepReport makes yesterday's report once a day, after ReportHour in
// Colombo: idempotent by date (analytics.report_runs), and a failed
// delivery is retried on the next tick, repeating only the part that
// failed (an email already sent is not sent again). Returns 1 when a
// report was finished.
func (s *Service) SweepReport(ctx context.Context) (int, error) {
	now := s.now()
	if now.In(Colombo).Hour() < ReportHour {
		return 0, nil
	}
	day := LocalDay(now).AddDate(0, 0, -1)
	claim, err := s.store.Q.ClaimReportRun(ctx, sqlcgen.ClaimReportRunParams{Day: date(day), MaxAttempts: MaxReportAttempts})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil // done, held by another tick, or out of attempts
	}
	if err != nil {
		return 0, fmt.Errorf("analytics: report: claim: %w", err)
	}
	body, err := s.BuildReport(ctx, day, false)
	if err != nil {
		metrics.Default.AnalyticsReports.WithLabelValues("build", "failed").Inc()
		s.finishReport(ctx, day, "failed", 0, err.Error())
		return 0, err
	}
	metrics.Default.AnalyticsReports.WithLabelValues("build", "done").Inc()
	problems := s.deliverReport(ctx, day, body, claim.EmailedAt, claim.UploadedAt)
	if len(problems) > 0 {
		s.finishReport(ctx, day, "failed", len(body), strings.Join(problems, "; "))
		s.logger.Warn("analytics: daily report not fully delivered; the next tick retries",
			"day", day.Format(time.DateOnly), "attempt", claim.Attempts, "problems", problems)
		return 0, nil
	}
	s.finishReport(ctx, day, "done", len(body), "")
	s.logger.Info("analytics: daily report done", "day", day.Format(time.DateOnly), "bytes", len(body))
	return 1, nil
}

// ErrDayNotOver refuses a report for today or later: aggregating a day that
// is still running would record it as done, and it would never be redone
// once complete.
var ErrDayNotOver = errors.New("analytics: that day is not over yet in Asia/Colombo")

// RegenerateReport rebuilds a day's report from its events (re-aggregating
// it), and with deliver emails and uploads it, replacing the stored copy.
// The regeneration CLI. Only for days that are over (ErrDayNotOver).
func (s *Service) RegenerateReport(ctx context.Context, day time.Time, deliver bool) ([]byte, error) {
	if !day.Before(LocalDay(s.now())) {
		return nil, ErrDayNotOver
	}
	body, err := s.BuildReport(ctx, day, true)
	if err != nil {
		return nil, err
	}
	if err := s.store.Q.UpsertRegeneratedReport(ctx, sqlcgen.UpsertRegeneratedReportParams{Day: date(day), Bytes: textInt(len(body))}); err != nil {
		return nil, fmt.Errorf("analytics: report: record: %w", err)
	}
	if deliver {
		if problems := s.deliverReport(ctx, day, body, pgtype.Timestamptz{}, pgtype.Timestamptz{}); len(problems) > 0 {
			return body, fmt.Errorf("analytics: report: %s", strings.Join(problems, "; "))
		}
	}
	return body, nil
}

// deliverReport emails and uploads what has not been delivered yet, and
// returns what failed.
func (s *Service) deliverReport(ctx context.Context, day time.Time, body []byte, emailed, uploaded pgtype.Timestamptz) []string {
	var problems []string
	if len(s.cfg.ReportRecipients) > 0 && !emailed.Valid {
		if s.mailer == nil {
			problems = append(problems, "email: no mailer configured")
		} else if err := s.mailer.SendReport(ctx, ReportMail{
			To:      s.cfg.ReportRecipients,
			Subject: "TieHere daily report, " + day.Format("Mon 2 Jan 2006"),
			Body: "The usage report for " + day.Format("Monday 2 January 2006") + " (Asia/Colombo) is attached.\n\n" +
				"It holds aggregates only: no names, ids or contact details, and groups of fewer than 5 accounts are not shown.\n",
			Filename: ReportFilename(day), ContentType: XLSXType, Data: body,
		}); err != nil {
			metrics.Default.AnalyticsReports.WithLabelValues("email", "failed").Inc()
			problems = append(problems, "email: "+redactAddresses(err.Error()))
		} else {
			metrics.Default.AnalyticsReports.WithLabelValues("email", "done").Inc()
			if err := s.store.Q.MarkReportEmailed(ctx, date(day)); err != nil {
				problems = append(problems, "email: sent but not recorded: "+err.Error())
			}
		}
	}
	if s.cfg.ArchiveBucket != "" && s.archive != nil && !uploaded.Valid {
		object := ReportObject(day)
		if err := s.archive.Upload(ctx, s.cfg.ArchiveBucket, object, body, UploadOptions{ContentType: XLSXType}); err != nil {
			metrics.Default.AnalyticsReports.WithLabelValues("upload", "failed").Inc()
			problems = append(problems, "upload: "+err.Error())
		} else {
			metrics.Default.AnalyticsReports.WithLabelValues("upload", "done").Inc()
			if err := s.store.Q.MarkReportUploaded(ctx, sqlcgen.MarkReportUploadedParams{
				Day: date(day), Uri: textKey("gs://" + s.cfg.ArchiveBucket + "/" + object),
			}); err != nil {
				problems = append(problems, "upload: done but not recorded: "+err.Error())
			}
		}
	}
	return problems
}

func (s *Service) finishReport(ctx context.Context, day time.Time, status string, bytes int, detail string) {
	var d pgtype.Text
	if detail != "" {
		if len(detail) > 1000 {
			detail = detail[:1000]
		}
		d = pgtype.Text{String: detail, Valid: true}
	}
	if err := s.store.Q.FinishReportRun(context.WithoutCancel(ctx), sqlcgen.FinishReportRunParams{
		Day: date(day), Status: status, Bytes: textInt(bytes), Detail: d,
	}); err != nil {
		s.logger.Error("analytics: report: could not record the run", "day", day.Format(time.DateOnly), "error", err)
	}
}

// addressLike matches anything shaped like an email address.
var addressLike = regexp.MustCompile(`[^\s<>"'(),;:]+@[^\s<>"'(),;:]+`)

// redactAddresses removes addresses a mail relay echoes in its refusals,
// before the text is logged or stored (security review 2026-11-01, S-7).
func redactAddresses(s string) string { return addressLike.ReplaceAllString(s, "[address]") }

func textInt(n int) pgtype.Int8 { return pgtype.Int8{Int64: int64(n), Valid: true} }
