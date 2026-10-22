package auth

import (
	"testing"
)

// TestValidateTestOTPBypassPhones is tracker #92 (review finding N-A6):
// a typo in TEST_OTP_BYPASS_PHONES used to become a silent, permanent
// allowlist entry that nothing could ever match — so the number it was
// meant to cover kept failing verification with no visible cause.
func TestValidateTestOTPBypassPhones(t *testing.T) {
	t.Run("well-formed numbers report nothing", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", "+94770000001,+447700900123")
		if got := ValidateTestOTPBypassPhones(); len(got) != 0 {
			t.Errorf("ValidateTestOTPBypassPhones() = %v, want none", got)
		}
	})

	// The whole point of #82's normalisation reaching this list too: an
	// entry written the way a human types a number still matches the
	// normalised target, and still validates.
	t.Run("spacing and punctuation are normalised, not rejected", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", "+94 77 000-0001")
		if got := ValidateTestOTPBypassPhones(); len(got) != 0 {
			t.Errorf("ValidateTestOTPBypassPhones() = %v, want none", got)
		}
		if !testOTPBypassPhones()["+94770000001"] {
			t.Error("a spaced allowlist entry no longer matches the normalised target")
		}
	})

	t.Run("malformed entries are named", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", "+94770000001,0770000002,ada@example.com,+0123")
		got := ValidateTestOTPBypassPhones()
		// Reported in their NORMALISED form, because that is what is
		// actually in the allowlist and therefore what will never
		// match. NormalizePhone strips dots as phone punctuation, so
		// the pasted address arrives here without its own.
		want := map[string]bool{"0770000002": true, "ada@examplecom": true, "+0123": true}
		if len(got) != len(want) {
			t.Fatalf("ValidateTestOTPBypassPhones() = %v, want %d entries", got, len(want))
		}
		for _, entry := range got {
			if !want[entry] {
				t.Errorf("unexpected entry reported: %q", entry)
			}
		}
	})

	t.Run("unset is not a problem", func(t *testing.T) {
		t.Setenv("TEST_OTP_BYPASS_PHONES", "")
		if got := ValidateTestOTPBypassPhones(); len(got) != 0 {
			t.Errorf("ValidateTestOTPBypassPhones() = %v, want none", got)
		}
	})
}
