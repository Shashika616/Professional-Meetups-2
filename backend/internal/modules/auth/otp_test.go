package auth

import (
	"regexp"
	"testing"
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
	if !otpMatches(hash, "123456") {
		t.Error("otpMatches(hash, correct code) = false, want true")
	}
	if otpMatches(hash, "654321") {
		t.Error("otpMatches(hash, wrong code) = true, want false")
	}
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
