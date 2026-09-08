# Plan — Home/Events IA restructure + carried-over hardening

Two unrelated batches, shipped together because both are ready: (1) the two
security follow-ups from the guest-login review that were never actioned,
(2) a UI/IA restructure requested directly by Shashika. No new domain
decision here worth a vault ADR — this reuses the existing trust model,
existing RPCs (mostly unchanged), and existing widgets; it's reorganized, not
redesigned. Read `docs/plans/04-guest-login-trust-redesign.md` and
`docs/decisions/adr-002-guest-login-and-trust-level-redesign.md` first if
§A doesn't make sense in isolation.

## §A — Hardening carryover (do this first, it's small)

1. **`LocationViewPage.open` needs a guest-tier gate back**, narrower than
   the one ADR-002 removed. Currently it opens unconditionally for every
   viewer, sending exact `lat`/`lng` and the interactive map to Level 0
   (guest) accounts — combined with guest signup's total lack of identity
   verification, this is a scriptable way to scrape exact meetup coordinates
   at scale. Fix: gate on `viewerTrustLevel < 1` specifically (not
   `lockedForViewer`, which is now guest-only anyway per ADR-002 §6) — a
   guest tapping "VIEW LOCATION" gets the toast + `VerificationChecklistPage`
   redirect (same pattern every other locked action already uses); Level 1+
   opens the real page unconditionally, same as today. The coarse location
   *label* on the card itself stays visible to guests — this only gates the
   interactive map/exact-coordinates view, per ADR-002 §5's original intent.
2. **`GuestSignup` needs its own rate limit**, tighter than the blanket
   20/min-per-IP every route shares. It's the only endpoint that creates a
   fully functional, zero-verification account. Add a dedicated limit — a
   handful per IP per day is enough; a real device only ever calls this once.
   Reuse whatever limiter infra `middleware/ratelimit.go` already has
   (email-keyed / target-keyed patterns exist for other sensitive routes —
   follow that shape, don't invent a new mechanism).
3. `schedule_flow.dart`'s locked-intent tap redirects to
   `VerificationChecklistPage` even when the gate that failed was the
   host-side one — should redirect to `HostingUnlockPage` in that case,
   matching what `home_page.dart`'s `onHostMeetup` already does correctly.
   (The other flagged nit — a stale comment in `matches_page.dart` — is
   superseded by §C deleting that file; no separate action needed.)

## §B — Backend: one new optional filter, no new endpoint

`ListOpenMeetupsRequest` (`internal/modules/meetup/types.go:116`) gains two
optional fields, both defaulting to "no restriction" so every existing caller
is unaffected:

- `Intent *Intent` (currently a required, single, non-nullable `Intent`) —
  nil means "all intents," matching the new home-page "All" filter option.
  When set, behaves exactly as today.
- `WithinDays int32` (0 = unrestricted) — when > 0, adds
  `AND window_start <= now() + ($N || ' days')::interval` to the query
  (`repository/meetups_postgres.go`'s `ListOpen` query). This is the only
  thing that makes a "Happening Soon" (next 7 days) view possible — nothing
  in this module supports a date-range filter today, confirmed by direct
  read of the query.

Everything else about the RPC is unchanged: same cursor pagination
(`Cursor`/`NextCursor`, page size 20/50), same per-meetup redaction
(`redactForViewer`, keyed on the flat Level 0/1+ split from ADR-002, entirely
independent of this filter), same `IsHostedByMe`/`MyRequestStatus` role
annotation already computed server-side — the frontend's "hosted by you" /
"requested" badges on the new Happening Soon cards need **no new backend
work**, that data is already on every `Meetup` returned today.

`checkTrustLevel`/`requiredTrustLevelToJoin`/`ToHost` are unaffected — this
filter only changes which rows are returned, not who's allowed to act on
them.

## §C — Frontend restructure

### C1. Bottom nav: "Matches" tab becomes "Events"

`app_shell.dart` — the tab currently routing to `MatchesPage` now routes to
a renamed `EventsPage` (see C3). Icon/label updated to "Events". `Home`,
`Safety`, `Chats`, `Profile` tabs unchanged.

### C2. `matches_page.dart` is dissolved, not just hidden

Its browsing UI moves into Home (C4) — extract, don't duplicate:

- `_MeetupCard`, `LockedCardHeader`, `_IntentTabsBar`-style filter chip row,
  and the `_MeetupList` cursor-pagination logic (`ScrollController` + 400px
  near-bottom trigger + `_hasMore`/`_loadingMore` guards) move to shared
  widgets — suggest `features/home/widgets/meetup_card.dart` and a new
  `core/widgets/paginated_meetup_list.dart` (see C5, this is also the fix for
  the two already-hand-duplicated copies of this exact pagination logic).
- Once extracted and Home (C4) is using them, delete `matches_page.dart` and
  its test file. Confirm nothing else references `MatchesPage` before
  deleting (grep first).

### C3. `my_meetups_page.dart` → `events_page.dart`

Rename the class (`MyMeetupsPage` → `EventsPage`) and file. Structural
change, not a rewrite — the data layer (`myMeetupsProvider`,
`listMyMeetups`, independent hosted/requested cursors,
`_RequestManagementPage`, the rating-prompt-on-reject flow) is unchanged:

- Top-level tabs relabeled: "HOSTING" → **"My Meetings"**, "REQUESTED" →
  **"Requested Meetings"**. Same `initialTab` deep-link params, same data
  source.
- The existing client-side "OPEN"/"HISTORY" toggle inside each tab (already
  built, per ADR-016 — currently two buttons, not real tabs) becomes a real
  second-level tab bar: **"Open meetups"** / **"History"**. Same filter logic
  underneath (`status IN (open, full)` vs. `status IN (completed,
  cancelled)`, computed client-side from the already-fetched list — no
  backend change needed here). This is the "realistic tab view" ask — use
  Flutter's actual `TabBar`/`TabBarView` for both levels, not custom toggle
  buttons standing in for tabs.
- Default view on open: My Meetings → Open meetups (matches today's
  `initialTab: 0` + default-open behavior).
- Every navigation destination reached from here today (tap a hosted item →
  `_RequestManagementPage`; tap a requested item → `MeetupDetailPage`) is
  unchanged.

### C4. `home_page.dart` restructure

New top-to-bottom order:

1. `HomeHeader` — **drop the two `_MyMeetupsEntryChip` buttons** ("Your
   Meetings"/"Requested Meetups"); that navigation now happens via the
   Events bottom-nav tab (C1). Keep the notification bell and everything
   else in the header unchanged.
2. **Intent filter, compact, moved up, with an "All" option.** Replace
   `IntentGrid`'s 2-column grid-of-tiles with a single-row horizontal chip
   bar (reuse `matches_page.dart`'s `_IntentTabsBar` chip pattern from C2,
   it's already close to this shape) — smaller footprint, one visible row,
   horizontally scrollable, locked intents shown with a lock icon exactly as
   today. Add an **"All"** chip as the first option, mapping to
   `Intent: nil` in the new backend filter (§B) — selecting it shows
   meetups across every intent. `intent_grid.dart` and the confirmed-dead
   `intent_slider.dart` can both be deleted once this replaces them (grep
   first to confirm no other caller of `IntentGrid` exists before deleting
   it — `IntentPickerSheet`, the "MORE" overflow sheet, may still be worth
   keeping as a secondary access point, or may become redundant now that
   every intent fits in one scrollable row; decide based on how many
   `IntentType` values actually exist and whether they fit on one line on a
   typical phone width without the overflow sheet).
3. `ActiveMeetupsSection` — **unchanged**, kept in place, still renders
   above the meetup list exactly as it does today (`activeMeetupsProvider` →
   `ListActiveMeetups`, unpaginated, client-side 30-minute lead-time window,
   `HAPPENING NOW` persistent card + `ACTIVE MEETUPS` list). Nothing in this
   section needs to change.
4. **New "Happening Soon" section** — a `SectionLabel('HAPPENING SOON')`
   followed by the paginated meetup list (C2's extracted widgets), calling
   `ListOpenMeetups` with the selected intent (or none, for "All") and
   `WithinDays: 7`. Each card shows the "hosted by you" / "requested" badge
   when `IsHostedByMe`/`MyRequestStatus` is set (data already present, per
   §B — likely already exists as a badge somewhere in the extracted
   `_MeetupCard`; confirm and reuse rather than adding a new one). Same
   guest-tier redaction/locked-card treatment as `matches_page.dart` had
   (`LockedCardHeader`, real location label visible, host name/photo/time
   blurred) — this must carry over unchanged, it's a security-relevant
   behavior (ADR-002 §6), not cosmetic.
5. `SafetyTipCard` — unchanged, kept.
6. **Remove `NetworkInsightsRow` ("Your Stats") entirely** — delete the
   widget file if nothing else references it (grep first).
7. Bottom fixed CTA block — **"FIND MATCHES" is removed entirely**
   (confirmed with Shashika: it's pointless once browsing is inline on this
   same page — nowhere left for it to take you). Only **"HOST YOUR OWN
   MEETUP"** remains, unchanged (trust-gate → `ScheduleFlowPage` or
   `HostingUnlockPage`). Since it's now the only button in that block,
   restyle it as the sole primary CTA rather than leaving it looking like
   half of a removed pair (e.g. it can take the full-width treatment the
   pair used to share, or move to wherever a single persistent bottom CTA
   reads best) — a layout call for whoever implements this, not something
   to leave looking like an accidental gap.

### C5. New shared pagination widget (fixes existing duplication, needed for C2+C4)

`core/widgets/paginated_meetup_list.dart` (or similar) — factor out the
`ScrollController` + 400px near-bottom trigger + `_hasMore`/`_loadingMore`
guard pattern that's currently hand-duplicated in `matches_page.dart` and
`my_meetups_page.dart` (per the existing code comment in the latter
admitting it's a copy, not a shared base). Add **pull-to-refresh**
(`RefreshIndicator` wrapping the list, re-fetching the first page) if it
doesn't already exist anywhere in this pattern today — check before
assuming; the "graceful scroll top and bottom" ask needs both directions
covered, not just infinite-scroll at the bottom. This widget backs: Home's
new Happening Soon list, and both Open-meetups sub-tabs on the new
`EventsPage`.

## §D — Tests

- Backend: `ListOpenMeetups` — new cases for `Intent: nil` (returns mixed
  intents) and `WithinDays` (excludes a meetup outside the window, includes
  one inside it), plus a case combining both. Confirm redaction and
  `IsHostedByMe`/`MyRequestStatus` are unaffected by the new filter (same
  code path, different WHERE clause — a quick regression check, not new
  logic to design).
- Frontend: `EventsPage` — default tab/sub-tab is My Meetings/Open; each of
  the four tab combinations renders the right filtered set; deep-link
  `initialTab` params still work post-rename. `HomePage` — "Happening Soon"
  renders with the selected intent and with "All"; guest-tier card in this
  new location still shows the locked treatment (this is the one most worth
  a dedicated regression test, since it's the same security property as
  ADR-002 §6, now rendered from a new call site). `LocationViewPage` — guest
  (level 0) tap shows the toast/redirect again; Level 1+ still opens
  unconditionally (control-run both directions, same discipline as the
  `linkedin_connected` fix from the last round).
- `PaginatedMeetupList`: one shared widget test covering infinite-scroll
  trigger and pull-to-refresh, run against both call sites' provider wiring.

## When done

Cite file:line for every claim, same bar as every prior round. In
particular: confirm `matches_page.dart` has zero remaining references before
it's deleted; confirm the new `WithinDays`/`Intent: nil` filter didn't touch
`redactForViewer` or the trust-gate functions at all (different concern,
should be a zero-line diff there); confirm "FIND MATCHES" and its
`onFindMatches` handler are fully removed, not just hidden, and that nothing
else still references them; confirm `flutter analyze`/`dart format
--set-exit-if-changed`/`flutter test` and the Go
`build`/`vet`/`golangci-lint`/`go test ./...` all pass.
