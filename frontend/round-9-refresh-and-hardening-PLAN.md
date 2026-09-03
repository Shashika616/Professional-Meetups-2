# Frontend plan — Round 9: real active-meetup refetching, push-notification scaffolding (no-op, Firebase deferred), IntentPickerSheet fix

See `docs/04-decisions/adr-030-active-meetup-refresh-fix-and-push-notification-scaffolding.md` and `docs/00-project/action-tracker.md` § 4b-22 for full context. **Do not add `firebase_core`/`firebase_messaging` as dependencies in this round** — no Firebase project exists yet (confirmed directly with Shashika), this round only builds the swappable scaffolding a real implementation slots into later.

## Fix 1 — Real refetching for the active-meetups list (this is the actual user-visible fix for the reported bug)

**Do not make the existing 30s `Timer.periodic` refetch from the network.** This was originally scoped to also poll periodically, reversed on cost grounds: real periodic refetching means every concurrent user on this screen generates a backend request/DB query every interval regardless of whether anything changed — a cost that scales with usage for what's usually a no-op check, and something that would need to be torn back out the moment real push notifications exist anyway. Leave `Timer.periodic`'s existing behavior exactly as it is today (recomputing a countdown/eligibility flag from already-fetched data, `setState(() {})` only, no network call) — do not touch it as part of this round.

Add two one-shot, event-triggered (not recurring) refetch paths instead:
- **Pull-to-refresh** on the section/screen containing the active-meetups list — check `matches_page.dart`'s browse list first for the `RefreshIndicator` pattern already established in this codebase, reuse it rather than inventing a new one.
- **App-resume refetch**: add a `WidgetsBindingObserver` (or reuse one if `home_page.dart`/`app_shell.dart` already has one for something else — check first) that invalidates `activeMeetupsProvider` on `AppLifecycleState.resumed`. This fires once per foreground transition, not repeatedly while foregrounded — that distinction matters, don't implement it in a way that ends up polling on a timer under the hood.

**Reconcile the persistent-card/list inconsistency**: `active_meetups_section.dart`'s `_PersistentMeetupCard` does its own independent client-side `DateTime.now().isAfter(meetup.windowEnd!)` check to swap to a rating prompt, while the plain active-meetups row list below it keeps showing the same meetup via its last-fetched (potentially stale) `status` badge. Once real refetching exists (above), confirm both are rebuilt from the same fresh data after any refetch — if there's a structural reason they could still disagree even with fresh data (e.g. one reads from a different provider/cache than the other), flag it and fix it; don't just paper over it with faster polling.

## Fix 2 — `PushNotificationService` scaffolding (no-op today)

New interface, `lib/core/services/push_notification_service.dart` (or wherever this codebase's other service interfaces live — `AuthService`/`MeetupService`'s location), mirroring their existing shape:

```dart
abstract interface class PushNotificationService {
  Future<void> initialize();
  Future<String?> currentToken();
  Stream<PushMessage> get messages;
}

class PushMessage {
  final String type; // e.g. "meetup_closed"
  final String? meetupId;
  final String title;
  final String body;
  const PushMessage({required this.type, this.meetupId, required this.title, required this.body});
}
```

`NoOpPushNotificationService implements PushNotificationService`: `initialize()` no-ops, `currentToken()` returns `null`, `messages` is a stream that never emits (e.g. backed by a `StreamController` that's never fed, or `const Stream.empty()`). Wire it into `app_providers.dart` the same way other services are wired (a `pushNotificationServiceProvider`, bound to `NoOpPushNotificationService` for now — leave a clear comment for the future swap, matching how `authServiceProvider`/`meetupServiceProvider`'s doc comments already describe their own real-vs-mock history).

Wire the (currently inert) call sites:
- On login/session-restore (wherever `authSessionProvider` establishes a session — check the existing pattern), call `pushNotificationService.currentToken()`, and if non-null, call the existing (already-implemented, currently-dead) `MeetupService.registerDeviceToken`. Today this never fires since the no-op always returns `null` — that's expected, the plumbing is what matters.
- Subscribe to `pushNotificationService.messages` somewhere appropriate (app-level, e.g. in `AppShell` or wherever a long-lived listener makes sense in this codebase's existing patterns) and, on a `type == 'meetup_closed'` message, invalidate `activeMeetupsProvider`/`myMeetupsProvider`. Never fires today, ready for later.

## Fix 3 — `IntentPickerSheet` stale trust level

`intent_grid.dart` calls `IntentPickerSheet.show(context, trustLevel)`, and the sheet stores that as a plain `final int trustLevel` field instead of watching `authSessionProvider` live like the other 6 redirect sites do. Change it to read the trust level live inside the sheet's own `build` (via `ref.watch`, consistent with the other 6 sites), so a user who completes verification while the sheet happens to still be mounted sees it reflect their new trust level immediately rather than requiring the sheet to be closed and reopened.

## Tests

- A regression test confirming `Timer.periodic`'s existing behavior is genuinely unchanged — it still only recomputes local state (`setState`) and does NOT trigger a network call/provider invalidation. This is worth asserting explicitly given the fix's own history (periodic refetching was considered and deliberately rejected) — a future pass shouldn't accidentally reintroduce it without that being a deliberate, visible choice.
- A pull-to-refresh test (drag-to-refresh triggers a refetch) if a `RefreshIndicator` is added.
- An app-resume test (simulate `AppLifecycleState.resumed`, confirm invalidation) — check if this codebase's test harness already has a pattern for simulating lifecycle state changes; if not, a straightforward one is fine.
- `NoOpPushNotificationService` unit tests: `currentToken()` returns null, `messages` never emits.
- A test confirming the login/session-restore path calls `currentToken()` but does NOT call `registerDeviceToken` when it returns null (i.e. confirm the "today this is inert" behavior is genuinely inert, not accidentally still trying to register a null token).
- A test for `IntentPickerSheet`'s fixed: verify it reflects an updated trust level while still mounted (open sheet at level 0, bump the underlying session state, confirm the sheet's own gate check now sees the new level without being reopened).

## Do not

- Do not add `firebase_core`/`firebase_messaging` to `pubspec.yaml` this round.
- Do not make `NoOpPushNotificationService`'s `messages` stream throw or the app crash anywhere from calling into a null-returning `currentToken()` — every call site must handle the no-op case gracefully, since that's the real, expected state until Firebase is set up.
- Do not change the lifecycle poller or `notifyMeetupClosed` on the backend — confirmed correct, out of scope.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line.
