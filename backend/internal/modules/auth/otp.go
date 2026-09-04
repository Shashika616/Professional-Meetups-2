package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
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

// otpMatches compares a stored hash against a presented code. Constant-time
// on principle, even though the comparison operates on already-hashed values
// rather than a raw secret.
//
// DELIBERATELY NOT PORTED: the source ships a testing bypass here
// (../Professional-Meetups/TESTING-NOTES.md) that accepts the hardcoded code
// "123456" for every purpose and comments the real comparison out, marked
// "DO NOT SHIP TO PRODUCTION" — it exists so the app can be exercised
// end-to-end without a real Twilio/Resend send. Porting it would be porting
// an authentication bypass, which is not what "port the validation rules
// faithfully" means. The real comparison is restored below; local end-to-end
// testing without a real SMS/email provider reads the code from the
// LoggingSmsSender/LoggingEmailSender log line instead, which is what those
// senders exist for.
func otpMatches(hash, code string) bool {
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
