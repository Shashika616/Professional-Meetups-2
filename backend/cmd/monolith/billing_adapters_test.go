package main

import (
	"context"
	"testing"

	"professional-meetups-monolith/backend/internal/modules/auth"
)

type profileStub struct{ p auth.Profile }

func (s profileStub) GetProfile(context.Context, string) (auth.Profile, error) { return s.p, nil }

// Review fix 6: an email_domains flag rule must only ever see a verified
// address — otherwise typing someone@meetups.test into a profile would join
// the test allowlist.
func TestFlagEmailResolverReturnsOnlyAVerifiedEmail(t *testing.T) {
	ctx := context.Background()
	unverified := flagEmailResolver(profileStub{auth.Profile{PersonalEmail: "x@meetups.test"}})
	if got, err := unverified(ctx, "u"); err != nil || got != "" {
		t.Fatalf("unverified email resolved to %q, %v; want empty", got, err)
	}
	verified := flagEmailResolver(profileStub{auth.Profile{PersonalEmail: "x@meetups.test", PersonalEmailVerified: true}})
	if got, err := verified(ctx, "u"); err != nil || got != "x@meetups.test" {
		t.Fatalf("verified email resolved to %q, %v", got, err)
	}
}

// The welcome fingerprint follows the same rule, and two accounts with the
// same verified phone get the same fingerprint.
func TestIdentityFingerprintUsesOnlyVerifiedAnchors(t *testing.T) {
	ctx := context.Background()
	fp := func(p auth.Profile) string {
		got, err := identityFingerprint{auth: profileStub{p}, key: []byte("k")}.Fingerprint(ctx, "u")
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	if fp(auth.Profile{PhoneNumber: "+94771234567", PersonalEmail: "a@b.c"}) != "" {
		t.Fatal("unverified phone and email produced a fingerprint")
	}
	a := fp(auth.Profile{PhoneNumber: "+94771234567", PhoneVerified: true})
	b := fp(auth.Profile{PhoneNumber: "+94771234567", PhoneVerified: true, PersonalEmail: "other@x.y", PersonalEmailVerified: true})
	if a == "" || a != b {
		t.Fatalf("same verified phone gave %q and %q", a, b)
	}
	if fp(auth.Profile{PersonalEmail: "A@B.C", PersonalEmailVerified: true}) != fp(auth.Profile{PersonalEmail: "a@b.c", PersonalEmailVerified: true}) {
		t.Fatal("email fingerprint is case-sensitive")
	}
}
