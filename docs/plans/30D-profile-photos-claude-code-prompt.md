# Claude Code prompt 30D: user profile photos

Read first: `docs/plans/30-review-fixes-photos-sos-reviews.md` (sections 1 and 2.1, decision D3), the LinkedIn photo code (`backend/internal/modules/auth/identity_resolution.go` around the "linkedin profile photo sync" path, `auth/linkedin/client.go`), where `profile_photo_url` is produced and consumed (auth repository and service, meetup display cache, gateway handlers, proto), and in `frontend/`: `lib/features/profile/profile_page.dart`, `lib/core/widgets/professional_avatar.dart` (or wherever avatars render), `lib/core/models/{user_profile,public_profile,meetup,auth_session}.dart`, `lib/core/storage/session_storage.dart`.

Hard rules: plan section 1. Keep it small: one stored size, no bucket, no image server, no new background jobs except the one-off backfill command.

## Backend

1. Migration: `auth.user_photos (user_id PK, jpeg BYTEA NOT NULL, etag TEXT NOT NULL, width INT, height INT, bytes INT, updated_at)` with a `CHECK (bytes <= 102400)`. Deleted with the account (add to the deletion path and its test).
2. `internal/modules/auth/photo` package:
   - `Normalize(raw []byte) (jpeg []byte, w, h int, err error)`: refuse more than 300 KB; sniff magic bytes (JPEG, PNG, WebP only); `image.DecodeConfig` first and refuse more than 4096 px per side; decode; centre-crop to square if needed (the app already crops); resize to 320 x 320 with `golang.org/x/image/draw` (CatmullRom); encode JPEG quality 80. Pure Go, no cgo. Pin dependency versions at least two weeks old and run `govulncheck`.
   - Etag = first 16 hex characters of SHA-256 of the output.
3. Routes: `PUT /v1/users/me/photo` (body `image/jpeg`, `image/png` or `image/webp`, 300 KB cap at the gateway, 10 per user per hour via the shared limiter), `DELETE /v1/users/me/photo`, `GET /v1/users/{id}/photo` (auth required; Level 0 callers get 404 for others' photos wherever names are hidden today; own photo always; `ETag`, `Cache-Control: private, max-age=86400`, 304 on `If-None-Match`; `Content-Type: image/jpeg`; `X-Content-Type-Options: nosniff`).
4. Every payload that carried an external `profile_photo_url` now carries `photo_url = /v1/users/{id}/photo?v=<etag>` or empty. The meetup display cache stores the etag, not bytes, and is updated through the existing user-profile event path.
5. LinkedIn: remove the repeating photo sync. On account **creation** through LinkedIn onboarding with no photo row, fetch the LinkedIn picture once server-side (https only, host must end in `.licdn.com`, no cross-host redirects, 5 s timeout, 2 MB cap), run `Normalize`, store. Connecting LinkedIn later or signing in again never touches an existing photo. Google and Apple never set photos.
6. `cmd/backfill-photos`: one-off, for accounts with a stored LinkedIn URL and no photo row; same fetch rules; idempotent; dry-run flag; then drop the old URL column in a later migration once the backfill has run in production (document the order in the runbook).

Tests: `Normalize` with valid JPEG, PNG and WebP, a PNG renamed as JPEG, a decompression bomb (huge dimensions in the header), a 301 KB body, an image with EXIF GPS (output has no EXIF), output size and dimensions; routes (own, other, Level 0, 304, delete, rate limit); LinkedIn create sets a photo, later sign-in and later link do not overwrite; SSRF guard (non-licdn host, redirect to another host).

## App

7. Add `image_picker` and `image_cropper` (pinned, at least two weeks old; add the iOS camera and photo library usage strings and the Android crop activity as the package requires).
8. Profile: tapping the avatar opens "Take photo", "Choose from library", "Remove photo" (when one exists). After picking, the cropper opens with a square aspect, circle overlay, pinch and drag to position, output at most 640 px, JPEG quality 85. Upload with a progress state; on success refresh the session profile and every visible avatar; errors use existing snack styles.
9. Avatars everywhere load `photo_url` with the auth header through one shared widget, decode at display size (`cacheWidth`), fall back to initials, and never block the UI.
10. Remove client code tied to the LinkedIn photo sync.

Tests: picker cancelled, cropper cancelled, upload success updates the avatar, upload error, remove, fallback to initials, header sent, Level 0 view shows initials.

Finish with the gates, golden or screenshot tests of the photo states in dark and light, and `docs/plans/30D-completion-report.md`. Do not start 30E.
