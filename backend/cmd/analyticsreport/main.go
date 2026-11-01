// Command analyticsreport regenerates the daily analytics report for any
// day (plan 29F): it re-aggregates the day from its raw events, builds the
// workbook, records the run, and optionally writes, emails and uploads it.
//
//	DATABASE_URL=... analyticsreport --date=2026-10-31 --out=report.xlsx
//	DATABASE_URL=... analyticsreport --date=2026-10-31 --deliver
//
// --deliver emails ANALYTICS_REPORT_RECIPIENTS and replaces
// analytics/reports/YYYY-MM-DD.xlsx in ANALYTICS_ARCHIVE_BUCKET, through the
// same senders the monolith uses (GMAIL_* or RESEND_*, otherwise the
// logging sender). Raw events must still be in Postgres (the retention
// window, 14 days by default); an older day is rebuilt from its aggregates
// only if they are already there.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"time"

	"professional-meetups-monolith/backend/internal/modules/analytics"
	analyticsconfig "professional-meetups-monolith/backend/internal/modules/analytics/config"
	analyticsrepo "professional-meetups-monolith/backend/internal/modules/analytics/repository"
	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/platform/db"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "analyticsreport:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, out io.Writer) error {
	fs := flag.NewFlagSet("analyticsreport", flag.ContinueOnError)
	dateFlag := fs.String("date", "", "the Asia/Colombo day to report, YYYY-MM-DD (required)")
	outFlag := fs.String("out", "", "write the workbook here")
	deliver := fs.Bool("deliver", false, "email it to ANALYTICS_REPORT_RECIPIENTS and upload it to ANALYTICS_ARCHIVE_BUCKET")
	if err := fs.Parse(args); err != nil {
		return err
	}
	day, err := time.Parse(time.DateOnly, *dateFlag)
	if err != nil {
		return errors.New("--date=YYYY-MM-DD is required")
	}
	if *outFlag == "" && !*deliver {
		return errors.New("nothing to do: give --out, --deliver, or both")
	}
	dbURL := getenv("DATABASE_URL")
	if dbURL == "" {
		return errors.New("DATABASE_URL is not set")
	}
	cfg, err := analyticsconfig.LoadFrom(getenv)
	if err != nil {
		return err
	}
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	svc := analytics.New(analytics.Deps{
		Store:   analyticsrepo.New(pool),
		Config:  cfg,
		Archive: analytics.NewGCS(),
		Mailer:  mailerFrom(getenv),
		Logger:  slog.New(slog.NewTextHandler(os.Stderr, nil)),
	})
	body, err := svc.RegenerateReport(ctx, day, *deliver)
	if err != nil {
		return err
	}
	if *outFlag != "" {
		if err := os.WriteFile(*outFlag, body, 0o600); err != nil {
			return err
		}
	}
	_, _ = fmt.Fprintf(out, "report for %s: %d bytes", day.Format(time.DateOnly), len(body))
	if *outFlag != "" {
		_, _ = fmt.Fprintf(out, ", written to %s", *outFlag)
	}
	if *deliver {
		_, _ = fmt.Fprint(out, ", delivered")
	}
	_, _ = fmt.Fprintln(out)
	return nil
}

// mailerFrom picks the sender the monolith would (Gmail, then Resend, then
// logging).
func mailerFrom(getenv func(string) string) analytics.ReportMailer {
	var sender email.AttachmentSender = email.NewLoggingEmailSender()
	switch {
	case getenv("GMAIL_ADDRESS") != "" && getenv("GMAIL_APP_PASSWORD") != "":
		sender = email.NewGmailSMTPEmailSender(getenv("GMAIL_ADDRESS"), getenv("GMAIL_APP_PASSWORD"))
	case getenv("RESEND_API_KEY") != "" && getenv("RESEND_FROM_EMAIL") != "":
		sender = email.NewResendEmailSender(getenv("RESEND_API_KEY"), getenv("RESEND_FROM_EMAIL"))
	}
	return mailer{sender}
}

type mailer struct{ sender email.AttachmentSender }

func (m mailer) SendReport(ctx context.Context, r analytics.ReportMail) error {
	return m.sender.SendWithAttachment(ctx, r.To, r.Subject, r.Body, email.Attachment{
		Filename: r.Filename, ContentType: r.ContentType, Data: r.Data,
	})
}
