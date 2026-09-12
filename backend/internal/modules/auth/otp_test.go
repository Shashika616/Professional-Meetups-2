package auth

import (
	"context"
	"regexp"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth/email"
	"professional-meetups-monolith/backend/internal/modules/auth/repository"
)

func TestGenerateOTP(t *testing.T) {
	seen := map[string]bool{}
	pattern := regexp.MustCompile(`^\d{6}$`)

	for i := 0; i < 200; i++ {
		code, err := generateOTP()
		if err != nil {
			t.Fatalf("generateOTP() error: %v", err)
		}
		if !pattern.MatchString(code) {
			t.Fatalf("generateOTP() = %q, want exactly 6 digits (zero-padded)", code)
		}
		seen[code] = true
	}

	// Not a strict randomness proof, but 200 draws from a 1,000,000-value
	// space landing on the same value twice would be a red flag that
	// something is badly non-random (e.g. seeded from a fixed source).
	if len(seen) < 190 {
		t.Errorf("only %d distinct codes out of 200 draws — suspiciously low entropy", len(seen))
	}
}

func TestHashOTPAndOtpMatches(t *testing.T) {
	hash := hashOTP("123456")

	if hash == "123456" {
		t.Error("hashOTP returned the raw code unchanged — not actually hashed")
	}
	// Neither env var is set here, so both bypasses are inert and this
	// exercises the real constant-time comparison — which matters, since
	// the "correct" code in this test happens to BE the bypass code.
	if !otpMatches(hash, "123456", repository.VerificationPurposePhone, "+94771111111") {
		t.Error("otpMatches(hash, correct code) = false, want true")
	}
	if otpMatches(hash, "654321", repository.VerificationPurposePhone, "+94771111111") {
		t.Error("otpMatches(hash, wrong code) = true, want false")
	}
}

// TEST_OTP_BYPASS_PHONES (Plan 16) is scoped on two axes at once — target
// AND purpose. These pin both, because a bypass that silently widened on
// either axis would be an authentication hole rather than a testing
// convenience, and nothing else in the suite would notice.
//
// Every case below uses a hash of a DIFFERENT code than the one presented,
// so a pass can only come from the allowlist branch, never from the real
// comparison accidentally succeeding.
func TestOtpMatches_TestPhoneAllowlist(t *testing.T) {
	const allowed = "+94771234567"
	const other = "+94779999999"
	realHash := hashOTP("654321")

	t.Run("accepted for an allowlisted phone target", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		if !otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposePhone, allowed) {
			t.Error("bypass code rejected for an allowlisted number, want accepted")
		}
	})

	t.Run("rejected for a phone target NOT in the allowlist", func(t *testing.T) {
		// The var IS set — to a different number. This is the case that
		// proves the allowlist is consulted rather than merely being present.
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		if otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposePhone, other) {
			t.Error("bypass code accepted for a non-allowlisted number, want rejected")
		}
	})

	t.Run("rejected for email purposes on the SAME allowlisted number", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		for _, purpose := range []repository.VerificationPurpose{
			repository.VerificationPurposePersonalEmail,
			repository.VerificationPurposeCorporateEmail,
		} {
			if otpMatches(realHash, testOTPBypassCode, purpose, allowed) {
				t.Errorf("bypass code accepted for purpose %q, want phone-only scope", purpose)
			}
		}
	})

	t.Run("the real code still works for an allowlisted number", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		if !otpMatches(realHash, "654321", repository.VerificationPurposePhone, allowed) {
			t.Error("real code rejected on an allowlisted number — the bypass must be additive, not a replacement")
		}
	})

	t.Run("unset means off", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", "")
		if otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposePhone, allowed) {
			t.Error("bypass code accepted with the allowlist unset, want rejected")
		}
	})
}

// Plan 17's addition: the SEND step, not the verify step. An allowlisted
// number must not reach Twilio at all — the call is already known to fail
// for these numbers (21612), so making it costs an API call and surfaces a
// scary error for an expected outcome.
func TestDispatchVerificationCode_SkipsSendForAllowlistedPhone(t *testing.T) {
	const allowed = "+94771234567"
	svc, _, _, _, smsSender := newTestService(t)

	t.Run("allowlisted number: no send, no error", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		err := svc.dispatchVerificationCode(
			context.Background(), repository.VerificationPurposePhone, allowed, "654321",
		)
		if err != nil {
			t.Fatalf("dispatchVerificationCode returned %v, want nil", err)
		}
		if len(smsSender.sent) != 0 {
			t.Errorf("SMS sender was called %d time(s) for an allowlisted number, want 0", len(smsSender.sent))
		}
	})

	t.Run("any other number still sends normally", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", allowed)
		if err := svc.dispatchVerificationCode(
			context.Background(), repository.VerificationPurposePhone, "+94779999999", "654321",
		); err != nil {
			t.Fatalf("dispatchVerificationCode returned %v, want nil", err)
		}
		if len(smsSender.sent) != 1 {
			t.Fatalf("SMS sender was called %d time(s) for a non-allowlisted number, want 1", len(smsSender.sent))
		}
		if smsSender.sent[0].to != "+94779999999" || smsSender.sent[0].code != "654321" {
			t.Errorf("sent %+v, want the real target and code", smsSender.sent[0])
		}
	})
}

func TestIsRejectedCorporateEmail(t *testing.T) {
	tests := []struct {
		email string
		want  bool
	}{
		{"jane.doe@acmecorp.com", false},
		{"j.doe@some-startup.io", false},
		{"someone@gmail.com", true},
		{"someone@Gmail.com", true}, // case-insensitive domain match
		{"someone@yahoo.com", true},
		{"someone@icloud.com", true},
		{"info@acmecorp.com", true},
		{"HR@acmecorp.com", true}, // case-insensitive local-part match
		{"careers@acmecorp.com", true},
		{"not-an-email", true},
		{"@acmecorp.com", true},
		{"jane@", true},
	}

	for _, tt := range tests {
		t.Run(tt.email, func(t *testing.T) {
			if got := isRejectedCorporateEmail(tt.email); got != tt.want {
				t.Errorf("isRejectedCorporateEmail(%q) = %v, want %v", tt.email, got, tt.want)
			}
		})
	}
}

func TestDomainFromEmail(t *testing.T) {
	if got := domainFromEmail("jane.doe@acmecorp.com"); got != "acmecorp.com" {
		t.Errorf("domainFromEmail() = %q, want %q", got, "acmecorp.com")
	}
}

// TestDomainFromEmail_Lowercases guards ADR-019's 2026-08-24 correction —
// domain names are case-insensitive (RFC 4343), and known_companies.domains
// is seeded lowercase, so an unlowercased return here caused a false
// errCompanyDomainMismatch for a legitimate employee who typed their email
// with any capitalization other than the seeded row's exact case.
func TestDomainFromEmail_Lowercases(t *testing.T) {
	if got := domainFromEmail("Jane@ComBank.LK"); got != "combank.lk" {
		t.Errorf("domainFromEmail() = %q, want %q", got, "combank.lk")
	}
}

// TEST_OTP_BYPASS_EMAILS is the email twin of the phone allowlist above, and
// these mirror that block deliberately: the same two axes (target AND
// purpose) plus one the phone list does not have — case. An email domain is
// case-insensitive (RFC 4343) and the client sends whatever was typed, so the
// match has to be too, and that must be pinned rather than assumed.
//
// As above, every case hashes a DIFFERENT code than the one presented, so a
// pass can only come from the allowlist branch.
func TestOtpMatches_TestEmailAllowlist(t *testing.T) {
	const allowed = "l2.a@meetups.test"
	const other = "someone.real@gmail.com"
	realHash := hashOTP("654321")

	emailPurposes := []repository.VerificationPurpose{
		repository.VerificationPurposePersonalEmail,
		repository.VerificationPurposeCorporateEmail,
		repository.VerificationPurposeEmailSignup,
		repository.VerificationPurposeEmailLogin,
	}

	t.Run("accepted for every email purpose on an allowlisted address", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		for _, purpose := range emailPurposes {
			if !otpMatches(realHash, testOTPBypassCode, purpose, allowed) {
				t.Errorf("bypass code rejected for purpose %q on an allowlisted address, want accepted", purpose)
			}
		}
	})

	t.Run("rejected for an address NOT in the allowlist", func(t *testing.T) {
		// The var IS set, to a different address — this proves the allowlist
		// is consulted rather than merely being present.
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		for _, purpose := range emailPurposes {
			if otpMatches(realHash, testOTPBypassCode, purpose, other) {
				t.Errorf("bypass code accepted for a non-allowlisted address on purpose %q, want rejected", purpose)
			}
		}
	})

	t.Run("rejected for the phone purpose on the SAME allowlisted address", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		if otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposePhone, allowed) {
			t.Error("email allowlist leaked into the phone purpose, want email-only scope")
		}
	})

	t.Run("matches case-insensitively on both sides", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", "  L2.A@Meetups.TEST  ")
		if !otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposeEmailLogin, "l2.a@meetups.test") {
			t.Error("mixed-case allowlist entry did not match a lowercase target")
		}
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		if !otpMatches(realHash, testOTPBypassCode, repository.VerificationPurposeEmailLogin, " L2.A@MEETUPS.TEST ") {
			t.Error("lowercase allowlist entry did not match a mixed-case target")
		}
	})

	t.Run("the real code still works for an allowlisted address", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		if !otpMatches(realHash, "654321", repository.VerificationPurposeEmailLogin, allowed) {
			t.Error("real code rejected on an allowlisted address — the bypass must be additive, not a replacement")
		}
	})

	t.Run("unset means off", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", "")
		for _, purpose := range emailPurposes {
			if otpMatches(realHash, testOTPBypassCode, purpose, allowed) {
				t.Errorf("bypass code accepted with the allowlist unset on purpose %q, want rejected", purpose)
			}
		}
	})
}

// The SEND step for the two user-keyed email purposes. An allowlisted address
// must not reach the mailer at all: it is on a reserved .test domain, so the
// message would be accepted by the SMTP server and then bounce into nothing,
// spending quota and building a bounce reputation against the sending address.
func TestDispatchVerificationCode_SkipsSendForAllowlistedEmail(t *testing.T) {
	const allowed = "l3.a@meetups.test"
	svc, _, _, emailSender, _ := newTestService(t)

	t.Run("allowlisted address: no send, no error, both email purposes", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		for _, purpose := range []repository.VerificationPurpose{
			repository.VerificationPurposePersonalEmail,
			repository.VerificationPurposeCorporateEmail,
		} {
			if err := svc.dispatchVerificationCode(context.Background(), purpose, allowed, "654321"); err != nil {
				t.Fatalf("dispatchVerificationCode(%q) returned %v, want nil", purpose, err)
			}
		}
		if len(emailSender.sent) != 0 {
			t.Errorf("email sender was called %d time(s) for an allowlisted address, want 0", len(emailSender.sent))
		}
	})

	t.Run("any other address still sends, with the right purpose", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		if err := svc.dispatchVerificationCode(
			context.Background(), repository.VerificationPurposeCorporateEmail, "real@company.com", "654321",
		); err != nil {
			t.Fatalf("dispatchVerificationCode returned %v, want nil", err)
		}
		if len(emailSender.sent) != 1 {
			t.Fatalf("email sender was called %d time(s) for a non-allowlisted address, want 1", len(emailSender.sent))
		}
		got := emailSender.sent[0]
		if got.to != "real@company.com" || got.code != "654321" || got.purpose != email.PurposeCorporateEmail {
			t.Errorf("sent %+v, want the real target, code, and the CORPORATE purpose", got)
		}
	})
}

// The other send site. email_signup and email_login are target-keyed — there
// is no user row yet — so they never reach dispatchVerificationCode, and a
// skip in that function alone would leave this path mailing .test domains.
// This is the test that would fail if someone "consolidated" the two skips
// into one and missed this call site.
func TestStartTargetKeyedVerification_SkipsSendForAllowlistedEmail(t *testing.T) {
	const allowed = "l1.a@meetups.test"

	t.Run("allowlisted address: no send, still reports the resend cooldown", func(t *testing.T) {
		svc, _, _, emailSender, _ := newTestService(t)
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		res, err := svc.startTargetKeyedVerification(
			context.Background(), repository.VerificationPurposeEmailLogin, allowed,
		)
		if err != nil {
			t.Fatalf("startTargetKeyedVerification returned %v, want nil", err)
		}
		if res.ResendAfterSeconds != int32(otpResendCooldown.Seconds()) {
			t.Errorf("ResendAfterSeconds = %d, want %d — the client must still be told to wait", res.ResendAfterSeconds, int32(otpResendCooldown.Seconds()))
		}
		if len(emailSender.sent) != 0 {
			t.Errorf("email sender was called %d time(s) for an allowlisted address, want 0", len(emailSender.sent))
		}
	})

	t.Run("any other address still sends", func(t *testing.T) {
		svc, _, _, emailSender, _ := newTestService(t)
		t.Setenv("TEST_OTP_BYPASS_EMAILS", allowed)
		if _, err := svc.startTargetKeyedVerification(
			context.Background(), repository.VerificationPurposeEmailSignup, "real@company.com",
		); err != nil {
			t.Fatalf("startTargetKeyedVerification returned %v, want nil", err)
		}
		if len(emailSender.sent) != 1 {
			t.Fatalf("email sender was called %d time(s) for a non-allowlisted address, want 1", len(emailSender.sent))
		}
	})
}
