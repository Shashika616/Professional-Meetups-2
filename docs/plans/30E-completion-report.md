# 30E completion report: host reviews, client fixes, structure, docs

Status: **complete** (2026-11-04). Working tree only, nothing committed, pushed or deployed. No new migration: 0037 is still the latest.

## Host reviews (2.3)

- **Meetups:** a profile lists only finished meetups the member **hosted**, with intent, day, area, turnout and average. The hour never leaves the server.
- **Reviews:** a new `reviews` list holds score, text and month, the same for every viewer. The name-reveal logic is gone, and the query cannot return an author.
- **Average:** it now leaves out the host's own review. Before, a host could raise their own score.
- **A member who only joined:** count and rating only.
- **Length:** text is capped at 500 characters on read as well, counted in characters, not bytes.

**One choice beyond the prompt:** reviews sit in their own section instead of under a meetup. Under a meetup of three, the guest list would have narrowed down the author.

**Old builds:** the gateway still sends `id` (empty), `hosted` and both window fields, because old builds crash without `id`. They show no comments and read "12:00 PM" on every past meetup.

## Client fixes

| Item | Change |
|---|---|
| N1-D1 location | Uploads are rounded to 3 decimals on the phone. `OtherMeetupsNearby` reads a known location and never starts a read. An explanation screen comes before the first prompt. The iOS Always text is removed. The map picker opens at the rounded location when known. |
| N1-D2 purchases | One listener per signed-in user, started by `AppShell`. It waits for the catalog, routes by product id, and leaves anything it cannot place pending. |
| N1-D3 version | `UpdateGate` blocks the whole app below the minimum, at start and on resume. |
| N1-D4 426 | The credit client brings up the same screen. |
| N1-D5 install id | Rotates on sign-out and account deletion, after a 3 second try at sending what is queued. |
| N1-D6 429 | A rate-limited refresh at launch stays signed in. |
| N1-D8 opt-out | Aborts a send in progress with `AbortableRequest`. |

**Also fixed:** the privacy page still said contacts are texted once to agree, which ADR-013 removed. Stale 40 km comments in the app now say 50 km.

## Structure (3.4)

Every target file is now under 600 lines, with no exceptions.

| File | Before | After | New files |
|---|---|---|---|
| `meetups_postgres.go` | 1329 | 438 | `meetups_list_`, `_lifecycle_`, `_member_postgres.go` |
| `meetup/service.go` | 1110 | 297 | `service_create`, `_read`, `_lifecycle`, `_events.go` |
| `auth/service.go` | 915 | 353 | `service_signup`, `_email`, `_session.go` |
| `handlers/meetups.go` | 827 | 390 | `meetups_requests`, `_safety`, `_reviews.go` |
| `profile_page.dart` | 1686 | 510 | 5 part files |
| `schedule_flow.dart` | 1592 | 525 | 3 part files |
| `events_page.dart` | 1502 | 518 | 2 part files |
| `meetup_detail_page.dart` | 1462 | 533 | 3 part files |

Dart uses `part` files so private widgets stay private. Code moved without changes.

**Deviation:** the prompt asks for one file per step with the suite green around each. I split the Go files as one step and the Dart files as a second, and ran the full suites after each. My Dart split script over-matched on two files and moved parts of `build` methods. The analyzer failed, I restored those lines, and the full suite passed afterwards.

## Emulator check (Pixel 8, local stack at migration 0037)

| Check | Result |
|---|---|
| Photo sheet, without a photo | No Remove option |
| Choose from library, circle crop | Works |
| Upload | 3.7 KB, 320 x 320, path reached the display cache, avatar loaded with the token |
| Remove | Row gone, cache empty, initials back |
| Location explanation | Shown before the system prompt, not shown again |
| System prompt | "While using the app" and "Only this time"; no Always |
| Home after granting location | Loads with a fix. Without one it shows the existing retry card |
| Update gate | Blocks on return to the foreground, clears when the minimum drops |
| `GET /v1/users/{id}` | Blank id, day only, reviews with score, text and month only |

**Not checked on a device:** store purchases (need a store account), the camera path, the iOS build, and the reviews section on screen (widget tests cover it; the API response was checked live).

## Gates

| Gate | Result |
|---|---|
| `gofmt`, `go vet ./...` | clean |
| `golangci-lint run ./...` | 0 issues |
| gosec, as CI runs it | 0 |
| `go test -race -count=1 ./...` | 42 packages pass, with Postgres up |
| `govulncheck ./...` | nothing reached; S-8 waits for 2026-11-10 |
| `flutter analyze --fatal-infos` | no issues |
| `dart format --set-exit-if-changed` | no changes |
| `flutter test` | 939 pass |
