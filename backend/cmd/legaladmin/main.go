// Command legaladmin publishes a new version of the terms and privacy policy.
// The app reads them from the server, so this needs no deploy and no release.
// If acceptance is switched on, everyone is asked to agree to the new version.
//
// NOT A SERVICE. An operator runs it by hand, over the session connection.
//
// Usage:
//
//	DATABASE_URL=... go run ./cmd/legaladmin --version 2026-12-01 \
//	    --terms terms.md --privacy privacy.md
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

var errUnfinished = errors.New("the text still contains [FILL IN]; finish it, or pass --allow-draft on a local database")

// check refuses text that must not reach users.
func check(version, terms, privacy string, allowDraft bool) error {
	if version == "" || strings.TrimSpace(terms) == "" || strings.TrimSpace(privacy) == "" {
		return errors.New("--version, --terms and --privacy are all required")
	}
	if !allowDraft && (strings.Contains(terms, "[FILL IN") || strings.Contains(privacy, "[FILL IN")) {
		return errUnfinished
	}
	return nil
}

func run() error {
	version := flag.String("version", "", "a new version name, such as 2026-12-01")
	termsPath := flag.String("terms", "", "the terms, as a Markdown file")
	privacyPath := flag.String("privacy", "", "the privacy policy, as a Markdown file")
	allowDraft := flag.Bool("allow-draft", false, "publish unfinished text, for a local database only")
	flag.Parse()

	terms, err := os.ReadFile(*termsPath) // #nosec G304 -- a path the operator typed
	if err != nil {
		return fmt.Errorf("read terms: %w", err)
	}
	privacy, err := os.ReadFile(*privacyPath) // #nosec G304 -- a path the operator typed
	if err != nil {
		return fmt.Errorf("read privacy policy: %w", err)
	}
	if err := check(*version, string(terms), string(privacy), *allowDraft); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer pool.Close()
	return repository.NewLegalRepository(pool).Publish(ctx, repository.LegalDocuments{
		Version: *version, Terms: string(terms), Privacy: string(privacy),
	})
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("legaladmin: %v", err)
	}
	fmt.Println("published")
}
