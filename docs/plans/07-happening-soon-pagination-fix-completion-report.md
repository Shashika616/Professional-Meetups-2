# Completion report — Home "Happening Soon" infinite-scroll fix

Scope: `docs/plans/happening-soon-pagination-fix-claude-code-prompt.md`,
working from `docs/plans/07-happening-soon-pagination-fix.md`. Only the four
files named in the prompt were touched, plus their tests.

The bug was mine, shipped in the Home/Events restructure, and the test I wrote
for it is precisely why it shipped — see "How this got through" below.

---

## §A — The bug, confirmed

`frontend/lib/features/home/home_page.dart` had a bare `ListView(` with no
controller, and `PaginatedMeetupList` attached its near-bottom listener to an
internal `ScrollController` that, on the shrink-wrapped path, was handed to no
scrollable at all (`controller: widget.shrinkWrap ? null : _scrollController`).

Nothing bridged the two, so `_maybeLoadNextPage` could never fire for Home's
browse list: capped at page one, with no error, no indicator, no crash.

## §B — The fix

**1. `home_page.dart`** — `HomePage` became a `ConsumerStatefulWidget` so it can
own a controller: declared at **:57**, attached to its own `ListView` at
**:164**, disposed in `dispose()`, passed down at **:183**.

**2. `happening_soon_section.dart`** — `outerScrollController` is a **required**
constructor parameter (**:61**, field at **:70**), forwarded at **:218**.
Required rather than optional deliberately: a null here is exactly the bug this
parameter exists to prevent, so the type system now refuses to reintroduce it.

**3. `paginated_meetup_list.dart`** — new optional `outerScrollController`
(**:51**, field **:103**) and a `_listeningController` getter (**:138-141**)
that returns the outer controller only when shrink-wrapped with one supplied,
and the internal one otherwise. `initState` listens on that (**:158**);
`_maybeLoadNextPage` reads its position (**:253**).

The non-shrink-wrapped path is **byte-identical in behaviour** — same internal
controller, same attachment, same threshold. `EventsPage`'s two cursor-
pagination tests pass unchanged.

**4. Disposal** — `dispose()` (**:220**) removes the listener from whichever
controller it attached to, then disposes **only** `_scrollController`. Removing
the listener is load-bearing rather than tidy on the outer path: that controller
belongs to Home and outlives this widget (Home rebuilds the section on every
intent-filter change), so a listener left behind would call into a disposed
`State`. `didUpdateWidget` (**:234-242**) re-points the listener if the caller
ever swaps controllers without remounting.

**5. Doc comment** — `happening_soon_section.dart:36-56` now describes what
actually bridges the two lists. The old text claimed "the parent owns
scrolling, and therefore owns infinite-scroll and pull-to-refresh too"; half
was true (pull-to-refresh really is Home's `RefreshIndicator`) and half was an
aspiration nothing implemented. The new comment says which half was which.

### A second, related gap found while testing

The first version of the fix still failed its own test. `ListView(children:)`
lays out **lazily**: the section is far down Home and is not mounted until
scrolled near, so *the scroll that reveals it is the one scroll its listener
cannot see*. Land at or near the bottom in one motion — a fling, a restored
scroll position, a short page — and pagination sits waiting for an event that
never comes.

Fixed with `_checkAfterLayout` (**:179**), a single post-frame near-bottom
check, run on mount (**:159**) and when the controller changes (**:242**).
Scoped to the outer-controller path only: doing it on the internal path would
make a non-shrink-wrapped list whose first page does not fill the viewport
immediately fetch page two, which is a behaviour change for `EventsPage`
rather than a fix.

`_maybeLoadNextPage` also gained a `hasClients` guard (**:253**) — the internal
controller is permanently client-less on the shrink-wrapped path, and any
controller is transiently so during teardown.

## §C — Error logging

Both sites now log the exception **type plus a sanitized message**, never the
raw object. `debugPrint` is not stripped from release builds, and while this
codebase's typed exceptions carry only user-safe messages, these two handlers
catch untyped failures too — a raw `PlatformException` from `google_sign_in` /
`sign_in_with_apple`, a geolocator plugin error, an HTTP client exception —
whose `toString()` can carry endpoint URLs, request echoes, or account
identifiers.

- `onboarding_flow.dart:184-210` — `_handleSignInError`, which covers all four
  sign-in paths including `guestSignup`. The stack trace is no longer printed
  either (it names internal paths and, for a plugin failure, the plugin's
  internals). `AuthException.message` is still included where present — it is
  safe by construction and is the same string the toast shows.
  `stackTrace` stays in the signature with a comment saying it is deliberately
  unlogged, so the next person does not add a `print` back to recover it.
- `happening_soon_section.dart` — the `updateLastKnownLocation` failure
  handler, same treatment.

---

## Proof, not reasoning

The plan asked for the fix to be proven by running it. It was, in both
directions.

**Forward** — five new tests drive the real trigger path and never touch
`loadNextPageForTest()`:

In `test/paginated_meetup_list_test.dart`:
- outer controller jumped to the bottom → `loadMore` fires with the right cursor;
- the **listener** path specifically: scroll partway to mount the list, assert
  it is mounted and nothing loaded, *then* scroll to the bottom — so only the
  listener can be responsible, not the post-frame check;
- a scroll that stays far from the bottom loads nothing (the threshold is a
  real check);
- unmounting the list leaves the outer controller usable (nothing disposes what
  it does not own).

In `test/happening_soon_section_test.dart` — the end-to-end case, mounting
`HomePage` at the **default** viewport (a tall one would leave Home with no
scroll extent and make the test vacuous) and dragging its own `ListView`:
- scrolling Home to the bottom fetches page two with the right cursor, intent,
  window and coordinates, and the new card appears;
- a filtered list keeps its intent when it pages;
- `hasMore: false` fetches nothing however far Home is scrolled.

**Control run** — with the fix disabled (`_listeningController` forced back to
the internal controller and `_checkAfterLayout` short-circuited), **4 of these
tests fail**:

```
test/happening_soon_section_test.dart: … scrolling Home to the bottom loads the next page …
test/happening_soon_section_test.dart: … the next page keeps the SELECTED intent …
test/paginated_meetup_list_test.dart:  … scrolling the OUTER list past the threshold …
test/paginated_meetup_list_test.dart:  … the LISTENER path works too …
```

Restoring the fix: `+41: All tests passed!` for those two files. The two
negative tests (far-from-bottom, `hasMore: false`) correctly pass in both
states — they would be the ones to catch an over-eager fix.

**Non-shrink-wrapped callers unaffected** — `test/events_page_test.dart` passes
unchanged, including both cursor-pagination tests ("the HOSTING tab requests a
second page via hosted_cursor…", "the REQUESTED tab … independently of the
hosted side").

## How this got through

The test that covered this before called `loadNextPageForTest()` — an escape
hatch I added to the widget and then tested *through*. It proved `loadMore`
reaches the service with the right arguments, which was true, and proved
nothing about whether anything ever calls it. Nothing did.

That test has been deleted, not adjusted. Its useful half (the arguments the
next page is fetched with) is now asserted inside the scroll-driven tests, so
the same coverage exists with no way to pass without the trigger working.

**`loadNextPageForTest` is deleted too**, along with the class doc that
justified making the `State` public "so a widget test can reach it without
synthesising a 400px scroll in a fake viewport". Synthesising the scroll turns
out to be a few lines, and it is the only version that can fail when the
wiring is wrong. Leaving the seam in place would leave the next person the
same shortcut that produced this bug.

## Gates

```
flutter analyze                        No issues found!
dart format --set-exit-if-changed      139 files (0 changed), exit 0
flutter test                           +355: All tests passed!
```

Backend untouched this round.
