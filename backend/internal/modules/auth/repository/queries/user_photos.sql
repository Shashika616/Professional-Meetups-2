-- name: UpsertUserPhoto :exec
INSERT INTO auth.user_photos (user_id, jpeg, etag, width, height, bytes)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (user_id) DO UPDATE
SET jpeg = excluded.jpeg, etag = excluded.etag, width = excluded.width,
    height = excluded.height, bytes = excluded.bytes, updated_at = now();

-- name: GetUserPhoto :one
SELECT jpeg, etag FROM auth.user_photos WHERE user_id = $1;

-- name: GetUserPhotoEtag :one
-- For a conditional request: the etag alone, without reading the bytes.
SELECT etag FROM auth.user_photos WHERE user_id = $1;

-- name: DeleteUserPhoto :exec
DELETE FROM auth.user_photos WHERE user_id = $1;
