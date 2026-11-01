// Package flags is remote configuration: named switches stored in
// ops.feature_flags, evaluated per caller, cached in-process (plan 29 §2,
// ADR-012).
//
// Evaluation is a pure function of a flag and a subject (Evaluate), so the
// rules can be table-tested without a database. The Service around it adds
// the cache and, only when a flag's rules need it, the caller's email.
package flags

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"strings"
)

// The keys plan 29 introduces. Constants rather than strings at call sites so
// a typo is a compile error, not a flag that is silently always off.
//
// Credits have no flag: hosts use and buy them from day one. Subscription
// plans come later, so they are the only part of billing behind one.
const (
	BillingPlansVisible = "billing.plans.visible"
	AnalyticsEnabled    = "analytics.enabled"
	AnalyticsSampleRate = "analytics.sample_rate"
)

// Rule types. A rule matches a subject or it does not; the first matching
// rule decides the flag (see Evaluate).
const (
	RuleUserIDs       = "user_ids"
	RuleEmailDomains  = "email_domains"
	RuleMinAppVersion = "min_app_version"
	RulePercentage    = "percentage"
)

// Rule is one entry of a flag's ordered rule list.
type Rule struct {
	Type    string   `json:"type"`
	Values  []string `json:"values,omitempty"`
	Version string   `json:"version,omitempty"`
	Percent int      `json:"percent,omitempty"`
	// Result is what a match yields. Nil means true: almost every rule is an
	// allowlist, and "result": false is the rarer explicit exclusion.
	Result *bool `json:"result,omitempty"`
}

// Flag is one row of ops.feature_flags.
type Flag struct {
	Key string
	// Enabled is the answer when no rule matches.
	Enabled bool
	Rules   []Rule
	// Value is an optional non-boolean payload handed to clients as-is.
	Value json.RawMessage
}

// Subject is who a flag is evaluated for. Every field may be empty: an
// anonymous caller of /v1/app-config has no user id or email, and an old app
// sends no version.
type Subject struct {
	UserID     string
	Email      string
	AppVersion string
}

// Validate rejects a rule list the evaluator could not apply as written. It
// runs when an operator sets a flag (cmd/billingadmin) and when flags load,
// so a malformed rule is refused rather than evaluated as "no match".
func Validate(rules []Rule) error {
	for i, r := range rules {
		switch r.Type {
		case RuleUserIDs, RuleEmailDomains:
			if len(r.Values) == 0 {
				return fmt.Errorf("flags: rule %d (%s) has no values", i, r.Type)
			}
		case RuleMinAppVersion:
			if _, ok := parseVersion(r.Version); !ok {
				return fmt.Errorf("flags: rule %d has an unreadable version %q", i, r.Version)
			}
		case RulePercentage:
			if r.Percent < 0 || r.Percent > 100 {
				return fmt.Errorf("flags: rule %d percent %d is outside 0-100", i, r.Percent)
			}
		default:
			return fmt.Errorf("flags: rule %d has unknown type %q", i, r.Type)
		}
	}
	return nil
}

// Evaluate answers one flag for one subject: the first rule that matches
// decides, and a flag no rule matches is f.Enabled.
func Evaluate(f Flag, s Subject) bool {
	for _, r := range f.Rules {
		if matches(f.Key, r, s) {
			if r.Result != nil {
				return *r.Result
			}
			return true
		}
	}
	return f.Enabled
}

func matches(key string, r Rule, s Subject) bool {
	switch r.Type {
	case RuleUserIDs:
		if s.UserID == "" {
			return false
		}
		for _, v := range r.Values {
			if strings.EqualFold(v, s.UserID) {
				return true
			}
		}
	case RuleEmailDomains:
		_, domain, ok := strings.Cut(s.Email, "@")
		if !ok || domain == "" {
			return false
		}
		domain = strings.ToLower(domain)
		for _, v := range r.Values {
			if strings.ToLower(strings.TrimPrefix(v, "@")) == domain {
				return true
			}
		}
	case RuleMinAppVersion:
		// No version (an app older than the header) never matches a
		// minimum: that is exactly the client the rule exists to exclude.
		return s.AppVersion != "" && CompareVersions(s.AppVersion, r.Version) >= 0
	case RulePercentage:
		if s.UserID == "" {
			return false
		}
		return Bucket(key, s.UserID) < r.Percent
	}
	return false
}

// Bucket places a user in 0..99 for a percentage rollout, stably per flag:
// the same user is in or out of a 10% rollout every time, and a different
// flag's 10% is a different set of users.
func Bucket(key, userID string) int {
	sum := sha256.Sum256([]byte(key + "\x00" + strings.ToLower(userID)))
	return int(binary.BigEndian.Uint32(sum[:4]) % 100)
}

// needsEmail reports whether evaluating f can depend on the subject's email,
// so the Service fetches it only when some rule actually reads it.
func needsEmail(f Flag) bool {
	for _, r := range f.Rules {
		if r.Type == RuleEmailDomains {
			return true
		}
	}
	return false
}
