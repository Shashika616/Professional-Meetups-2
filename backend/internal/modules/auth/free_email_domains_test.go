package auth

import (
	"strings"
	"testing"
)

// #91. One work mailbox may verify one account: the hash of the address is
// what enforces it. A +tag reaches the same inbox, so it must hash the same.
func TestWorkEmailHash_IgnoresAPlusTag(t *testing.T) {
	key := []byte("test-key")
	base := hashWorkEmail(key, "jane@acme.com")
	for _, variant := range []string{"jane+1@acme.com", "Jane+Work@ACME.com", " jane+@acme.com "} {
		if got := hashWorkEmail(key, variant); got != base {
			t.Errorf("%q hashes differently from jane@acme.com: one person could "+
				"verify a second account with the same mailbox", variant)
		}
	}
	// A different person is still a different hash.
	if hashWorkEmail(key, "john@acme.com") == base {
		t.Error("two different mailboxes hashed the same")
	}
	// A leading + is a real local part, not a tag; leave it alone.
	if normalizeEmailForHash("+jane@acme.com") != "+jane@acme.com" {
		t.Error("an address starting with + was rewritten")
	}
}

// A tag did not make a shared mailbox personal.
func TestCorporateEmail_RoleAddressWithATagIsStillRejected(t *testing.T) {
	for _, email := range []string{"info+x@acme.com", "HR+hiring@acme.com"} {
		if !isRejectedCorporateEmail(email) {
			t.Errorf("%q passed as a personal work address", email)
		}
	}
	if isRejectedCorporateEmail("jane+x@acme.com") {
		t.Error("a personal address with a tag was rejected")
	}
}

func TestFreeEmailDomains_CoverTheCommonProviders(t *testing.T) {
	for _, domain := range []string{
		"gmail.com", "googlemail.com", "outlook.com", "live.com", "yahoo.com",
		"icloud.com", "proton.me", "rediffmail.com", "sltnet.lk",
	} {
		if !isRejectedCorporateEmail("jane@" + domain) {
			t.Errorf("jane@%s was accepted as a work email", domain)
		}
	}
	if isRejectedCorporateEmail("jane@acme.com") {
		t.Error("a company domain was rejected")
	}
}

// The list is a hand-edited file, so keep it clean: lowercase, no
// duplicates, nothing that is not a bare domain.
func TestFreeEmailDomains_FileIsTidy(t *testing.T) {
	seen := map[string]bool{}
	for i, line := range strings.Split(freeEmailDomainsFile, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if line != strings.ToLower(line) {
			t.Errorf("line %d %q is not lowercase", i+1, line)
		}
		if strings.ContainsAny(line, " @/") || !strings.Contains(line, ".") {
			t.Errorf("line %d %q is not a bare domain", i+1, line)
		}
		if seen[line] {
			t.Errorf("line %d %q is a duplicate", i+1, line)
		}
		seen[line] = true
	}
	if len(seen) < 30 {
		t.Errorf("only %d domains loaded; the embed may be broken", len(seen))
	}
}
