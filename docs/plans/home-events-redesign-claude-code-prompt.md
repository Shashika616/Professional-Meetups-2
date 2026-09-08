# Claude Code prompt — Home/Events IA restructure + hardening carryover

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
The guest-login/trust-level slice (ADR-002) is built and independently
verified. This prompt covers two things shipped together: two security
follow-ups from that review that were never actioned, and a UI/IA
restructure requested directly by Shashika. No other phase changes.

## Read first

`docs/plans/05-home-events-redesign.md` in full — this prompt summarizes it,
that document has the real detail, file:line citations, and the reasoning
for every call. Don't work from this prompt alone.

## §A — Security follow-ups (small, do first)

1. `LocationViewPage.open` currently opens unconditionally for every viewer,
   including guests — sends exact coordinates and the interactive map to
   Level 0 (zero-verification) accounts. Restore a gate: `viewerTrustLevel
   < 1` shows the toast + `VerificationChecklistPage` redirect (same pattern
   as every other locked action); Level 1+ is unaffected. The location
   *label* on cards stays visible to guests — only this map view is gated.
2. `GuestSignup` has no rate limit beyond the generic 20/min-per-IP shared by
   every route. Add a dedicated, tighter limit (a handful per IP per day) —
   follow whatever pattern `middleware/ratelimit.go` already uses for other
   sensitive routes (email-keyed/target-keyed limiters exist there).
3. `schedule_flow.dart`'s locked-intent tap always redirects to
   `VerificationChecklistPage` — when the failed gate is the host-side one,
   it should redirect to `HostingUnlockPage` instead, matching
   `home_page.dart`'s existing correct behavior.

## §B — Backend: one new optional filter on `ListOpenMeetups`, no new RPC

Add `Intent *Intent` (nil = all intents) and `WithinDays int32` (0 =
unrestricted, >0 caps `window_start` to that many days out) to
`ListOpenMeetupsRequest`. Both default to today's exact behavior when unset
— every existing caller is unaffected. This is the only backend change
needed; redaction, trust gating, pagination, and the existing
`IsHostedByMe`/`MyRequestStatus` role fields are untouched and already
sufficient for the frontend work below.

## §C — Frontend restructure

- **Bottom nav**: "Matches" tab → "Events" tab, now routing to a renamed
  `EventsPage` (was `MyMeetupsPage`).
- **`matches_page.dart` is dissolved**: extract its `_MeetupCard`,
  `LockedCardHeader`, intent-chip filter row, and cursor-pagination logic
  into shared widgets (this also fixes the existing hand-duplicated
  pagination logic between this file and `my_meetups_page.dart` — factor
  both into one `PaginatedMeetupList`-style widget). Delete the file once
  Home (below) uses the extracted pieces — grep for remaining references
  first.
- **`my_meetups_page.dart` → `events_page.dart`**: rename
  `MyMeetupsPage`→`EventsPage`. Relabel tabs "HOSTING"/"REQUESTED" →
  **"My Meetings"/"Requested Meetings"**. Turn the existing client-side
  OPEN/HISTORY toggle buttons into real second-level tabs, **"Open
  meetups"/"History"** — same underlying filter logic, just real
  `TabBar`/`TabBarView` instead of custom toggle buttons. Data layer,
  `_RequestManagementPage`, and every navigation target are unchanged.
  Default: My Meetings → Open meetups.
- **`home_page.dart` restructure**, top to bottom: header (drop the "Your
  Meetings"/"Requested Meetups" chip buttons — that's now the Events tab);
  a compact single-row horizontal intent-chip filter with a new **"All"**
  option (maps to `Intent: nil`) replacing the current grid, locked intents
  still shown locked; `ActiveMeetupsSection` unchanged, still above
  everything else; a new **"Happening Soon"** section — the extracted
  paginated meetup list, called with the selected intent (or none) and
  `WithinDays: 7`, showing hosted-by-you/requested badges from the data
  that's already on every `Meetup`; keep `SafetyTipCard`; **delete
  `NetworkInsightsRow` ("Your Stats") entirely**; bottom CTA block **drops
  "FIND MATCHES" entirely** (confirmed with Shashika — pointless once
  browsing is inline on this page, there's nowhere left for it to navigate
  to). Only "HOST YOUR OWN MEETUP" remains, unchanged in behavior — restyle
  it as the sole primary CTA (e.g. full-width) rather than leaving a gap
  where its sibling button used to be.
- The guest-tier locked-card treatment (blurred host name/photo/time,
  visible location label) must carry over unchanged to the new Happening
  Soon list — this is a security property (ADR-002 §6), not styling; verify
  it explicitly, don't just assume it survives the widget move.
- Add pull-to-refresh to the new shared paginated-list widget if it isn't
  already part of the existing pattern — check first.
- Style direction: compact, native-feeling chips and real tabs — reference
  how established apps (LinkedIn, Meetup, Eventbrite) present a horizontal
  intent/category filter row and a two-level tab structure. Avoid heavy
  gradients/glow/oversized cards.

## §D — Tests

See `docs/plans/05-home-events-redesign.md` §D for the full list. Priority:
the guest-tier redaction regression test on the new Happening Soon list, and
`ListOpenMeetups`'s new `Intent: nil`/`WithinDays` cases confirming
redaction and trust-gate code paths are untouched.

## Bar for "done"

Same as every prior round: file:line citations, not assertions. Specifically
confirm zero references to `MatchesPage`/`matches_page.dart` remain before
it's deleted, confirm the new backend filter didn't touch
`redactForViewer`/`requiredTrustLevelTo*` at all, confirm "FIND MATCHES" and
its `onFindMatches` handler are fully removed (not just hidden) with nothing
left referencing them, and confirm `flutter analyze` + `dart format
--set-exit-if-changed` + `flutter test` + Go `build`/`vet`/`golangci-lint`/
`go test ./...` all pass. Don't touch billing or anything outside §A–C.
