import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/legacy.dart' show StateProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/http_auth_service.dart';
import 'package:professional_connections_platform/core/services/http_meetup_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/services/firebase_push_notification_service.dart';
import 'package:professional_connections_platform/core/services/http_subscription_service.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/services/token_refresher.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

final sessionStorageProvider = Provider<SecureSessionStorage>(
  (ref) => SecureSessionStorage(),
);

// TokenRefresher needs HttpAuthService's own refreshSession() method, and
// HttpAuthService needs TokenRefresher.getValidAccessToken as its
// getAccessToken callback — a naive circular dependency if built as two
// independent providers. Both are constructed once here, in a single
// provider body (the `late final service` trick), and authServiceProvider/
// tokenRefresherProvider/meetupServiceProvider below just proxy into this
// shared bundle — never authSessionProvider, which this bundle must stay
// independent of (see the note on _AuthBundle itself).
// HttpMeetupService reuses the same TokenRefresher instance rather than
// constructing a second one (frontend/meetup-scheduling-PLAN.md Step 4) —
// there is exactly one proactive-refresh mechanism for the app's lifetime,
// not one per service.
final _authBundleProvider = Provider<_AuthBundle>((ref) {
  final storage = ref.read(sessionStorageProvider);
  late final HttpAuthService authService;
  final refresher = TokenRefresher(
    storage: storage,
    refreshSession: (token) => authService.refreshSession(token),
  );
  authService = HttpAuthService(getAccessToken: refresher.getValidAccessToken);
  final meetupService = HttpMeetupService(
    getAccessToken: refresher.getValidAccessToken,
  );
  final subscriptionService = HttpSubscriptionService(
    getAccessToken: refresher.getValidAccessToken,
  );
  return _AuthBundle(
    service: authService,
    refresher: refresher,
    meetupService: meetupService,
    subscriptionService: subscriptionService,
  );
});

// Never reads authSessionProvider — HttpAuthService's verification/profile
// calls are invoked from inside AuthSessionNotifier itself (e.g. build()'s
// own getValidSession() call below), and ref.read(authSessionProvider) from
// within that provider's own build() would be a self-referential read on a
// provider that's still resolving. TokenRefresher-backed secure storage is
// the actual source of truth for "what's the current token" either way —
// AuthSessionNotifier keeps it in sync via saveSession()/completeVerification
// on every state change.
final authServiceProvider = Provider<AuthService>(
  (ref) => ref.read(_authBundleProvider).service,
);

final tokenRefresherProvider = Provider<TokenRefresher>(
  (ref) => ref.read(_authBundleProvider).refresher,
);

final meetupServiceProvider = Provider<MeetupService>(
  (ref) => ref.read(_authBundleProvider).meetupService,
);

/// Real as of ADR-031 Slice B — [HttpSubscriptionService], same
/// bundle-proxy wiring as [meetupServiceProvider].
final subscriptionServiceProvider = Provider<SubscriptionService>(
  (ref) => ref.read(_authBundleProvider).subscriptionService,
);

/// The caller's current subscription status, always backend-sourced (never
/// derived from local purchase-stream state — see
/// `subscription_service.dart`'s doc comment). `autoDispose` + `keepAlive`
/// isn't used here: callers that need a fresh read after a purchase call
/// `ref.invalidate(subscriptionStatusProvider)` explicitly (mirrors how
/// other on-demand backend reads in this app are refreshed).
final subscriptionStatusProvider = FutureProvider<SubscriptionStatus>(
  (ref) => ref.read(subscriptionServiceProvider).currentStatus(),
);

/// Real as of ADR-030 round-10 (was [NoOpPushNotificationService] under
/// round-9's scaffolding, the same way [authServiceProvider]/
/// [meetupServiceProvider] used to be bound to `Mock*` implementations
/// before their real backends existed) — the real
/// `professional-meetups-976d2` Firebase project now exists, with real
/// `google-services.json`/`GoogleService-Info.plist`/`firebase_options.dart`
/// in place. `onTokenRefreshed` re-runs the exact same
/// `registerDeviceToken` call `AuthSessionNotifier` already makes at
/// session-restore/sign-in (see that class's own
/// `_registerPushTokenIfAvailable`) — FCM rotates tokens periodically for
/// a live session, which round-9's one-shot registration never covered.
/// Every call site (`AuthSessionNotifier`'s token-registration call,
/// `AppShell`'s message listener) is written against the
/// [PushNotificationService] interface, not this implementation, so this
/// binding swap was the only change either needed.
final pushNotificationServiceProvider = Provider<PushNotificationService>((
  ref,
) {
  return FirebasePushNotificationService(
    onTokenRefreshed: (token) {
      unawaited(ref.read(meetupServiceProvider).registerDeviceToken(token));
    },
  );
});

class _AuthBundle {
  const _AuthBundle({
    required this.service,
    required this.refresher,
    required this.meetupService,
    required this.subscriptionService,
  });

  final HttpAuthService service;
  final TokenRefresher refresher;
  final HttpMeetupService meetupService;
  final HttpSubscriptionService subscriptionService;
}

/// Home's intent filter for the "Happening Soon" list. NULL MEANS "ALL
/// INTENTS", which is both the default and the new option the backend's
/// nullable intent filter exists for.
///
/// Replaces the old non-nullable `selectedIntentProvider`. That one defaulted
/// to coffee because every surface reading it needed exactly one intent to
/// browse; the browse page is now inline on Home, where "show me everything
/// happening near me this week" is the more useful opening state and the one
/// a first-time user is best served by.
final homeIntentFilterProvider = StateProvider<IntentType?>((ref) => null);

/// AppShell's bottom-nav tab index — a provider rather than AppShell's own
/// local `setState` so a page can switch tabs too, not just the bottom nav
/// bar itself.
final currentTabIndexProvider = StateProvider<int>((ref) => 0);

/// Open meetups for the currently-selected intent, within 40km of the
/// caller's last on-demand location read (ADR-021 §2) — replaces the mock
/// matchesProvider (ADR-013 § 7). `.autoDispose` so a stale page isn't kept
/// alive after the user navigates away from the browse tab. The family key
/// is a record (not just [IntentType]) because the viewer coordinate is
/// itself part of what's being asked for — HomePage's "Happening Soon"
/// section only constructs this key once per successful location read
/// (Step 2 of `frontend/geo-visibility-PLAN.md`), not on every rebuild.
/// The family key gained two members alongside the viewer coordinate:
/// `intent` is now nullable (null = every intent, Home's "All" chip) and
/// `withinDays` bounds how far out to look (0 = unrestricted, Home's
/// "Happening Soon" passes 7). Both are part of the key rather than the
/// call because they are part of WHAT IS BEING ASKED FOR — two different
/// filters are two different cached results, not one result to invalidate
/// between.
final openMeetupsProvider = FutureProvider.autoDispose
    .family<
      PagedResult<Meetup>,
      ({IntentType? intent, double viewerLat, double viewerLng, int withinDays})
    >(
      (ref, key) => ref
          .watch(meetupServiceProvider)
          .listOpenMeetups(
            intent: key.intent,
            viewerLat: key.viewerLat,
            viewerLng: key.viewerLng,
            withinDays: key.withinDays,
          ),
    );

/// The signed-in user's hosted + requested meetups — "My Meetups"
/// (frontend/meetup-scheduling-PLAN.md Step 8). Only ever the *first* page
/// of each side (2026-08-31 round-4 hardening) — `EventsPage`'s lists
/// accumulate further pages themselves through the shared
/// `PaginatedMeetupList`, the same split `openMeetupsProvider` and Home's
/// own "Happening Soon" list use.
final myMeetupsProvider =
    FutureProvider.autoDispose<
      ({
        List<Meetup> hosted,
        List<Meetup> requested,
        String? hostedNextCursor,
        bool hostedHasMore,
        String? requestedNextCursor,
        bool requestedHasMore,
      })
    >((ref) => ref.read(meetupServiceProvider).listMyMeetups());

/// Meetups where the caller is host or an accepted participant, merged and
/// server-sorted soonest-first (ADR-025 §2) — backs HomePage's "Active
/// Meetups" section and the persistent swipeable card.
final activeMeetupsProvider = FutureProvider.autoDispose<List<Meetup>>(
  (ref) => ref.read(meetupServiceProvider).listActiveMeetups(),
);

/// The signed-in user's trusted contacts (ADR-026) — read by both the
/// manage-contacts screen and `SafetyPage`'s SOS button (to decide whether
/// tapping TRIGGER SOS should even show the confirm dialog, or route to
/// manage-contacts instead). `.autoDispose` so a stale list isn't kept
/// alive after navigating away — contacts can be added/removed from the
/// manage screen, so the safety page should always see a fresh read, not a
/// cached one from an earlier visit.
final trustedContactsProvider =
    FutureProvider.autoDispose<List<TrustedContact>>(
      (ref) => ref.read(authServiceProvider).listTrustedContacts(),
    );

/// Whether the app has a persisted session, and the profile cached from it.
/// Nothing tracked a logged-in user across app restarts before this —
/// without it, every relaunch would force a fresh LinkedIn login, defeating
/// the point of a 30-day refresh token.
class AuthSessionState {
  const AuthSessionState({this.session, this.profile});

  final AuthSession? session;
  final UserProfile? profile;

  /// A stored refresh token is the actual "logged in" signal — the short
  /// (15 min) access token being expired doesn't mean the session is gone,
  /// it means the next authenticated call should refresh first.
  bool get isLoggedIn => session != null;
}

class AuthSessionNotifier extends AsyncNotifier<AuthSessionState> {
  @override
  Future<AuthSessionState> build() async {
    // getValidSession() refreshes-and-persists first if the stored access
    // token is expired or about to be — a secure-storage read failure, an
    // already-dead refresh token, or a transient network error during that
    // refresh are all treated alike as "no session," same as before this
    // addendum: forcing a fresh LinkedIn login is the safe fallback, not a
    // hang. This is also why an idle-but-not-force-quit session (backgrounded
    // past the 15-minute access-token TTL but well within the 30-day
    // refresh-token life) now correctly comes back logged in on relaunch
    // instead of being forced to sign in again.
    try {
      final session = await ref.read(tokenRefresherProvider).getValidSession();
      if (session == null) return const AuthSessionState();
      final state = AuthSessionState(
        session: session,
        profile: await _fetchProfileOrFallback(session),
      );
      unawaited(_registerPushTokenIfAvailable());
      return state;
    } catch (_) {
      return const AuthSessionState();
    }
  }

  /// ADR-030 (round-9 scaffolding) — best-effort push-token registration,
  /// called once a session is established (session-restore here,
  /// [_completeSignIn] for a fresh sign-in/sign-up). Always a no-op
  /// end-to-end today: [NoOpPushNotificationService.currentToken] always
  /// returns `null`, so [MeetupService.registerDeviceToken] never actually
  /// fires — the plumbing exists so a real `PushNotificationService`
  /// implementation makes this live with no call-site change. `unawaited`
  /// at both call sites deliberately — this must never delay or fail
  /// session establishment over a notification concern, and any failure
  /// inside is swallowed for the same reason.
  Future<void> _registerPushTokenIfAvailable() async {
    try {
      final token = await ref
          .read(pushNotificationServiceProvider)
          .currentToken();
      if (token == null) return;
      await ref.read(meetupServiceProvider).registerDeviceToken(token);
    } catch (_) {
      // Best-effort — see doc comment above.
    }
  }

  Future<void> signInWithLinkedIn({required bool ageConfirmedOver18}) =>
      _completeSignIn(
        () => ref
            .read(authServiceProvider)
            .signInWithLinkedIn(ageConfirmedOver18: ageConfirmedOver18),
      );

  /// ADR-014's three additional account-creation paths — each just calls a
  /// different [AuthService] method, then shares the exact same
  /// save-session-and-fetch-profile tail as [signInWithLinkedIn] via
  /// [_completeSignIn], so that bookkeeping isn't duplicated four times.
  Future<void> signInWithApple({required bool ageConfirmedOver18}) =>
      _completeSignIn(
        () => ref
            .read(authServiceProvider)
            .signInWithApple(ageConfirmedOver18: ageConfirmedOver18),
      );

  Future<void> signInWithGoogle({required bool ageConfirmedOver18}) =>
      _completeSignIn(
        () => ref
            .read(authServiceProvider)
            .signInWithGoogle(ageConfirmedOver18: ageConfirmedOver18),
      );

  /// The guest path (ADR-002 § 3). Uses the same [_completeSignIn] tail as
  /// every other entry point — a guest gets a real session and a real
  /// profile fetch, because it is a real account.
  Future<void> guestSignup({required bool ageConfirmedOver18}) =>
      _completeSignIn(
        () => ref
            .read(authServiceProvider)
            .guestSignup(ageConfirmedOver18: ageConfirmedOver18),
      );

  Future<void> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) => _completeSignIn(
    () => ref
        .read(authServiceProvider)
        .signUpWithEmail(
          email: email,
          code: code,
          ageConfirmedOver18: ageConfirmedOver18,
        ),
  );

  /// Sends the OTP [loginWithEmail] verifies (ADR-019 §1) — doesn't touch
  /// session state itself, just delegates; unlike every other method here,
  /// this isn't a sign-in completion, so it has no [_completeSignIn] tail.
  Future<int> startEmailLoginOtp(String email) =>
      ref.read(authServiceProvider).startEmailLoginOtp(email);

  Future<void> loginWithEmail({required String email, required String code}) =>
      _completeSignIn(
        () => ref
            .read(authServiceProvider)
            .loginWithEmail(email: email, code: code),
      );

  /// Shared tail for every account-creation/sign-in path (ADR-014) — sets
  /// [AsyncLoading], calls [signIn], saves the resulting session, fetches
  /// the profile, and re-throws on failure so the caller (whichever
  /// onboarding/login screen triggered this) can show the specific mapped
  /// error message; state still reflects the failure for anything else
  /// watching this provider.
  Future<void> _completeSignIn(Future<AuthSession> Function() signIn) async {
    state = const AsyncLoading();
    try {
      final session = await signIn();
      await ref.read(sessionStorageProvider).saveSession(session);
      state = AsyncData(
        AuthSessionState(
          session: session,
          profile: await _fetchProfileOrFallback(session),
        ),
      );
      unawaited(_registerPushTokenIfAvailable());
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  /// Profile-initiated "Connect LinkedIn" (ADR-014) — links LinkedIn to the
  /// CALLER's already-authenticated account rather than creating/resolving
  /// one, so this reuses [completeVerification]'s save-and-refresh
  /// semantics (the same shape every Level 2/3 verification-completing call
  /// already uses) rather than [_completeSignIn], which is for the
  /// four account-creation paths specifically.
  Future<void> linkLinkedIn() async {
    final session = await ref.read(authServiceProvider).linkLinkedIn();
    await completeVerification(session);
  }

  /// Called after any verification-completing [AuthService] call succeeds
  /// (`verifyPhoneCode`, `submitPersonalDetails`, etc.) — saves the fresh
  /// session immediately (so the new trust level is live without waiting
  /// for the next natural token refresh) *and* re-fetches the full
  /// profile, so `UserProfile`'s booleans move together with `AuthSession`
  /// rather than drifting: without this, `ProfilePage`'s Phone row could
  /// still say "Not verified" immediately after phone verification
  /// actually succeeded, right after the trust-level badge elsewhere
  /// already updated (`frontend/PLAN.md`'s Level 2/3 addendum, Step 2).
  Future<void> completeVerification(AuthSession session) async {
    await ref.read(sessionStorageProvider).saveSession(session);
    state = AsyncData(
      AuthSessionState(
        session: session,
        profile: await _fetchProfileOrFallback(session),
      ),
    );
  }

  /// Backs ADR-019 §2's new mandatory post-auth screen — updates the
  /// cached [UserProfile] in place from the response, without touching
  /// [AuthSessionState.session] (`full_name` isn't part of the JWT claims,
  /// unlike trust level, so there's no fresh token to save here, unlike
  /// [completeVerification]).
  Future<void> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async {
    final profile = await ref
        .read(authServiceProvider)
        .completeProfileSetup(
          fullName: fullName,
          companyName: companyName,
          companyEmail: companyEmail,
        );
    final session = state.value?.session;
    // Shouldn't happen — this is only ever called mid-session.
    if (session == null) return;
    state = AsyncData(AuthSessionState(session: session, profile: profile));
  }

  /// Clears the local session regardless of whether the network call
  /// succeeds — a failed logout call to the backend shouldn't leave the
  /// user stuck signed in locally, same idempotent-logout spirit as the
  /// backend's `/v1/auth/logout` (`frontend/PLAN.md` Step 7).
  Future<void> signOut() async {
    // Ensure build() has actually resolved before reading state.value —
    // ProfilePage never reads/watches this provider itself (only this
    // method does, lazily, on tap), so without this a sign-out fired before
    // the notifier's first build completes would see a stale/absent
    // session, silently skip the backend logout() call, and leave a live,
    // unrevoked refresh token server-side while the local session already
    // looks signed out. In the real app SplashScreen always reads this
    // provider first and primes it long before ProfilePage is reachable,
    // but this shouldn't depend on that navigation ordering to be correct.
    await future;
    final refreshToken = state.value?.session?.refreshToken;
    if (refreshToken != null) {
      try {
        await ref.read(authServiceProvider).logout(refreshToken);
      } catch (_) {
        // Ignored on purpose — see doc comment above.
      }
    }
    await ref.read(sessionStorageProvider).clearSession();
    state = const AsyncData(AuthSessionState());
  }

  /// Called when a caller catches `SessionExpiredException` from an
  /// authenticated call made mid-session (not during build()/launch, which
  /// already handles this itself via getValidSession()'s own catch) —
  /// TokenRefresher has already cleared storage by the time this runs
  /// (whatever call failed went through its getValidAccessToken), so this
  /// only needs to bring in-memory state into agreement with it; Riverpod
  /// doesn't notice a storage write it wasn't watching for on its own.
  /// Unlike [signOut], this must NOT call authService.logout() — the
  /// refresh token that call would send is already dead server-side
  /// (that's why we're here), and storage no longer has it to send anyway.
  void forceSignOut() {
    state = const AsyncData(AuthSessionState());
  }

  /// Tries a real `getProfile()` fetch; falls back to the minimal profile
  /// derivable from [session] alone (the pre-addendum behavior) if the
  /// fetch fails — e.g. offline right at launch. A transient failure here
  /// must not crash session loading; the next successful fetch catches up.
  Future<UserProfile> _fetchProfileOrFallback(AuthSession session) async {
    try {
      return await ref.read(authServiceProvider).getProfile();
    } catch (_) {
      return UserProfile(
        id: session.userId,
        fullName: session.fullName,
        profilePhotoUrl: session.profilePhotoUrl,
        trustLevel: session.trustLevel,
      );
    }
  }
}

final authSessionProvider =
    AsyncNotifierProvider<AuthSessionNotifier, AuthSessionState>(
      AuthSessionNotifier.new,
    );

/// Key shared_preferences is persisted under (Slice G) — a plain string
/// ('dark'/'light'), not an int/bool, so a stray unrelated value under this
/// key from some future migration mistake fails safe as "unrecognized,
/// treat as dark" rather than silently reading a wrong enum index.
const _themeModePrefsKey = 'app_theme_mode';

/// Dark/light toggle (Slice G) — a plain [Notifier], not [AsyncNotifier]:
/// unlike [AuthSessionNotifier] (where callers genuinely need to wait for
/// session restore before deciding what to show), nothing here should ever
/// have to sit in an `AsyncValue.loading` state just to render a color, so
/// [build] returns synchronously with the hard-coded default and the
/// persisted preference (if any) catches up moments later via [_load] —
/// same "default to dark first, then reconcile" reasoning as the spec's
/// own "default to dark, not system brightness" requirement, just applied
/// to the loading window too, not only to a fresh install with no
/// persisted value at all.
class ThemeModeNotifier extends Notifier<AppThemeMode> {
  @override
  AppThemeMode build() {
    _load();
    return AppThemeMode.dark;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_themeModePrefsKey) == 'light') {
      _apply(AppThemeMode.light);
    }
  }

  Future<void> toggle() async {
    final next = state == AppThemeMode.dark
        ? AppThemeMode.light
        : AppThemeMode.dark;
    _apply(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _themeModePrefsKey,
      next == AppThemeMode.light ? 'light' : 'dark',
    );
  }

  /// Updates [AppPalette]'s own static mode flag *before* `state = mode` —
  /// every `AppPalette.someColor` getter reads that flag directly, not
  /// this provider's state, so widgets rebuilding in response to the state
  /// change below must already see the new colors once they rebuild, not
  /// a stale value from a write that hasn't landed yet.
  void _apply(AppThemeMode mode) {
    AppPalette.setMode(mode);
    state = mode;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, AppThemeMode>(
  ThemeModeNotifier.new,
);
