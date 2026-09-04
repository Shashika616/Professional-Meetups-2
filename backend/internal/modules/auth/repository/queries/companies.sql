-- Company verification database (ADR-019 §3, migration 0007) — the
-- previously-deferred Verification Model § 5 piece, built now.

-- name: GetKnownCompanyByNameNormalized :one
-- Matching happens against name_normalized (lowercased, whitespace-
-- collapsed) — never the raw display name a user typed. Returns
-- apperror.ErrNotFound (wrapped) for an unknown company, the MVP fallback
-- case (ADR-019 §3).
SELECT * FROM auth.known_companies WHERE name_normalized = $1;

-- name: InsertUnverifiedCompanyClaim :exec
-- Flags an unknown-company (name, domain) pair for the not-yet-assigned
-- manual reviewer (ADR-019 §3) — no reviewer UI in this slice, just the
-- queue.
INSERT INTO auth.unverified_company_claims (user_id, company_name_entered, domain)
VALUES ($1, $2, $3);
