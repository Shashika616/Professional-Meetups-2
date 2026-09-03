# Frontend plan — Request-management UI (ADR-020) + light theme toggle

Two unrelated slices, built together for convenience only (Shashika's instruction) — no shared code between them. Part 1 is ADR-020's frontend half (companion to `backend/cancellation-withdrawal-ratings-PLAN.md`); Part 2 is the light theme toggle, independent of everything else in this batch.

---

## Part 1 — Request-management UI + cancellation/withdrawal ratings

**What exists today, concretely**: `home_header.dart`'s `_MyMeetupsButton` is the sole entry point into `MyMeetupsPage`, which already has a `TabBar` with `HOSTING`/`REQUESTED` tabs and an `_OpenHistoryToggle` (Open vs. History, ADR-016) inside each. `_RequestManagementPage` (nested under HOSTING) already renders each request's status inline via `_MeetupListView`'s status-label switch (`REQUEST PENDING` / `YOU'RE IN` / rejected copy) in one combined scrolling list. `host_meetup_controls.dart` presumably already has the cancel action wired to `CancelMeetup` (verify before assuming) — check there for where to add the reason field, rather than building a new cancel entry point.

### Step 1 — Two visible entry points

- Replace `_MyMeetupsButton` in `home_header.dart` with two buttons/cards — "Your Meetings" and "Requested Meetups" — each navigating directly to `MyMeetupsPage` with its `TabController`'s initial index set to HOSTING or REQUESTED respectively (add an optional constructor parameter to `MyMeetupsPage` for the initial tab if it doesn't already accept one). Match existing header sizing/spacing conventions (`GradientButton`/`Glass`-based, not ad hoc).

### Step 2 — Three explicit request tabs

- Inside `_RequestManagementPage`, replace the single combined list with a nested `TabBar`/`TabBarView` — **Pending**, **Accepted**, **Rejected** — partitioning the same `ListMeetupRequests` result client-side by `status` (no new backend call). Each tab reuses the existing row widget, just filtered.
- Add a fourth implicit grouping for **withdrawn** requests — shown inside the Rejected tab (or a small "Withdrawn" section within it, host's call on exact placement) since both represent "no longer pending, not accepted" from the host's point of view. A withdrawn row shows the `withdrawal_note` if present and a "Rate" action once `ListRatableParticipants` includes them (Step 4).

### Step 3 — Cancel-with-reason

- Find the current cancel action (likely `host_meetup_controls.dart`, confirm before building) and add a required reason field — a simple text-entry dialog/bottom sheet before the `CancelMeetup` call goes out, blocking submission on an empty reason (mirrors the backend's own required-field rejection, but catch it client-side first for a faster, clearer UX).
- On success, show confirmation that accepted participants have been notified — no new screen needed, a snackbar/toast is enough (matches this app's existing lightweight-confirmation pattern, e.g. `toast.dart`).

### Step 4 — Withdraw-with-note, and rating both new cases

- Find the existing withdraw action (requester side, likely on `meetup_detail_page.dart` or `my_meetups_page.dart`'s REQUESTED tab) and add an optional note field before the `WithdrawRequest` call.
- `ListRatableParticipants`'s response now includes cancellation-triggered (host) and withdrawal-triggered (requester) entries alongside the existing happened-based ones (backend Step 5) — the existing `RatingPrompt` widget (`features/meetups/widgets/rating_prompt.dart`) should already work unmodified for these if it just iterates whatever `ListRatableParticipants` returns; if it currently assumes "only reachable after `SubmitMeetupFeedback`," that assumption needs removing since these two new cases are reachable without ever calling that RPC. Verify this explicitly, don't assume the existing widget generalizes for free.
- Show the new optional `context_note` field (backend Step 5) inline in the rating prompt when present, so the host has the withdrawal note in view while rating.

### Step 5 — Tests

- Widget test: tapping "Your Meetings" opens `MyMeetupsPage` on the HOSTING tab; "Requested Meetups" opens it on REQUESTED.
- Widget test: the three request tabs correctly partition a mixed-status fixture list.
- Widget test: cancel action is blocked with an empty reason.
- Widget test: rating prompt renders for a cancellation-triggered and a withdrawal-triggered entry, not just a happened-triggered one.
- `flutter analyze --fatal-infos`, `flutter test`, `dart format --set-exit-if-changed .` all clean.

---

## Part 2 — Light theme + toggle

**Real scope, checked before writing this plan, not assumed**: `AppPalette` (`core/theme/app_palette.dart`) is referenced 352 times across 49 files as `AppPalette.someColor` — all `static const Color` fields, no existing `Theme.of(context)`/`ThemeData` integration anywhere in this app. A mechanical find-replace of all 352 call sites is **not** the recommended approach here — it's a large, error-prone diff for what should be a contained change.

### Recommended approach — convert fields to brightness-aware getters, touch zero call sites

- Change `AppPalette`'s fields from `static const Color x = ...` to `static Color get x => _isLight ? _lightX : _darkX`, where `_isLight` is a private static bool (or reads a static holder synced from a Riverpod `ThemeModeNotifier`). Every existing `AppPalette.someColor` reference across all 49 files keeps working unmodified — this is the entire point of this approach, verify it holds before proceeding (spot-check a handful of the 49 files after the change compiles, don't just assume).
- Add a `themeModeProvider` (Riverpod `StateProvider<ThemeMode>` or similar, matching this app's existing Riverpod-only state-management convention — no other approach exists in this codebase, don't introduce one) persisted via `shared_preferences` (check `pubspec.yaml` for whether it's already a dependency before adding it).
- **Critical**: static getters alone don't trigger widget rebuilds. Wrap the app root (`main.dart`'s `MaterialApp` or just above it) in a `Consumer`/`ConsumerWidget` that watches `themeModeProvider` and forces a full rebuild of the tree beneath it on change (e.g., keying the root widget on the theme mode, or wrapping in something equivalent) — verify this actually works by testing a toggle and confirming every currently-visible screen's colors flip, not just the toggle's own immediate parent widget.
- Toggle location: Profile page (near where other account-level settings would live) is the natural place — check `profile_page.dart`'s existing settings-like rows for the right pattern to match, don't invent new chrome for a single toggle row.
- Default to dark (today's only theme) for existing users — don't default to system brightness, which would silently change the app's appearance for everyone with light-mode OS settings on first launch of this update.

### Light color values — a design decision, not fully specified here

Needs actual light-mode equivalents for every field in `AppPalette` (background/surface/card tones inverted from near-black to near-white, text colors inverted, semantic colors like `verified`/`danger`/`gold` re-checked for contrast against a light background, and — the trickiest one — `glassTint`/`glassBorder`, since this app's glassmorphism chrome (`Glass` widget, `BackdropFilter` blur + tinted border) reads very differently on a light background than the current dark one; this may need its own small round of visual iteration rather than a mechanical value-inversion). Flag this back to Shashika for a quick look once a first pass exists, rather than shipping unreviewed light-mode glass chrome.

### Tests

- Widget test: toggling theme mode updates a sampled widget's rendered color (confirms the full-rebuild mechanism actually works, not just that the provider's value changed).
- Widget test: default theme mode on fresh install is dark, not system-derived.
- `flutter analyze --fatal-infos`, `flutter test`, `dart format --set-exit-if-changed .` all clean.
