-- name: InsertIdentity :one
INSERT INTO auth.user_identities (user_id, provider, subject, email)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetIdentityByProviderSubject :one
SELECT * FROM auth.user_identities WHERE provider = $1 AND subject = $2;

-- name: ListIdentitiesForUser :many
SELECT * FROM auth.user_identities WHERE user_id = $1 ORDER BY linked_at;
