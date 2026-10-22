package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// hashWorkEmail computes VerifyCorporateEmailCode's reuse-abuse anchor
// (ADR-019 §3) — a keyed HMAC-SHA256 of the normalized raw email address,
// hex-encoded. Deliberately keyed (never a plain SHA-256 of the address
// alone): a well-known address format like firstname.lastname@company.com
// is otherwise trivially reversible by dictionary/rainbow-table attack,
// which would defeat ADR-003's "never retain a reversible copy of the raw
// address" rule in spirit even though only a hash is stored.
func hashWorkEmail(key []byte, email string) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(normalizeEmailForHash(email)))
	return hex.EncodeToString(mac.Sum(nil))
}

// normalizeEmailForHash lowercases and trims the address before hashing —
// so "Jane@AcmeCorp.com" and "jane@acmecorp.com " collide to the same
// hash, matching how a person would actually type the same mailbox twice.
//
// It also drops a +tag (#91). The hash is what enforces "one work mailbox,
// one account", and jane+1@acme.com, jane+2@acme.com and jane@acme.com are
// all the same inbox: without this, one person could verify as many
// accounts as they could invent tags.
//
// Hashes stored before this change were taken without stripping, and the
// raw addresses were never stored, so they cannot be recomputed. That only
// matters for an address that already carried a tag; every untagged
// address hashes exactly as it did.
func normalizeEmailForHash(email string) string {
	email = strings.ToLower(strings.TrimSpace(email))
	at := strings.LastIndexByte(email, '@')
	if at <= 0 {
		return email
	}
	return stripPlusTag(email[:at]) + email[at:]
}

// normalizeCompanyName lowercases and collapses internal whitespace —
// matches known_companies.name_normalized (migration 0007), so "Acme  Corp"
// and "acme corp" both look up the same row.
func normalizeCompanyName(name string) string {
	return strings.Join(strings.Fields(strings.ToLower(name)), " ")
}
