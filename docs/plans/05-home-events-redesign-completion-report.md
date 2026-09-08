# Completion report — Home/Events IA restructure + hardening carryover

Scope: `docs/plans/home-events-redesign-claude-code-prompt.md` §A–§D, working
from `docs/plans/05-home-events-redesign.md`. Nothing outside §A–C was
touched — billing, the notification outbox and the notification module are
untouched.

Every claim below cites `file:line`.

---

## §A — Security follow-ups

### A1 — `LocationViewPage.open` is gated again

`frontend/lib/features/meetups/location_view_page.dart:63-80`. `open()` now
takes `{required int viewerTrustLevel}` and, at line 66, returns early for
`viewerTrustLevel < 1` with the locked toast (line 68) and a
`VerificationChecklistPage` push (line 72). Level 1+ falls through to the
unconditional push at line 77.

The gate keys on **`viewerTrustLevel`, not `lockedForViewer`**. Those
coincide in production today (after ADR-002 §6 only guests are locked) but
answer different questions, and this one is specifically "has this account
done anything at all to identify itself". The reasoning — including why the
gate was removed last round and why removing it was wrong about this page
though right about the card's coarse label — is written into the doc comment
at lines 29-62 so the next person does not undo it a fourth time. That
comment is explicit that this is UX enforcement, not the security boundary:
the coordinates are already in the response the client holds, so what it buys
is raising bulk collection from "call an endpoint" to "modify the app". The
real fix if it is ever attacked is server-side coarsening for Level 0, which
would be an ADR-002 amendment.

Both call sites pass the viewer's level:
`frontend/lib/features/home/widgets/meetup_card.dart:145-149` and
`frontend/lib/features/meetups/meetup_detail_page.dart`.

### A2 — Dedicated rate limit on guest signup

`backend/internal/gateway/middleware/ratelimit.go:83-89` adds
`accountCreationPaths` (currently just `/v1/auth/guest/signup`),
`accountCreationLimit = 5` and `accountCreationWindow = 24 * time.Hour`.

The check runs at lines 111-117, **before** the body-keyed limiters, and
keys on IP alone — so it never reads the request body, which matters because
the body-reading limiters below it buffer and restore the body, and doing
that work for a request that is going to be rejected anyway is wasted.

While there: `writeRateLimited` (line 181) now takes the window
(`writeRateLimited(w http.ResponseWriter, window time.Duration)`) and emits a
`Retry-After` derived from it. Previously every limiter reported the same
hardcoded value, which for a 24-hour limit would have told the client to
retry in a minute. All five call sites updated.

Tests: `backend/internal/gateway/middleware/ratelimit_test.go` — four new
cases covering the tighter limit, that it is per-IP, that it does not leak
onto other routes, and that the check does not read the body.

### A3 — `schedule_flow.dart` redirects to the host-side page

`frontend/lib/features/meetups/schedule_flow.dart:341-357`. A locked-intent
tap in the scheduling flow is always a **host**-side gate failure, so it now
pushes `HostingUnlockPage` (line 356) rather than
`VerificationChecklistPage`. This matches `home_page.dart`'s already-correct
behaviour. Someone short of the host bar may already be Level 2, and the join
checklist would have shown them a list of things they finished long ago.

---

## §B — `ListOpenMeetups`: two optional filters, no new RPC

**SQL** — `backend/internal/modules/meetup/repository/queries/meetups.sql`,
both queries (`ListOpenMeetupsFirstPage` and `ListOpenMeetupsAfterCursor`):

- line 120 / 176: `AND (sqlc.narg(intent)::meetup.intent_type IS NULL OR m.intent = sqlc.narg(intent)::meetup.intent_type)`
- lines 124-125 / 180-181: `AND (sqlc.arg(within_days)::int = 0 OR m.window_start <= now() + (sqlc.arg(within_days)::int * INTERVAL '1 day'))`

Both queries had to move from positional `$1/$2/$3` to fully named args:
once `intent` became a `narg`, `$1` was unreferenced and sqlc could no longer
infer `$2`/`$3` ("could not determine data type of parameter $1"). Prose
comments that named `$2` were rewritten to match.

**Repository** — `backend/internal/modules/meetup/repository/repository.go:131`
adds `OpenMeetupFilter{Intent *Intent; WithinDays int32}`, threaded through
`ListOpen` at line 151. Both fields default to today's exact behaviour when
unset (nil intent = every intent, 0 days = unrestricted).

**Service** — `backend/internal/modules/meetup/service.go:339-381`.
`maxWithinDays = 365` at line 337; validation at lines 343-348 (a non-nil
intent must name a real one; `within_days` must be in range) returns
`ErrInvalidInput` rather than letting a nonsense value reach Postgres.

**Wire** — `backend/proto/meetup/v1/meetup.proto` gains `int32 within_days = 8`
and documents `INTENT_UNSPECIFIED` as "every intent". No previously *valid*
request changes meaning: an unspecified intent used to be a 400.

Threaded through `internal/grpcapi/meetup.go`,
`internal/gateway/monolithclient/meetup.go`, and
`internal/gateway/handlers/meetups.go` (the `intent` query param is now
optional; `within_days` is parsed strictly).

**Frontend service** — `frontend/lib/core/services/meetup_service.dart` and
`http_meetup_service.dart`: `listOpenMeetups({IntentType? intent, ..., int withinDays = 0})`,
with unset filters omitted from the query string entirely.

Tests: `backend/internal/modules/meetup/integration_test.go` — five new
integration tests (nil intent returns every intent; within_days bounds the
window; both combined; the filters do not affect redaction or the role
fields; an out-of-range within_days is rejected). Gateway handler tests in
`internal/gateway/handlers/meetups_test.go`, including one pinning that the
trust level still comes from the JWT and not from a query param.

---

## §C — Frontend restructure

### Extracted shared widgets (new files)

| File | Lines | What it is |
|---|---|---|
| `frontend/lib/features/home/widgets/meetup_card.dart` | 412 | `MeetupCard`, `LockedCardHeader`, `_StatusPill`, `MeetupsSkeleton` — lifted verbatim from the deleted `matches_page.dart` |
| `frontend/lib/core/widgets/paginated_meetup_list.dart` | 245 | The single infinite-scroll + pull-to-refresh list |
| `frontend/lib/features/home/widgets/intent_filter_bar.dart` | 149 | The one-row intent chip filter, with "All" |
| `frontend/lib/features/home/widgets/happening_soon_section.dart` | 313 | Home's browse section |

`PaginatedMeetupList` replaces two hand-written copies of the same machinery
(one in `matches_page.dart`, one in `my_meetups_page.dart`, the latter with a
comment acknowledging it was a copy). It owns pull-to-refresh itself rather
than relying on each page to remember it — see its doc comment at
`paginated_meetup_list.dart:26-38`.

`MeetupCard` was extracted with **no rendering changes at all**, deliberately:
`LockedCardHeader` is a security property, not styling.

### Home

`frontend/lib/features/home/home_page.dart` (194 lines, rewritten). Order is
`HomeHeader` (144) → `IntentFilterBar` (146) → `ActiveMeetupsSection` (152) →
`HappeningSoonSection` (153) → `SafetyTipCard` (154), with the sole CTA at
lines 169-170 (`FilledButton.icon`, `key: Key('hostYourOwnMeetup')`,
full-width).

- `happeningSoonWithinDays = 7` at `happening_soon_section.dart:28` — a real
  server-side narrowing, so the pagination underneath it pages only within
  the window rather than client-slicing an unbounded list.
- `homeIntentFilterProvider` at `app_providers.dart:147` is
  `StateProvider<IntentType?>` defaulting to null ("All"); `openMeetupsProvider`
  (line 169) is keyed on `(intent, viewerLat, viewerLng, withinDays)`.
- The intent chips gate at the **join** bar (`intent_filter_bar.dart:71`),
  because this filter chooses what to browse and browsing is the join-side
  question. Hosting has its own higher bar and its own button. "All" is never
  locked.
- With "All" selected, `onHostMeetup` asks "can this user host *anything*"
  (`home_page.dart:96-98`) — with no single intent selected there is nothing
  else to gate on, and the scheduling flow's own per-intent step handles the
  rest.
- `HappeningSoonSection` owns the on-demand location read that browsing needs
  (ADR-021 §2), carried over from the deleted page, including the
  fire-and-forget `updateLastKnownLocation`.
- A location block now blocks **the section**, not the page — everything else
  on Home still works without a location.

`IntentPickerSheet` was deleted rather than ported: six intents plus "All" fit
in one scrollable row, so an overflow affordance for a list with no overflow
is just another thing to tap.

### Events

`frontend/lib/features/meetups/events_page.dart` (renamed from
`my_meetups_page.dart`). `EventsPage` keeps `initialTab` because
`meetup_detail_page.dart` still deep-links here. Top tabs are "My Meetings" /
"Requested Meetings"; each renders a `_MeetupList` whose second level is
"Open meetups" / "History". Default is My Meetings → Open meetups.

**Second-level control — changed after visual review.** §C asked for this
level to become a real `TabBar`, and it was one briefly. On device that put
two identically-drawn underlined tab bars directly on top of each other,
separated only by a hairline, so they read as one confusing four-item control
rather than two levels. Shashika called it after seeing it, and it is now a
segmented pair of icon+label pills (`_SubTabSelector`), visually subordinate
to the tab bar above it — which is what the hierarchy actually is.

The pills still drive a real `TabController`, so everything the TabBar bought
over the original pair of `GestureDetector`s is kept: the list still swipes
between Open and History, the selection follows a swipe as well as leading a
tap, and each half is still a `Semantics` tab with a selected state. The open/history split is still computed
client-side from the already-fetched list — only the control changed, and the
filter is applied to appended pages too so a page-2 fetch cannot append
history rows into the open tab.

`app_shell.dart:39` puts `EventsPage()` in slot 1;
`app_bottom_bar.dart:30` is `_NavItem(Icons.event_outlined, Icons.event, 'EVENTS')`.

### Deleted

`matches_page.dart`, `lib/features/matches/` (directory gone),
`network_insights_row.dart`, `intent_grid.dart`, `intent_slider.dart`,
`intent_picker_sheet.dart`; the two header entry chips and
`_MyMeetupsEntryChip` from `home_header.dart`.

---

## Two real bugs the new tests found

Both were found by tests written against behaviour the code *claimed* in its
own comments, and both are fixed rather than tested around.

1. **A short list could not be pulled to refresh.**
   `paginated_meetup_list.dart` kept its empty state inside a scrollable
   specifically so pull-to-refresh would survive an empty list — but passed
   no physics, so a list shorter than the viewport does not scroll, and a
   `RefreshIndicator` has no overscroll to detect on a scrollable that cannot
   scroll. The gesture silently did nothing in exactly the state a user is
   most likely to pull in. Fixed at
   `frontend/lib/core/widgets/paginated_meetup_list.dart:189`
   (`widget.physics ?? const AlwaysScrollableScrollPhysics()` — `??`, not an
   override, so shrink-wrap mode's deliberate `NeverScrollableScrollPhysics`
   still wins).

2. **A stale page could still append after the first page was replaced.**
   `didUpdateWidget`'s identity reset claimed to prevent "a page-2 fetch
   already in flight appending onto a now-stale page one". It did not: the
   State object stays mounted across a refetch-in-place, so the awaiting
   `_loadNextPage` resumed with `mounted` still true and appended the old
   query's continuation onto the new first page — cursors from two different
   queries, silently interleaved. Fixed with a generation counter at
   `paginated_meetup_list.dart:92, 132, 155, 159, 172`.

Plus one smaller one: `MockMeetupService.listOpenMeetups` filtered with
`m.intent == intent`, which returns nothing when `intent` is null — the new
"All" case would have rendered an empty mock list. Fixed at
`frontend/lib/core/services/meetup_service.dart:284`.

---

## §D — Tests

### New files

- **`frontend/test/happening_soon_section_test.dart`** (658 lines, 23 tests)
  — ported from the deleted `matches_page_test.dart`, mounting `HomePage`.
  The guest-tier group is first, per the stated priority. Also covers the
  browse list itself, the new query filters, the 40km geo-visibility
  behaviour carried over from the browse page, the role badges, and this call
  site's load-more wiring.
- **`frontend/test/paginated_meetup_list_test.dart`** (393 lines, 8 tests) —
  infinite scroll, the didUpdateWidget reset, the swallowed-failure retry
  path, pull-to-refresh (including the empty list), and the shrink-wrap mode.
- **`frontend/test/location_view_page_test.dart`** (235 lines, 6 tests) — the
  trust gate as a control run in both directions, plus the GET DIRECTIONS
  deep links ported from the deleted file.

### Renamed / updated

- `my_meetups_page_test.dart` → **`frontend/test/events_page_test.dart`**
  (28 tests) — all 19 pre-existing tests still pass against the renamed page,
  plus a new 9-test group covering the two navigation levels, including that
  the page has exactly one `TabBar` and that the sub-level still swipes with
  the pills following it.
- `frontend/test/home_page_test.dart` (338 lines, 11 tests) — stale comments
  about `NetworkInsightsRow`/`IntentGrid` corrected, button lookups moved to
  the key, plus a new 4-test "removed controls stay removed" group.
- `frontend/test/app_shell_test.dart` — tab 1 is `EventsPage`; a fake
  Geolocator platform added in `setUp`, since tab 0 now does a location read.
- `frontend/test/support/scripted_meetup_service.dart` and
  `fake_meetup_service.dart` — new signature. `ScriptedMeetupService` records
  `lastListOpenMeetupsIntent`/`lastListOpenMeetupsWithinDays`, nullable *and*
  recorded, because null is now a meaningful value on the wire and a test has
  to tell "passed null" apart from "never called".

### Deleted

`matches_page_test.dart` (its 25 tests are ported, not lost — the browse
behaviour split between `happening_soon_section_test.dart`, the pagination
machinery into `paginated_meetup_list_test.dart`, and the map page into
`location_view_page_test.dart`), `network_insights_row_test.dart` and
`intent_picker_sheet_test.dart` (subjects removed), and
`home_header_test.dart` (both its tests were about the two removed entry
chips; the header's own avatar behaviour is covered by
`home_page_test.dart`'s `HomeHeader` group).

### Guest-tier carry-over — verified explicitly, not assumed

Per the requirement that this be checked rather than assumed
(`happening_soon_section_test.dart`, first group, 5 tests):

- the locked card in the *new* location redacts host name and the time
  window, keeps the location label (ADR-002 §5), and shows "Sign up to see
  who's hosting";
- never-redacted fields (intent, joined count, status) still render;
- the join button stays enabled (ADR-028 drops the disabled-button pattern);
- tapping the button *and* tapping the card both toast and redirect, and
  `requestToJoin` is never reached;
- an unlocked card at Level 2 is the control run.

The fixture's `locationLabel` carries the comment explaining that a locked
meetup deliberately keeps a real label, so a future revert to null shows up
as a redaction-contract change rather than a fixture tweak.

---

## The four explicit confirmations

**1. Zero references to `MatchesPage` / `matches_page.dart` before deletion.**
Confirmed. `lib/features/matches/` no longer exists. Nine matches remain
across `lib/` and `test/`, and every one is prose in a comment recording what
was removed and why — `lib/app_shell.dart:35`,
`lib/core/widgets/paginated_meetup_list.dart:22`,
`lib/features/home/widgets/meetup_card.dart:21`, `test/app_shell_test.dart:346`,
`test/paginated_meetup_list_test.dart:15,23`,
`test/happening_soon_section_test.dart:24`,
`test/location_view_page_test.dart:17`,
`test/support/fake_auth_service.dart:10`. No import, no symbol, no route.

Two stale prose references that pointed at genuinely deleted things were
corrected rather than left: `lib/app_shell.dart` described the sync listener
as serving "HomePage's FIND MATCHES button jumping straight to the Matches
tab" (both gone), and `meetup_card.dart` pointed at `intent_picker_sheet.dart`
(deleted) for a toast-wording precedent.

**2. The new backend filter did not touch `redactForViewer` /
`requiredTrustLevelTo*`.** Confirmed. `redactForViewer` is defined at
`backend/internal/modules/meetup/convert.go:119`;
`requiredTrustLevelToJoin`/`requiredTrustLevelToHost` at
`backend/internal/modules/meetup/trustgate.go:31` and `:48`. Both files carry
mtimes from the *previous* round (`convert.go` 18:40:07, `trustgate.go`
18:39:27) while every §B edit is 20:18-20:19 — so neither was opened, let
alone changed. (Git diff is uninformative here: the repo has this work
untracked.)

Structurally as well as by timestamp: in
`service.go:339-381` the two new validations and the filter construction all
sit *before* the read, and the redaction loop at lines 376-379 is unchanged —
it still calls `redactForViewer(&out[i], req.ViewerTrustLevel)` for every row
unconditionally, regardless of which filter produced the page.
`TestListOpenMeetups_FiltersDoNotAffectRedactionOrRoleFields_Integration`
(`integration_test.go:1781`) pins this from the outside: a guest is still
redacted through the filtered path with the location still visible, and both
role fields (`IsHostedByMe` and `MyRequestStatus`) are still annotated
correctly.

**3. "FIND MATCHES" and `onFindMatches` are fully removed, not hidden.**
Confirmed. `onFindMatches` has zero occurrences anywhere in `lib/` or `test/`.
The string "FIND MATCHES" survives only in explanatory comments
(`home_page.dart:21,28,164`, `app_shell.dart:108`) and in the removal-guard
test itself (`test/home_page_test.dart:297,303`). There is no hidden widget,
no `Visibility`, no dead handler — `home_page.dart:169` shows the CTA block
now contains exactly one button, and the test group at
`home_page_test.dart:278-337` asserts the button, "Your Stats", and both
header entry chips all render nothing.

**4. All gates pass.**

```
flutter analyze                        No issues found!
dart format --set-exit-if-changed      139 files (0 changed), exit 0
flutter test                           +342: All tests passed!
go build ./...                         ok
go vet ./...                           ok
golangci-lint run ./...                0 issues.
go test ./...                          exit 0 (21 packages ok, 0 failures)
```

---

# Follow-ups from device review (2026-09-07/08)

Four rounds of feedback after running the build on device. Each is recorded
with what was asked, what was actually wrong underneath, and what changed.

## 1. The Open/History sub-tabs looked wrong

Asked: replace them with two buttons with icons.

§C had specified a real `TabBar` here and it was one. On device that put two
identically-drawn underlined tab bars directly on top of each other,
separated by a hairline, so they read as one four-item control. Replaced with
`_SubTabSelector` (`frontend/lib/features/meetups/events_page.dart`), a pair
of icon+label pills — flat, matching `IntentFilterBar`'s chips rather than
introducing a third button style.

It still drives a real `TabController`, so everything the TabBar bought over
the original hand-rolled `GestureDetector` pair is kept: the selection
follows a swipe as well as leading a tap, and each half is a `Semantics` tab
with a selected state.

This reverses a specific §C instruction, deliberately and on request.

## 2. "Could not load meetups near you" shown when there was simply nothing

Asked: show that message only for a genuine network problem; show a friendly
invitation when there is nothing to list.

Three real defects underneath, all fixed:

**a. Nothing could distinguish offline from a server error.**
`MeetupNetworkException` is thrown for a 400 *and* for every unmapped status
including 5xx — cases where the server was reached and answered. A genuine
transport failure, meanwhile, escaped as a raw `SocketException` /
`http.ClientException` and never became a `MeetupException` at all. So no
screen could tell the two apart even if it wanted to.

Added `MeetupOfflineException`
(`frontend/lib/core/services/meetup_service.dart`) and a `_send` wrapper in
`http_meetup_service.dart` that maps `SocketException`,
`http.ClientException` and `TimeoutException` onto it — narrowly, so a
response that arrives and happens to be a 500 is still an ordinary mapped
error. The exception's own text is discarded: it carries hostnames, ports and
errno strings.

`_ErrorState` now branches on that one type — "You're offline / Check your
connection" versus "Could not load meetups right now / This one is on us, not
you."

**b. The failure card was unreachable while Riverpod retried.**
Found by the test, not by reading. Riverpod 3 auto-retries a failed provider
with backoff, and while a retry is pending the state is `AsyncLoading` *that
carries the error*. `.when()` therefore took its `loading:` branch, so an
offline user sat on a shimmer indefinitely — no message, no retry button —
until the retry schedule ran out.

`happening_soon_section.dart` no longer uses `.when()`. It orders by what is
most useful to show: any page we have (even mid-refresh, so a refresh never
blanks the list being read), else an error as soon as the FIRST attempt
fails, else the skeleton. The background retry continues regardless and lands
on the first branch if it succeeds.

**c. The empty state was a bare sentence.**
Now `_NoMeetupsYet` — a friendly icon, copy that names the gap ("No coffee
meetups near you this week", intent-aware so "no coffee meetups" is not
mistaken for "no meetups at all"), and an invitation to host or check back.
Deliberately *not* its own host button: Home's CTA is permanently on screen a
few centimetres below and carries the host-side trust gate (ADR-002 §4); a
second entry point would duplicate that gate or skip it.

`PaginatedMeetupList` gained an optional `emptyState` widget slot alongside
the existing `emptyMessage` string.

## 3. Could not swipe off the Events page

Asked: swiping should move between main pages from Events too.

Structural, not a bug in one widget: Events stacked THREE horizontal gesture
consumers — AppShell's `PageView`, the page's tab `TabBarView`, and each
list's Open/History `TabBarView`. Flutter gives a horizontal drag to the
innermost scrollable and never hands it back mid-gesture, so exactly one of
the three could ever respond, and it was the innermost. Events was the one
page a swipe could not leave.

Decision (Shashika): a swipe means the same thing everywhere — move between
main pages. Both Events `TabBarView`s now take
`NeverScrollableScrollPhysics`; tabs switch by tap, on controls permanently
on screen. `_RequestManagementPage` is deliberately excluded — it is a pushed
route, outside AppShell's PageView, with no competing ancestor, so its tabs
still swipe.

Proven by a new `app_shell_test.dart` case that swipes Events -> Safety and
Events -> Home.

## 4. Profile showed "12 MEETUPS" for a new account

Asked: show real numbers, no hardcoded values, and check the others.

Audited the whole page. `'12'` was the only *literal*, but two of the three
chips were wrong:

**MEETUPS was hardcoded.** No completed-meetup count existed anywhere in the
backend — no column, no proto field, no query. Built end-to-end, mirroring
the existing `rating_average`/`rating_count` arrangement exactly rather than
inventing a second pattern:

- `migrations/0005_meetups_completed_cache.{up,down}.sql` — `meetups_completed`
  plus `meetups_completed_updated_at` on `auth.users`, a read-only cache.
- `RecomputeMeetupsCompletedForParticipants` (meetup queries) — one statement
  returning each participant's new total, run inside the transaction that
  completed the meetup.
- Published post-commit from both completion paths (`Close` and the
  auto-close sweep) in `meetups_postgres.go`; the starting-soon sweep
  deliberately does not, since it changes no meetup's status.
- `TopicMeetupsCompletedUpdated` / `MeetupsCompletedUpdatedPayload`, consumed
  by `auth.ApplyMeetupsCompletedUpdate` into the cache, wired in
  `cmd/monolith/main.go`.
- Proto field 19, gateway JSON, `UserProfile.meetupsCompleted`, and the chip.

The event carries an **absolute total, never a delta** — that is what makes
the consumer idempotent, since a redelivered "+1" would inflate the figure
and an absolute value re-applies harmlessly. Same `occurred_at` ordering
guard as the rating cache. `TestMeetupsCompleted_CountsAccumulateAndAreAbsolute`
pins it: three closes publish 1, 2, 3 — not 1, 1, 1 and not 1, 3, 6.

Participant = host plus every `accepted` requester. Deliberately not gated on
the Safety Gate check-in: that is an affordance people can legitimately skip,
and someone who attended without opening the checklist has still completed a
meetup. Same definition `IsParticipant` uses elsewhere.

**RATING could only ever show a dash.** Found while auditing. `rating_average`
and `rating_count` were populated by the monolith and carried by
`monolithclient.Profile`, but `profileResponse` — the only thing the app sees
— had no fields for them, so the gateway silently dropped them. Every user's
rating rendered as "no ratings yet" regardless of their actual score. Fixed
in `internal/gateway/handlers/verification.go`, with
`TestGetProfile_SerializesTheStatsRow` asserting on the JSON rather than on
any single layer, which is what would have caught it.

**TRUST was correct** and is unchanged.

### Note for deployment

Migration 0005 is applied by the golang-migrate container at
`docker compose up`, so the stack needs a restart to pick it up. No backfill:
existing accounts start at a truthful 0 and get their real total the next time
one of their meetups completes.

## Gates after this round

```
flutter analyze                        No issues found!
dart format --set-exit-if-changed      139 files (0 changed), exit 0
flutter test                           +350: All tests passed!
go build ./...                         ok
go vet ./...                           ok
golangci-lint run ./...                0 issues.
go test ./...                          exit 0 (21 packages ok, 0 failures)
```
