package flags

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// CacheTTL is how long the flag table is trusted after a read (plan 29 §2).
// A flag change takes effect within this window on every instance, which is
// the price of not reading the table on every request.
const CacheTTL = 30 * time.Second

// Store reads every flag. One query for the whole table: there are a handful
// of flags, and reading them together is what makes a 30-second cache cheap.
type Store interface {
	All(ctx context.Context) ([]Flag, error)
}

// EmailResolver looks up a user's email, for email_domains rules. It is
// consulted only when a rule needs it, so most evaluations cost no lookup.
type EmailResolver func(ctx context.Context, userID string) (string, error)

// Evaluated is one flag's answer for one subject, as /v1/app-config returns
// it.
type Evaluated struct {
	Enabled bool
	Value   json.RawMessage
}

// Service evaluates flags against a cached copy of the table.
type Service struct {
	store  Store
	emails EmailResolver
	ttl    time.Duration
	now    func() time.Time
	logger *slog.Logger

	mu       sync.Mutex
	cached   map[string]Flag
	loadedAt time.Time
}

// Option configures a Service.
type Option func(*Service)

// WithTTL overrides CacheTTL (tests use 0 to read through).
func WithTTL(d time.Duration) Option { return func(s *Service) { s.ttl = d } }

// WithClock overrides time.Now, for cache-expiry tests.
func WithClock(now func() time.Time) Option { return func(s *Service) { s.now = now } }

// WithEmailResolver enables email_domains rules. Without one they never
// match, which fails closed for an allowlist.
func WithEmailResolver(r EmailResolver) Option { return func(s *Service) { s.emails = r } }

// WithLogger sets the logger for load and lookup failures.
func WithLogger(l *slog.Logger) Option { return func(s *Service) { s.logger = l } }

// NewService constructs a Service over store.
func NewService(store Store, opts ...Option) *Service {
	s := &Service{store: store, ttl: CacheTTL, now: time.Now, logger: slog.Default()}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// snapshot returns the cached table, reloading it once it is older than the
// TTL. A failed reload keeps serving the previous copy if there is one: a
// database blip must not flip every flag to its default mid-traffic.
func (s *Service) snapshot(ctx context.Context) (map[string]Flag, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cached != nil && s.now().Sub(s.loadedAt) < s.ttl {
		return s.cached, nil
	}
	all, err := s.store.All(ctx)
	if err != nil {
		if s.cached != nil {
			s.logger.Warn("flags: reload failed, serving the previous copy", "error", err)
			return s.cached, nil
		}
		return nil, fmt.Errorf("flags: load: %w", err)
	}
	next := make(map[string]Flag, len(all))
	for _, f := range all {
		if err := Validate(f.Rules); err != nil {
			// Skip the one bad flag rather than the table: it then reads as
			// absent, which is off.
			s.logger.Error("flags: ignoring a flag with invalid rules", "key", f.Key, "error", err)
			continue
		}
		next[f.Key] = f
	}
	s.cached, s.loadedAt = next, s.now()
	return next, nil
}

// Enabled evaluates one flag. An unknown flag is off.
func (s *Service) Enabled(ctx context.Context, key string, subject Subject) (bool, error) {
	table, err := s.snapshot(ctx)
	if err != nil {
		return false, err
	}
	f, ok := table[key]
	if !ok {
		return false, nil
	}
	return Evaluate(f, s.withEmail(ctx, f, subject)), nil
}

// Allowlisted reports whether one of the flag's rules matches the subject,
// whatever the flag's default. It answers "is this caller on the list",
// which stays true for the listed accounts and false for everyone else even
// after the flag is turned on for all — billing uses it to accept sandbox
// store purchases only from the test accounts on billing.plans.visible.
func (s *Service) Allowlisted(ctx context.Context, key string, subject Subject) (bool, error) {
	table, err := s.snapshot(ctx)
	if err != nil {
		return false, err
	}
	f, ok := table[key]
	if !ok {
		return false, nil
	}
	f.Enabled = false
	return Evaluate(f, s.withEmail(ctx, f, subject)), nil
}

// EvaluateAll answers every flag for one subject, for /v1/app-config. The
// email is fetched at most once, and only if some flag reads it.
func (s *Service) EvaluateAll(ctx context.Context, subject Subject) (map[string]Evaluated, error) {
	table, err := s.snapshot(ctx)
	if err != nil {
		return nil, err
	}
	out := make(map[string]Evaluated, len(table))
	resolved := false
	for key, f := range table {
		if !resolved && needsEmail(f) {
			subject = s.withEmail(ctx, f, subject)
			resolved = true
		}
		out[key] = Evaluated{Enabled: Evaluate(f, subject), Value: f.Value}
	}
	return out, nil
}

func (s *Service) withEmail(ctx context.Context, f Flag, subject Subject) Subject {
	if subject.Email != "" || subject.UserID == "" || s.emails == nil || !needsEmail(f) {
		return subject
	}
	email, err := s.emails(ctx, subject.UserID)
	if err != nil {
		// Evaluated without it: an email_domains allowlist then does not
		// match, which is the closed direction.
		s.logger.Warn("flags: email lookup failed", "key", f.Key, "error", err)
		return subject
	}
	subject.Email = email
	return subject
}
