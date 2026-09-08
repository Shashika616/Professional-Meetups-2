# Claude Code prompt — fix dead infinite-scroll on Home's "Happening Soon" list

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
Found during a fresh vulnerability/issues sweep, not self-reported: a real
functional regression in the newest frontend feature. Small, well-scoped fix
— no design ambiguity.

## Read first

`docs/plans/07-happening-soon-pagination-fix.md` in full.

## The bug

`PaginatedMeetupList` (`frontend/lib/core/widgets/paginated_meetup_list.dart`)
only attaches its scroll listener when it's not shrink-wrapped
(`controller: widget.shrinkWrap ? null : _scrollController`). Home's
"Happening Soon" section (`happening_soon_section.dart`) is the only caller
using `shrinkWrap: true` — it's nested inside `home_page.dart`'s own outer
scrolling `ListView`. Nothing bridges that outer list's scroll position back
down to trigger the next page, despite a doc comment claiming the parent
handles it. **Net effect: Home's nearby-meetups list is stuck on page one,
silently, with no error and no indicator.**

## The fix

1. `home_page.dart` — add an explicit `ScrollController`, attach it to its
   own outer `ListView`, dispose it properly.
2. `HappeningSoonSection` — accept and forward that controller down as a new
   optional param (e.g. `outerScrollController`).
3. `PaginatedMeetupList` — when shrink-wrapped with an `outerScrollController`
   supplied, listen to *that* controller for `_maybeLoadNextPage` instead of
   creating/attaching an internal one that's never actually attached to
   anything scrollable. Leave the non-shrink-wrapped path (used by
   `EventsPage`'s Open-meetups sub-tabs) completely unchanged — this is
   additive.
4. Don't dispose a controller `PaginatedMeetupList` doesn't own.
5. Update `happening_soon_section.dart`'s doc comment to describe what
   actually bridges the two lists now, not the unwired aspiration it
   currently states.

## Also fix (same sweep, tiny, unrelated bug — bundle it, don't skip it)

`onboarding_flow.dart`'s `_handleSignInError` (covers every sign-in path
including `guestSignup`) and `happening_soon_section.dart`'s location-fetch
error handler both `debugPrint` the raw caught error object — not stripped
in release builds, and a non-typed exception (a raw `PlatformException` from
`google_sign_in`/`sign_in_with_apple`, an HTTP client error) could print more
than intended. Change both to log `error.runtimeType` + a sanitized message,
not the raw object. Small, mechanical.

## Tests

See plan doc's Tests section. The important one: drive the OUTER scroll
controller in the test (not the existing `loadNextPageForTest()` escape
hatch) to prove the actual production trigger path works, not just that the
underlying load function works in isolation — that distinction is exactly
what let this bug ship in the first place. Confirm `EventsPage`'s existing
pagination tests still pass unchanged.

## Bar for "done"

File:line, and prove the fix by a test that drives the real scroll path, not
by reasoning about the code. Confirm `flutter analyze`/`dart format
--set-exit-if-changed`/`flutter test` all pass. Don't touch anything outside
`paginated_meetup_list.dart`, `happening_soon_section.dart`,
`home_page.dart`, and `onboarding_flow.dart`'s error-logging line.
