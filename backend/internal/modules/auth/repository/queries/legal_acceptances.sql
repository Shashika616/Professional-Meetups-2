-- name: InsertLegalAcceptance :exec
INSERT INTO auth.legal_acceptances (user_id, version, app_version, platform)
VALUES ($1, $2, $3, $4)
ON CONFLICT (user_id, version) DO NOTHING;

-- name: HasLegalAcceptance :one
SELECT EXISTS (
  SELECT 1 FROM auth.legal_acceptances WHERE user_id = $1 AND version = $2
);

-- name: CurrentLegalDocuments :one
SELECT version, terms, privacy FROM ops.legal_documents
ORDER BY published_at DESC
LIMIT 1;

-- name: PublishLegalDocuments :exec
INSERT INTO ops.legal_documents (version, terms, privacy) VALUES ($1, $2, $3);
