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

	"professional-meetups-monolith/backend/internal/modules/auth/repository"
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

// testOTPBypassPhones parses TEST_OTP_BYPASS_PHONES — a comma-separated
// allowlist of exact phone-number strings, matched against
// VerificationCode.Target the same way pending.Target is already compared
// in verifyAndConsumeCode (verification.go). Not normalized — the entry
// must match byte-for-byte what the client actually sends. Empty/unset
// means the allowlist is empty, i.e. this mechanism is off.
func testOTPBypassPhones() map[string]bool {
	return parseOTPBypassAllowlist("TEST_OTP_BYPASS_PHONES", strings.TrimSpace)
}

// parseOTPBypassAllowlist reads a comma-separated allowlist out of the named
// environment variable, applying normalize to every entry and dropping the
// empties (so a trailing comma or a stray blank is not an allowlisted "").
// An unset or empty variable yields a nil map, which reads as "off" at every
// call site because a lookup in a nil map is a miss.
//
// # WHY A SHARED PARSER RATHER THAN ONE PER ALLOWLIST
//
// The phone and email lists differ in exactly one respect — how an entry is
// normalized — and were otherwise the same twelve lines twice. Splitting on
// the parameter that actually varies means a parsing fix (a different
// separator, a size cap, rejecting a malformed entry) lands once instead of
// needing to be noticed twice.
//
// It also makes a real correctness property structural rather than
// remembered: the SAME normalize function is applied to the allowlist entry
// here and to the lookup key at the call site, so the two halves of the
// comparison cannot drift apart. That is precisely the bug this shape
// prevents — an allowlist lowercased on load but matched against a raw
// target reads as "the bypass is broken", not as a deliberate rejection.
//
// Deliberately NOT cached behind a sync.Once. It re-reads the environment on
// every call, which looks wasteful and is: the values never change during a
// process lifetime. Two reasons it stays this way. The env read only happens
// after the cheap guards at the call site have already matched (right purpose,
// and the presented code is literally the fixed one), so it is off the path of
// every real verification. And the tests drive these mechanisms with
// t.Setenv, which mutates the environment mid-process — a cached map would
// make every one of those tests silently assert against the first value read.
// Testability of an authentication bypass is worth more than a map allocation
// that happens only when someone types 123456.
func parseOTPBypassAllowlist(envVar string, normalize func(string) string) map[string]bool {
	raw := os.Getenv(envVar)
	if raw == "" {
		return nil
	}
	set := make(map[string]bool)
	for _, entry := range strings.Split(raw, ",") {
		if entry = normalize(entry); entry != "" {
			set[entry] = true
		}
	}
	return set
}

// reservedTestTLDs are the RFC 2606 (and RFC 6761) suffixes that cannot be
// registered or resolve to a real mailbox — the only domains that make
// TEST_OTP_BYPASS_EMAILS's safety argument actually true rather than just
// stated in a comment.
var reservedTestTLDs = []string{".test", ".example", ".invalid", ".localhost"}

// isReservedTestAddress reports whether email's domain ends in one of
// reservedTestTLDs. Case-insensitive, like the allowlist itself.
func isReservedTestAddress(email string) bool {
	email = strings.ToLower(strings.TrimSpace(email))
	at := strings.LastIndex(email, "@")
	if at < 0 {
		return false
	}
	domain := email[at+1:]
	for _, suffix := range reservedTestTLDs {
		if strings.HasSuffix(domain, suffix) {
			return true
		}
	}
	return false
}

// ValidateTestOTPBypassEmails is the startup check behind the rule above:
// every entry of TEST_OTP_BYPASS_EMAILS (raw, comma-separated, as read
// from the environment) must be a reserved-TLD address. It returns an error
// naming the first entry that is not, so the process can refuse to start
// rather than boot with a credential-free login to a real mailbox. Empty
// entries are ignored, matching parseOTPBypassAllowlist.
func ValidateTestOTPBypassEmails(raw string) error {
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if !isReservedTestAddress(entry) {
			return fmt.Errorf("TEST_OTP_BYPASS_EMAILS entry %q is not on a reserved test TLD (%s): a deliverable address here is a credential-free login for whoever owns it", entry, strings.Join(reservedTestTLDs, ", "))
		}
	}
	return nil
}

// testOTPBypassEmails parses TEST_OTP_BYPASS_EMAILS — the email-side twin of
// testOTPBypassPhones, deliberately the same shape so the two can be reasoned
// about, logged, and reverted identically.
//
// One difference, and it is not cosmetic: entries are lowercased on both
// sides. A phone number arrives already normalized to E.164 by the client, so
// byte-exact is the stricter and therefore correct rule there. An email
// address does not — the client sends whatever the user typed, and the domain
// half is case-insensitive by RFC 4343. Matching byte-exact here would mean
// "L2.A@Meetups.test" silently missing an allowlist that contains
// "l2.a@meetups.test", which reads as the bypass being broken rather than as
// a deliberate rejection.
//
// Empty/unset means the allowlist is empty, i.e. this mechanism is off.
func testOTPBypassEmails() map[string]bool {
	// normalizeBypassEmail is passed here AND used on the target at the call
	// site — that shared function is what guarantees both sides of the
	// comparison are normalized identically.
	return parseOTPBypassAllowlist("TEST_OTP_BYPASS_EMAILS", normalizeBypassEmail)
}

// isEmailOTPPurpose reports whether purpose is one of the four email-delivered
// verification purposes. Listed exhaustively rather than derived from a name
// prefix: VerificationPurposePersonalEmail and VerificationPurposeEmailLogin
// share no prefix, and a `strings.Contains(purpose, "email")` test would
// silently widen the moment a non-email purpose is named with that word in
// it. A new email purpose must be added here on purpose, not inherited.
func isEmailOTPPurpose(purpose repository.VerificationPurpose) bool {
	switch purpose {
	case repository.VerificationPurposePersonalEmail,
		repository.VerificationPurposeCorporateEmail,
		repository.VerificationPurposeEmailSignup,
		repository.VerificationPurposeEmailLogin:
		return true
	default:
		return false
	}
}

// testEmailBypassSkipLogMsg is the log line both email send sites emit when
// they skip a real send. A constant, not two string literals: there ARE two
// send sites (dispatchVerificationCode for the user-keyed purposes,
// startTargetKeyedVerification for signup/login), they must stay greppable as
// one thing in `gcloud run services logs read`, and two copies of a sentence
// this long drift the first time anyone rewords one of them.
const testEmailBypassSkipLogMsg = "TEST_OTP_BYPASS_EMAILS: real email send skipped for allowlisted test address; fixed test code and the real generated code (below) both work"

// normalizeBypassEmail matches testOTPBypassEmails' own treatment of an
// allowlist entry, so the comparison is symmetric. Kept as a named function
// rather than inlined at the one call site so the two cannot drift.
func normalizeBypassEmail(target string) string {
	return strings.ToLower(strings.TrimSpace(target))
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
//
// # THE SECOND MECHANISM: TEST_OTP_BYPASS_PHONES (Plan 16)
//
// ALLOW_TEST_OTP_BYPASS is global — every purpose, every account — which is
// why it stays local-only and is never set on the deployed service. The
// deployed service has a narrower problem: Twilio cannot deliver long-code
// SMS to Dialog/Etisalat/Hutchison (error 21612) until an Alphanumeric
// Sender ID registration completes, so real phone OTP never arrives on the
// two physical test devices, and phone verification gates Level 2 trust.
//
// TEST_OTP_BYPASS_PHONES solves exactly that, scoped on two axes at once:
//
//   - PURPOSE: phone only. Email OTP (personal and corporate) still always
//     requires the real code — Resend/Gmail delivery works, so there is no
//     reason to weaken that path at all.
//   - TARGET: only numbers in the allowlist. Every other number, including
//     ones nobody has used yet, still requires the real delivered code.
//
// Residual risk, stated rather than hidden: anyone who knows an allowlisted
// number could use "123456" to verify it. That is a real account-takeover
// surface on those specific numbers — but a strictly smaller one than doing
// nothing, because those numbers cannot complete verification at all today
// (the SMS never arrives), so no currently-working account is newly exposed.
// No other user and no other number is affected.
//
// # THE THIRD MECHANISM: TEST_OTP_BYPASS_EMAILS
//
// Same shape as TEST_OTP_BYPASS_PHONES, scoped to the four email purposes and
// to an allowlist of exact addresses. It exists for a DIFFERENT reason, and
// the difference matters enough to state rather than let the symmetry imply.
//
// The phone bypass answers an undeliverability problem: Twilio cannot reach
// those carriers at all, so the real code never arrives. This one does not.
// Email delivery works. It answers a throughput problem instead — exercising
// a 0-to-3 trust ladder means signing in as eight different accounts, and
// eight mailboxes is friction that makes the ladder go untested in practice.
//
// # RESIDUAL RISK, AND WHY THE PHONE ARGUMENT DOES NOT TRANSFER
//
// TEST_OTP_BYPASS_PHONES could argue that it exposed nothing: those numbers
// cannot complete verification today under any circumstances, so no working
// account was newly reachable. THAT ARGUMENT IS FALSE HERE. Email works, so
// an allowlisted address is an account that anyone knowing the address could
// sign in as with "123456". That is a real account-takeover surface.
//
// What contains it is the allowlist's contents, not the mechanism, and
// that containment is ENFORCED, not merely documented:
//
//   - Every entry must be on an RFC 2606 / RFC 6761 reserved suffix (see
//     reservedTestTLDs). Those cannot be registered, cannot receive mail,
//     and therefore cannot belong to a real person or be recovered by one.
//     cmd/monolith checks every entry with ValidateTestOTPBypassEmails at
//     startup and refuses to boot if any entry is deliverable, naming it.
//   - They are seeded fixtures holding no real data, no payment method, and
//     no relationship to any real account.
//   - Every other address, including any real user's, still requires the
//     real delivered code.
//
// So the operating rule is narrower than for the phone list: NEVER put a
// real, deliverable address in TEST_OTP_BYPASS_EMAILS. A reserved-TLD
// fixture is a test account; a real address is a published password, and
// since 2026-09-15 the process will not start with one in the list.
//
// The three mechanisms are independent on purpose: each can be identified on
// its own in logs and reverted on its own.
func otpMatches(hash, code string, purpose repository.VerificationPurpose, target string) bool {
	if allowTestOTPBypass() && code == testOTPBypassCode {
		return true
	}
	if purpose == repository.VerificationPurposePhone &&
		code == testOTPBypassCode &&
		testOTPBypassPhones()[target] {
		return true
	}
	if isEmailOTPPurpose(purpose) &&
		code == testOTPBypassCode &&
		testOTPBypassEmails()[normalizeBypassEmail(target)] {
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
