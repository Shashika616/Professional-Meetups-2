// Command billingadmin is the only way to change credits, plans or feature
// flags by hand (plan 29 §1, ADR-010). There is deliberately no admin HTTP
// surface (OWASP API5): this runs against the database by someone who
// already holds its credentials, and every action is written to the ledger
// or an audit table with the operator's name and reason.
//
//	billingadmin grant       --user U --amount N [--expires-days D] --operator O --reason R [--key K]
//	billingadmin adjust      --user U --delta N --operator O --reason R [--key K]
//	billingadmin show-wallet --user U
//	billingadmin set-plan    --user U --plan pro|enterprise|none [--until 2027-01-31] --operator O --reason R
//	billingadmin flags show
//	billingadmin flags set   --key K --enabled true|false [--rules JSON] [--value JSON] --operator O --reason R
//
// DATABASE_URL must point at the session pooler or direct host (runbook §9),
// never the transaction pooler.
//
// --key makes grant and adjust idempotent. Without one, the key is derived
// from the command's own arguments, so running the identical command twice
// applies it once; pass a fresh --key to repeat a grant on purpose.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"professional-meetups-monolith/backend/internal/modules/billing"
	billingconfig "professional-meetups-monolith/backend/internal/modules/billing/config"
	"professional-meetups-monolith/backend/internal/platform/db"
	"professional-meetups-monolith/backend/internal/platform/flags"
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "billingadmin:", err)
		os.Exit(1)
	}
}

var errUsage = errors.New("usage: billingadmin grant|adjust|show-wallet|set-plan|flags show|flags set (see the package doc)")

// run is main without the process: testable with a fake environment.
func run(ctx context.Context, args []string, getenv func(string) string, out io.Writer) error {
	if len(args) == 0 {
		return errUsage
	}
	cmd, rest := args[0], args[1:]
	if cmd == "flags" {
		if len(rest) == 0 {
			return errUsage
		}
		cmd, rest = "flags "+rest[0], rest[1:]
	}

	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var (
		user        = fs.String("user", "", "user id")
		amount      = fs.Int64("amount", 0, "credits to grant")
		delta       = fs.Int64("delta", 0, "credits to add (positive) or remove (negative)")
		expiresDays = fs.Int("expires-days", 0, "days until a grant expires (0: never)")
		plan        = fs.String("plan", "", "pro, enterprise, or none")
		until       = fs.String("until", "", "plan end date, YYYY-MM-DD")
		operator    = fs.String("operator", "", "who is doing this")
		reason      = fs.String("reason", "", "why")
		key         = fs.String("key", "", "idempotency key")
		flagKey     = fs.String("flag", "", "flag key (flags set); --key also accepted")
		enabled     = fs.String("enabled", "", "true or false")
		rules       = fs.String("rules", "[]", "flag rules as JSON")
		value       = fs.String("value", "", "flag value as JSON")
	)
	if err := fs.Parse(rest); err != nil {
		return fmt.Errorf("%s: %w", cmd, err)
	}

	// Validate before touching the database: a mistyped command must not
	// even connect.
	needsAction := map[string]bool{"grant": true, "adjust": true, "set-plan": true, "flags set": true}
	if needsAction[cmd] && (strings.TrimSpace(*operator) == "" || strings.TrimSpace(*reason) == "") {
		return fmt.Errorf("%s: --operator and --reason are required", cmd)
	}
	switch cmd {
	case "grant":
		if *user == "" || *amount <= 0 {
			return errors.New("grant: --user and a positive --amount are required")
		}
	case "adjust":
		if *user == "" || *delta == 0 {
			return errors.New("adjust: --user and a non-zero --delta are required")
		}
	case "show-wallet":
		if *user == "" {
			return errors.New("show-wallet: --user is required")
		}
	case "set-plan":
		if *user == "" || *plan == "" {
			return errors.New("set-plan: --user and --plan are required")
		}
		if *plan != billing.PlanNone && *until == "" {
			return errors.New("set-plan: --until is required")
		}
	case "flags show":
	case "flags set":
		if *flagKey == "" {
			*flagKey = *key
		}
		if *flagKey == "" || (*enabled != "true" && *enabled != "false") {
			return errors.New("flags set: --flag (or --key) and --enabled true|false are required")
		}
	default:
		return errUsage
	}

	dbURL := getenv("DATABASE_URL")
	if dbURL == "" {
		return errors.New("DATABASE_URL is not set")
	}
	pool, err := db.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	if strings.HasPrefix(cmd, "flags") {
		return runFlags(ctx, cmd, pool, out, flags.Flag{Key: *flagKey, Enabled: *enabled == "true"}, *rules, *value, *operator, *reason)
	}

	svc := billing.New(billing.Deps{Pool: pool, Config: billingconfig.Config{}})
	action := billing.AdminAction{Operator: *operator, Reason: *reason, Key: *key}
	if action.Key == "" {
		action.Key = derivedKey(cmd, *user, fmt.Sprint(*amount, *delta, *expiresDays), *reason)
	}

	switch cmd {
	case "grant":
		applied, err := svc.AdminGrant(ctx, *user, *amount, time.Duration(*expiresDays)*24*time.Hour, action)
		if err != nil {
			return err
		}
		_, _ = fmt.Fprintf(out, "grant %d to %s: applied=%v key=%s\n", *amount, *user, applied, action.Key)
	case "adjust":
		applied, err := svc.AdminAdjust(ctx, *user, *delta, action)
		if err != nil {
			return err
		}
		_, _ = fmt.Fprintf(out, "adjust %+d for %s: applied=%v key=%s\n", *delta, *user, applied, action.Key)
	case "set-plan":
		var end time.Time
		if *plan != billing.PlanNone {
			end, err = time.Parse("2006-01-02", *until)
			if err != nil {
				return fmt.Errorf("set-plan: --until %q is not YYYY-MM-DD", *until)
			}
		}
		if err := svc.AdminSetPlan(ctx, *user, *plan, end, action); err != nil {
			return err
		}
		_, _ = fmt.Fprintf(out, "set-plan %s for %s until %s\n", *plan, *user, *until)
	}
	// Every command ends by showing the wallet it changed.
	if *user == "" {
		return nil
	}
	v, err := svc.Wallet(ctx, billing.Caller{UserID: *user})
	if err != nil {
		return err
	}
	ent, err := svc.Entitlements(ctx, billing.Caller{UserID: *user})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{"wallet": v, "entitlements": ent})
}

func runFlags(ctx context.Context, cmd string, pool *pgxpool.Pool, out io.Writer, f flags.Flag, rules, value, operator, reason string) error {
	store := flags.NewPostgresStore(pool)
	if cmd == "flags set" {
		dec := json.NewDecoder(strings.NewReader(rules))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&f.Rules); err != nil {
			return fmt.Errorf("flags set: --rules: %w", err)
		}
		if value != "" {
			f.Value = json.RawMessage(value)
		}
		if err := store.Set(ctx, f, operator, reason); err != nil {
			return err
		}
	}
	all, err := store.All(ctx)
	if err != nil {
		return err
	}
	for _, f := range all {
		rules, _ := json.Marshal(f.Rules)
		_, _ = fmt.Fprintf(out, "%-32s enabled=%-5v rules=%s value=%s\n", f.Key, f.Enabled, rules, string(f.Value))
	}
	return nil
}

func derivedKey(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return "cli-" + hex.EncodeToString(sum[:8])
}
