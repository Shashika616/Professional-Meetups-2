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
func normalizeEmailForHash(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

// normalizeCompanyName lowercases and collapses internal whitespace —
// matches known_companies.name_normalized (migration 0007), so "Acme  Corp"
// and "acme corp" both look up the same row.
func normalizeCompanyName(name string) string {
	return strings.Join(strings.Fields(strings.ToLower(name)), " ")
}
