# Frontend PLAN — Meetup Time Windows, Host-Initiated Closing, Feedback Popup, Rating Confirmation, GradientButton Fix

Implements ADR-016. Pairs with `backend/meetup-lifecycle-PLAN.md` — read both.

## Step 1 — Fix `GradientButton`'s overflow bug (shared widget, fix once)

`core/widgets/gradient_button.dart`'s inner `Row` (around line 102-119): the `Text(widget.label, ...)` has no overflow handling, so a bold, letter-spaced label can exceed its available width when the button sits in a constrained context (e.g. two `GradientButton`s side-by-side in an `Expanded` row) — this is what produced the reported `RenderFlex overflowed by 16 pixels` banner on the "IT HAPPENED"/"DIDN'T HAPPEN" row. Fix at the widget level, not the call site:

```dart
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  mainAxisSize: MainAxisSize.min,
  children: [
    if (widget.icon != null) ...[
      Icon(widget.icon, size: 20, color: AppPalette.onyx),
      const SizedBox(width: 12),
    ],
    Flexible(
      child: Text(
        widget.label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppPalette.onyx,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
          fontSize: 15,
        ),
      ),
    ),
  ],
),
```

Add a widget test that pumps two `GradientButton`s with long labels ("IT HAPPENED" / "DIDN'T HAPPEN") into a narrow `Row` (constrain the test's surface size to something iPhone-SE-class, ~375 logical px) and asserts `tester.takeException()` is null — a real regression test for the exact bug in the screenshots, not just a visual eyeball check.

## Step 2 — Time-range picker in the schedule flow

`features/meetups/schedule_flow.dart`'s Timing step currently branches on "today" (no time entry) vs. "schedule for later" (a single date+time picker). Replace both with one consistent step: a date picker (defaulting to today) plus **two** time pickers, "From" and "To" — client-side validation that `to > from` before allowing Continue (the real check is server-side per the backend plan, this is just fast feedback). Feed `windowStart`/`windowEnd` (both `DateTime`, combining the picked date with each time) into `MeetupService.createMeetup`.

## Step 3 — Display the time range on every meetup card

`core/models/meetup.dart`: replace `scheduledFor` with `windowStart`/`windowEnd` (both non-nullable `DateTime` now) and add `closedAt` (nullable). Add a small formatting helper (e.g. `meetup.formattedWindow` getter or a top-level function) producing "Today, 3:00–5:00 PM" / "Aug 22, 6:00–8:00 PM" style output — reuse `intl`'s `DateFormat` if already a dependency (check `pubspec.yaml` before adding a new one). Wire into the three card locations already wired for rating/trust badges: `matches_page.dart` (browse card), `my_meetups_page.dart` (request + hosted cards), `meetup_detail_page.dart`'s summary section.

## Step 4 — Host "Close Meetup" action + Open/History tabs

`meetup_detail_page.dart`: for the host's own meetup, once `DateTime.now().isAfter(meetup.windowStart)` and status is `open`/`full`, show a "Close Meetup" button (a destructive-ish but not alarming style — this isn't cancellation, it's normal completion) that calls the new `MeetupService.closeMeetup(meetupId)` and refreshes. Show a confirming toast, not a blocking dialog (closing is reversible in the sense that it's just a status/history move, not data loss — no need for the same weight as the rating confirmation in Step 6).

`my_meetups_page.dart`: split into two views — a `TabBar`/segmented control, **Open** (status `open`/`full`) and **History** (status `completed`/`cancelled`), reusing the existing card widgets for both, just filtered differently. Confirm with the actual current widget structure before restructuring — it may already have host-vs-requester tabs, in which case this is a second, orthogonal axis (open/history × host/requester), not a replacement.

## Step 5 — Feedback popup: add an optional note

`meetup_detail_page.dart`'s `_submitFeedback` (called from `_SafetyGateSection`'s "How did it go?" buttons): after the happened/didn't-happen tap, show a second, dismissible bottom sheet or dialog with a single optional multi-line text field ("Add a note (optional)") and Save/Skip actions. Either action proceeds to call `submitMeetupFeedback` with `notes` set to the entered text (or null if skipped) — don't block on it, the field is explicitly optional per the request. No new timestamp handling needed on the frontend — `meetup_feedback.submitted_at` is already set server-side at insert time (unchanged, already correct).

## Step 6 — Rating confirmation dialog

`features/meetups/widgets/rating_prompt.dart`: before calling `MeetupService.submitRating`, show a confirm dialog ("Rate {name} {n} stars? You won't be able to change this later.") with Cancel/Confirm. Only call the API on Confirm. This one *should* block (unlike Step 4's close action) — ratings are immutable per ADR-015, so this is the last chance to catch a mis-tap.

## Tests

- The `GradientButton` overflow regression test (Step 1).
- Schedule flow: from/to validation (reject `to <= from`), both today and later paths now go through the same widget.
- Card formatting: a few representative `formattedWindow` cases (today, a future date, spanning midnight if that's allowed — decide whether it should be during Step 2, flagging here since the plan doesn't resolve it: does a window need to stay within one calendar day, or can "10 PM–1 AM" be valid? Recommend allowing it — nothing in ADR-016 requires same-day, and forcing same-day would make late-evening meetups awkward to schedule).
- Feedback popup: optional note saves correctly, and skipping doesn't block progression.
- Rating confirmation: Cancel doesn't call the API, Confirm does, exactly once.
- Host close: button only appears for the host, only after `windowStart`, hidden/disabled otherwise.

## Self-review checklist

- [ ] `GradientButton` fix verified against the actual reported screenshots' scenario (two buttons, narrow device) via the new widget test, not just code inspection.
- [ ] Every screen showing a meetup card was actually found and updated — grep for the old `scheduledFor` field name across `frontend/lib` to make sure nothing still references the removed field.
- [ ] Close action correctly hidden for non-hosts and before the window starts — checked in a widget test, not just assumed from the `if` condition.
- [ ] Rating confirmation actually blocks the API call on Cancel — a real test, not just a visual dialog with no wiring.

## Addendum (2026-08-20): host controls are stranded in `MyMeetupsPage`, and there's no visible status badge

Found by Shashika using the actual built app, confirmed by reading the current code: `formattedWindow`, the Open/History toggle, and `CLOSE MEETUP` (in `meetup_detail_page.dart`) are already built and match the plan above — but there's a real navigation gap and two missing pieces of UI.

**The gap**: `MyMeetupsPage`'s "HOSTING" tab pushes `_RequestManagementPage` (a separate, narrower widget — Accept/Reject only), while its "REQUESTED" tab and every other entry point (Home, Matches) push the full `MeetupDetailPage`, which is where `CLOSE MEETUP` actually lives. A host managing meetups the normal way — tapping the calendar icon → Hosting — lands on the one screen that *can't* close or cancel anything. With one meetup this is easy to miss; with ten, it's a real usability problem, which is exactly how this was found.

**`cancelMeetup` exists in `MeetupService`/`HttpMeetupService` already (`meetup_service.dart:92`, `http_meetup_service.dart:221`) but has no UI anywhere** — no button calls it. Backend route already exists too (`POST /v1/meetups/{id}/cancel`).

Fix, three parts:

1. **Extract a shared `HostMeetupControls` widget** (new, `features/meetups/widgets/host_meetup_controls.dart`) taking a `Meetup` and an `onChanged(Meetup)` callback, rendering whichever of CANCEL/CLOSE actually apply given the meetup's current status and window (same conditions `meetup_detail_page.dart` already computes at lines 367-370) — one implementation, not two. Use it from **both** `MeetupDetailPage` (replacing the inline `OutlinedButton` at line 372) and `_RequestManagementPage` (new).
2. **Add `CANCEL MEETUP`** to that shared widget: a destructive-styled button (red text/border, distinct from `CLOSE MEETUP`'s neutral `OutlinedButton` styling — these should not look alike, cancelling is consequential to the people who requested to join) — behind a confirmation dialog ("Cancel this meetup? Everyone who requested to join will be notified." Cancel/Confirm) before calling `MeetupService.cancelMeetup`. Only shown while status is `open`/`full` (not already cancelled/completed).
3. **Add a confirmation dialog to `CLOSE MEETUP` too**, upgrading it from today's direct call-on-tap, for consistency with Cancel and with the rating-confirmation pattern elsewhere in this same plan ("Mark this meetup as done?" Cancel/Confirm) — lighter-weight wording than Cancel's, since it's a lower-stakes, more reversible action, but still a deliberate tap rather than none.

**Status badge, everywhere a meetup card renders**: new `MeetupStatusBadge(status)` widget (`core/widgets/`) — small colored label, not just implied by other text:

| Status | Label | Color |
|---|---|---|
| `open` | OPEN | `AppPalette.verified` (or existing "available" green) |
| `full` | FULL | `AppPalette.candyBlue` |
| `cancelled` | CANCELLED | `AppPalette.danger` |
| `completed` | COMPLETED | `AppPalette.textSecondary` |

Wire into every card, not just one: `MyMeetupsPage`'s `_MeetupListView` (both Hosting and Requested tabs — today's `_statusRow` only shows accepted-count or request-status, never the meetup's own lifecycle status), `MeetupDetailPage`'s summary card, and grep for every other place a `Meetup` renders as a card (`matches_page.dart`'s browse card, Home's "YOUR NEXT MEETUP" card — confirm both before assuming just these two) to make sure none are missed. This badge is additive — it sits alongside the existing accepted-count/request-status text, doesn't replace it.

### Verification, explicitly requested — actually walk these flows, not just implement

- Tap the calendar icon → Hosting tab → tap a hosted meetup → confirm CANCEL and CLOSE (whichever applies) are both visible and functional from this exact screen, not just from `MeetupDetailPage`.
- Confirm cancelling notifies/updates correctly for a meetup with pending and/or accepted requests (check what the existing backend `CancelMeetup` handler already does here before assuming — it may already be built and just never wired to any button).
- Confirm the status badge shows correctly for all four states on real data (create one of each in a local run if that's the fastest way to check, rather than reasoning about it in the abstract).
- Confirm both confirmation dialogs (Cancel, Close) actually block the API call on "Cancel"/dismiss — the same class of bug as an unwired confirm dialog that looks right but does nothing.
- Re-run the `GradientButton` overflow check (Step 1) against these new buttons too, since `HostMeetupControls` introduces at least one more place two buttons could sit side-by-side on a narrow screen.

## Related

ADR-016 · ADR-015 · `backend/meetup-lifecycle-PLAN.md` · `frontend/meetup-scheduling-PLAN.md` (the slice this evolves)
