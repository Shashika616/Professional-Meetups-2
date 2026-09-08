package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"
)

const (
	// otpExpiry is how long a generated code stays valid (backend/PLAN.md's
	// addendum, Step C/D).
	otpExpiry = 10 * time.Minute

	// otpMaxAttempts caps guesses against a single code before it's
	// invalidated and a fresh send is required — 5 attempts against a
	// 10-minute-lived 6-digit code (1-in-1,000,000 space) is a reasonable
	// bound against brute-forcing, consistent with this project's existing
	// rate-limiter reasoning (ratelimit.go).
	otpMaxAttempts = 5

	// otpResendCooldown is the server-enforced minimum gap between sends
	// for the same (user, purpose) — the client's own countdown timer is a
	// UX convenience, this is the actual control (Step G).
	otpResendCooldown = 1 * time.Minute
)

// generateOTP returns a cryptographically random 6-digit code (crypto/rand,
// not math/rand), zero-padded to always be exactly 6 digits.
func generateOTP() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", fmt.Errorf("generate otp: %w", err)
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// hashOTP mirrors newRefreshToken's hashToken — SHA-256, hex-encoded. The
// raw code is never stored (verification_codes.code_hash).
func hashOTP(code string) string {
	sum := sha256.Sum256([]byte(code))
	return hex.EncodeToString(sum[:])
}

// testOTPBypassCode is the fixed code accepted when allowTestOTPBypass() is
// true — same value as the source's own hardcoded bypass
// (../Professional-Meetups/TESTING-NOTES.md), for continuity with existing
// manual-testing habits.
const testOTPBypassCode = "123456"

// allowTestOTPBypass reports whether the test-only OTP bypass is active.
// Off unless ALLOW_TEST_OTP_BYPASS=true is explicitly set in the process
// environment — never on by default, and never inferred from any other
// config (e.g. Twilio/Resend being unconfigured does NOT imply this should
// be on; use the LoggingSmsSender/LoggingEmailSender log line for that case
// instead). See TESTING-NOTES.md at the repo root.
func allowTestOTPBypass() bool {
	return os.Getenv("ALLOW_TEST_OTP_BYPASS") == "true"
}

// otpMatches compares a stored hash against a presented code. Constant-time
// on principle, even though the comparison operates on already-hashed values
// rather than a raw secret.
//
// Test-only bypass, off by default: the source ships a testing shortcut here
// (../Professional-Meetups/TESTING-NOTES.md) that accepts the hardcoded code
// "123456" for every purpose by commenting the real comparison out entirely,
// marked "DO NOT SHIP TO PRODUCTION". That shape — an unconditional bypass
// with no gate — was deliberately not ported in Phase 1: porting it as-is
// would be porting an authentication bypass, not a validation rule, and
// "port faithfully" was never meant to cover that.
//
// What's below instead: the real comparison always runs, and "123456" is
// only ever accepted *in addition* to it, and only when allowTestOTPBypass()
// is true (ALLOW_TEST_OTP_BYPASS=true, an explicit opt-in env var, absent
// from every deployed environment and never set in backend/.env.example).
// This exists purely so manual testing doesn't require digging a real code
// out of the LoggingSmsSender/LoggingEmailSender log line every time; it is
// not a replacement for that log line, which remains the only way to see a
// *real* generated code. Must never be true outside local development — see
// TESTING-NOTES.md at the repo root, which this file's behavior must stay
// consistent with.
func otpMatches(hash, code string) bool {
	if allowTestOTPBypass() && code == testOTPBypassCode {
		return true
	}
	return subtle.ConstantTimeCompare([]byte(hash), []byte(hashOTP(code))) == 1
}

// freeEmailDomains and roleBasedLocalParts are Verification Model § 5's
// existing lists (ADR-012: kept in for this MVP even though the rest of §
// 5's fraud-detection flow — domain age/SPF/DKIM/DMARC, the company
// verification database, manual review — is deferred).
var freeEmailDomains = map[string]bool{
	"gmail.com":      true,
	"yahoo.com":      true,
	"hotmail.com":    true,
	"outlook.com":    true,
	"protonmail.com": true,
	"zoho.com":       true,
	"icloud.com":     true,
}

var roleBasedLocalParts = map[string]bool{
	"info":    true,
	"admin":   true,
	"hr":      true,
	"contact": true,
	"support": true,
	"careers": true,
	"jobs":    true,
	"office":  true,
}

// isRejectedCorporateEmail reports whether email fails the free-domain or
// role-based-address check — this runs *before* a code is generated at all
// for StartCorporateEmailVerification (Step C/D). A malformed address (no
// "@", empty local/domain part) is rejected too, same as a free/role-based
// one — none of these are valid professional-proof addresses.
func isRejectedCorporateEmail(email string) bool {
	local, domain, ok := splitEmail(email)
	if !ok {
		return true
	}
	if freeEmailDomains[strings.ToLower(domain)] {
		return true
	}
	return roleBasedLocalParts[strings.ToLower(local)]
}

// domainFromEmail extracts the domain half of a corporate email for storage
// as User.CompanyDomain — the raw address itself is never persisted
// (ADR-003). Lowercased, mirroring isRejectedCorporateEmail's own
// strings.ToLower treatment a few lines up — domain names are
// case-insensitive (RFC 4343), and known_companies.domains is seeded
// lowercase, so an unlowercased return here caused VerifyCorporateEmailCode
// to falsely reject a legitimate employee who typed their email with any
// capitalization other than the seeded row's exact case (ADR-019's
// 2026-08-24 correction).
func domainFromEmail(email string) string {
	_, domain, _ := splitEmail(email)
	return strings.ToLower(domain)
}

func splitEmail(email string) (local, domain string, ok bool) {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}
