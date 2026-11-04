# 30D completion report: profile photos

Status: **complete** (2026-11-04). Working tree only, nothing committed, pushed or deployed.

Migration: **0037** (`auth.user_photos`), additive. Up, down, up is clean, and a test covers the size cap and that a photo goes with its account.

## Backend

- **Storage:** one JPEG per user in `auth.user_photos`, 320 px, at most 100 KB. No bucket and no image server.
- **Normalising (`auth/photo`):**
  - refuses bodies over 300 KB;
  - checks the real format from the first bytes (JPEG, PNG, WebP only);
  - reads the dimensions before decoding, so a decompression bomb is refused;
  - re-encodes, which removes EXIF, GPS included.
- **Routes:** `PUT` and `DELETE /v1/users/me/photo`, `GET /v1/users/{id}/photo` with ETag and 304. Details are in `docs/api/plan-30-changes.md`.
- **Who sees what:** your own photo always; someone else's needs Level 1 or above.
- **Limits:** 10 uploads an hour through the shared limiter; the photo `GET` has its own route limit of 300, since one screen loads many.
- **LinkedIn:** the repeating sync is gone. A picture is fetched once, server-side, when a LinkedIn account is created and has no photo. The fetch allows only https and `.licdn.com`, redirects included, with a 5 second and 2 MB cap.
- **`cmd/backfill-photos`:** one-off, idempotent, with `--dry-run`.
- **Payloads:** `photo_url`, `host_photo_url` and `requester_photo_url` carry our path or nothing. The gateway drops anything else, so no external address reaches a client.

## App

- Tap the avatar on Profile for Take photo, Choose from library, and Remove photo when there is one.
- The phone crops to a circle, 640 px at most, JPEG quality 85, so uploads stay small.
- The avatar shows a spinner during upload. Errors show as a toast and leave the old photo in place.
- The token goes only to our own `/v1/` paths (`PhotoAuth`). Anything else draws initials and is never fetched.
- Camera and library icons added to `AppIcons`.

## Differences from the prompt

- **The old column stays.** The prompt says to drop the old URL column in a later migration. I kept `profile_photo_url`, holding our path. That field already flows through the profile event into the meetup display cache, so reusing it avoided a second pipeline. External addresses are replaced by the backfill.
- **The display cache holds the path, not the bare etag,** for the same reason.
- **Real photos are not in the goldens.** The goldens cover the sheet with and without a photo, in dark and light. `Image.network` cannot load under `flutter test`, so a real picture on the avatar has to be checked on the emulator. That check is part of the Plan 30 close.

## Behaviour to know about

- **Old builds show initials for everyone.** They read the old field names, which are gone. This was the intended fallback; nothing crashes.
- **Until the backfill runs,** LinkedIn users show initials.

## Gates

| Gate | Result |
|---|---|
| `gofmt`, `go vet ./...` | clean |
| `golangci-lint run ./...` | 0 issues |
| `go test -race -count=1 ./...` | 42 packages pass, with Postgres up |
| `govulncheck ./...` | nothing reached; `golang.org/x/net` S-8 waits for 2026-11-10 |
| Migration 0037 up, down, up | clean |
| `flutter analyze --fatal-infos` | no issues |
| `dart format --set-exit-if-changed` | no changes |
| `flutter test` | 901 pass |

## For the owner

After the deploy, run `backfill-photos` and then `backfill-user-display-cache` (runbook §3a, step 5a).
