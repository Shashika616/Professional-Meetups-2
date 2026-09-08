# Plan — fix dead infinite-scroll on Home's "Happening Soon" list

Found during a general vulnerability/issues sweep (not self-reported). Small,
well-scoped, single bug — no design ambiguity, no ADR needed.

## §A — The bug

`frontend/lib/core/widgets/paginated_meetup_list.dart:199`:
```dart
controller: widget.shrinkWrap ? null : _scrollController,
```
`PaginatedMeetupList` only listens for scroll position via its own
`_scrollController`, and only attaches that controller when NOT
shrink-wrapped. `HappeningSoonSection` (`frontend/lib/features/home/widgets/
happening_soon_section.dart:183`) is the only caller that passes
`shrinkWrap: true` (it's nested inside `home_page.dart`'s own outer
`ListView`, which is the thing that actually scrolls). Its doc comment
(lines 37-40) claims "the parent owns scrolling, and therefore owns
infinite-scroll and pull-to-refresh too" — but `home_page.dart` has no
`ScrollController`, no `NotificationListener<ScrollNotification>`, nothing
that bridges its own scroll position back down to trigger
`HappeningSoonSection`'s next page. Confirmed directly: grepped
`home_page.dart` for any scroll-bridging construct — none exists.

**Effect**: `_maybeLoadNextPage` never fires for this list. A user can only
ever see the first page of nearby meetups on Home; scrolling further does
nothing, with no error, no indicator, no crash — it just silently stops
growing. Since the old Matches page (which had working infinite scroll) is
gone, this is now the only inline browse surface on Home, so this caps real
browsing at one page's worth of results.

## §B — The fix

`PaginatedMeetupList` needs to listen to whichever `ScrollController`
actually scrolls when it's shrink-wrapped — not create and attach a
controller nobody drives. Concretely:

1. `home_page.dart` gets an explicit `ScrollController`, attached to its own
   outer `ListView` (currently implicit/default) — `disposed` in its State's
   `dispose()`, same as any other controller this codebase already owns.
2. `HappeningSoonSection` accepts and forwards that controller down to
   `PaginatedMeetupList` as a new, optional constructor parameter (e.g.
   `outerScrollController`).
3. `PaginatedMeetupList`: when `shrinkWrap` is true and an
   `outerScrollController` is supplied, add `_maybeLoadNextPage` as a
   listener on *that* controller instead of creating/attaching its own
   internal one (a shrink-wrapped, `NeverScrollableScrollPhysics` inner list
   never scrolls itself, so its own `ScrollController.position` would never
   be meaningful anyway — the outer list's position is what needs watching).
   Keep the existing internal-controller path unchanged for every
   non-shrink-wrapped caller (`EventsPage`'s Open-meetups sub-tabs) — this is
   additive, not a rewrite of the working case.
4. Dispose correctly: `PaginatedMeetupList` must not dispose a controller it
   doesn't own (the outer one belongs to `home_page.dart`) — only dispose
   `_scrollController` when it actually created and attached it.
5. Fix or remove `happening_soon_section.dart:37-40`'s doc comment once this
   is wired — it should describe what actually bridges the two, not restate
   the aspiration that turned out unwired.

## §C — Small, related fix (same sweep, tiny)

`onboarding_flow.dart`'s `_handleSignInError` (used by every sign-in path
including the new `guestSignup`) and `happening_soon_section.dart`'s
location-fetch failure handler both `debugPrint` the raw caught error object
directly. `debugPrint` is not stripped from release builds. Today's
`AuthException`/`MeetupException` types only carry sanitized messages, but a
non-typed exception (e.g. a raw `PlatformException` from `google_sign_in`/
`sign_in_with_apple`, or an HTTP client exception) could carry more than
intended in its native `toString()`. Change both sites to log
`error.runtimeType` plus a sanitized message rather than the raw object —
small, mechanical, no behavior change for the typed-exception case that
already works correctly.

## Tests

- Widget test: a `PaginatedMeetupList` in shrink-wrap mode with an
  `outerScrollController` supplied actually calls `loadMore` when that
  controller's position crosses the near-bottom threshold — drive the outer
  controller directly (via a wrapping scrollable in the test harness) rather
  than the existing `loadNextPageForTest()` escape hatch, since the whole
  point is proving the production trigger path works, not the function it
  calls.
- Regression test confirming the existing non-shrink-wrapped callers
  (`EventsPage`'s lists) are unaffected — same test-suite pattern already
  used for `PaginatedMeetupList`, just confirm nothing regressed.

## When done

Cite file:line. Confirm by manual/test-driven proof (not just code reading)
that scrolling Home's outer list past the near-bottom threshold actually
triggers `HappeningSoonSection`'s next page — this is the exact kind of
claim that must be checked by running it, per this codebase's own standing
discipline, not asserted from inspection. Confirm the non-shrink-wrapped
callers still pass their existing tests unchanged. `flutter analyze`/
`dart format --set-exit-if-changed`/`flutter test` all clean.
