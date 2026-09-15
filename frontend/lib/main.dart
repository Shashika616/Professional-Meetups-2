import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/features/splash/splash_screen.dart';
import 'package:professional_connections_platform/firebase_options.dart';

/// Handles a push message that arrives while the app is fully
/// backgrounded/terminated (ADR-030, round-10) — `firebase_messaging`
/// requires this to be a top-level (or static) function, annotated exactly
/// like this, since it runs in a separate background isolate spun up just
/// for this call, which has none of `main()`'s state. Per the package's own
/// contract, that isolate needs its own `Firebase.initializeApp()` call
/// before doing anything Firebase-related — this app doesn't otherwise act
/// on a background message today (no local-notification display, no
/// provider to invalidate — there's no running app instance to invalidate
/// a provider in), so this is currently just the required registration
/// hook, not a place with real logic yet.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

/// Replaces Flutter's default error widget (which renders the raw
/// exception message and widget-library stack trace) with a clean,
/// user-safe fallback — never anything from [details] itself. A top-level
/// function, not an inline closure in [main], so it's directly testable.
Widget buildFriendlyErrorWidget(FlutterErrorDetails details) {
  return Material(
    color: AppPalette.onyx,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: AppPalette.danger,
              size: 40,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong.',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Please try again. If this keeps happening, let us know.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ADR-030 (round-10) — must happen before runApp: FirebasePushNotificationService
  // (core/services/firebase_push_notification_service.dart) and the
  // background handler below both assume Firebase is already initialized
  // by the time anything touches FirebaseMessaging. Real project
  // (professional-meetups-976d2); firebase_options.dart is hand-authored
  // from the real, already-placed google-services.json/
  // GoogleService-Info.plist, not a placeholder.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Without this, any widget-build-time exception (a bad cast, a null from
  // a provider that shouldn't be null, a RenderFlex overflow that throws)
  // falls through to Flutter's *default* error widget — which renders the
  // raw exception message and widget-library stack trace directly on
  // screen, in both debug and release builds. That's developer-facing
  // detail, not something a real user should ever see. This only replaces
  // what's *shown*; FlutterError.onError is left at its default, so the
  // full error still gets dumped to the console exactly as before — the
  // real detail is still there for whoever's looking at logs, just not
  // rendered into the app itself.
  ErrorWidget.builder = buildFriendlyErrorWidget;

  // Configure image cache for better performance
  PaintingBinding.instance.imageCache.maximumSize = 100;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20; // 100 MB

  runApp(
    ProviderScope(
      retry: _retryPolicy,
      child: const ProfessionalConnectionsApp(),
    ),
  );
}

/// When a failed provider is worth trying again, and when it is not.
///
/// # WHY THIS EXISTS
///
/// Riverpod retries any failed provider on its own, forever, with exponential
/// backoff. That is right for a flaky network and wrong for a permanent
/// failure, and the app has already been bitten by the difference once: a
/// billing endpoint returning 503 because it was not built yet produced a
/// retry loop that was a third of all traffic to the server.
///
/// The same shape showed up again on 2026-09-11 with a dead session. Observed
/// in the production logs:
///
///     19:08:32  /v1/meetups/active  401
///     19:08:42  /v1/meetups/active  401
///     19:08:53  /v1/meetups/active  401
///     19:09:04  /v1/meetups/active  401
///
/// A 401 means the refresh token is gone. Retrying it cannot succeed, so the
/// user sits on a loading skeleton while their phone talks to the server every
/// ten seconds until the app is closed. Battery, data and server load, all for
/// a request whose answer will never change.
///
/// So: session failures are terminal; everything else retries with
/// Riverpod's backoff, but only [maxProviderRetries] times. A transient blip
/// recovers well inside that budget (the schedule below adds up to about 40
/// seconds), while a phone that is genuinely offline, or a server that is
/// genuinely down, stops being asked every 6.4 seconds for as long as the
/// app is open. Every screen that shows a provider error already has a
/// RETRY button or pull-to-refresh, so giving up in the background costs the
/// user nothing they cannot get back with one tap.
@visibleForTesting
Duration? retryPolicyForTest(int retryCount, Object error) =>
    _retryPolicy(retryCount, error);

/// 200, 400, 800, 1600, 3200, 6400, 6400, 6400 ms: eight attempts, ~40s.
@visibleForTesting
const int maxProviderRetries = 8;

Duration? _retryPolicy(int retryCount, Object error) {
  if (error is MeetupSessionExpiredException ||
      error is SessionExpiredException) {
    return null;
  }
  if (retryCount >= maxProviderRetries) return null;
  // Riverpod's own default: 200ms doubling, capped at 6.4s.
  final ms = 200 * (1 << retryCount);
  return Duration(milliseconds: ms > 6400 ? 6400 : ms);
}

/// A [ConsumerWidget] (was `StatelessWidget` before Slice G) so it can
/// [WidgetRef.watch] [themeModeProvider] — that watch is what actually
/// forces a rebuild on toggle; [AppPalette]'s static getters alone don't
/// notify anything. [MaterialApp] is keyed on the theme mode so the
/// rebuild reaches every already-pushed route, not just this widget's
/// immediate return value — `Navigator`-held route state is intentionally
/// discarded and restarts at [SplashScreen] on a toggle (which fast-paths
/// straight back to `AppShell` for an already-signed-in user); this is the
/// accepted tradeoff of the "key the root widget" approach the theming
/// plan calls out, not an oversight — a full app remount is the simplest
/// way to guarantee every visible screen's colors actually flip, verified
/// by `test/theme_toggle_test.dart` rather than assumed.
class ProfessionalConnectionsApp extends ConsumerWidget {
  const ProfessionalConnectionsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final isLight = themeMode == AppThemeMode.light;

    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: AppPalette.onyx,
      systemNavigationBarIconBrightness: isLight
          ? Brightness.dark
          : Brightness.light,
    );
    SystemChrome.setSystemUIOverlayStyle(overlayStyle);

    return MaterialApp(
      key: ValueKey(themeMode),
      debugShowCheckedModeBanner: false,
      title: 'TieHere',
      // The style above is only a request; any route that paints its own
      // (an AppBar, a dialog) replaces it, and a page without one keeps
      // whatever came last, which is how the clock ended up white on the
      // light ground. Annotating the whole tree keeps every screen honest.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: child ?? const SizedBox.shrink(),
      ),
      theme: ThemeData(
        brightness: isLight ? Brightness.light : Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: AppPalette.onyx,
        colorScheme: isLight
            ? ColorScheme.light(
                primary: AppPalette.candyBlue,
                secondary: AppPalette.steelBlue,
                surface: AppPalette.surface,
                onPrimary: AppPalette.onyx,
              )
            : ColorScheme.dark(
                primary: AppPalette.candyBlue,
                secondary: AppPalette.steelBlue,
                surface: AppPalette.surface,
                onPrimary: AppPalette.onyx,
              ),
        // The bar itself stays TRANSPARENT so the page background runs
        // unbroken from top to bottom. A solid brand-blue header was tried and
        // removed: sliding between pages, a full width colour band appearing
        // and disappearing made the app feel like several different apps
        // rather than one.
        //
        // The title earns its place through weight and contrast instead, which
        // is what the reference designs do too: a heavier, fully opaque title
        // over a plain page reads as a header without needing a slab behind it.
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          // An AppBar paints its own status-bar style, and with a
          // transparent background it guessed light icons in light mode
          // (a white clock on the pale ground). Pin it to the app's.
          systemOverlayStyle: overlayStyle,
          titleTextStyle: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 15,
            // Heavier and more tracked out than body text, which is what
            // separates it now that nothing else does.
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
          ),
          iconTheme: IconThemeData(color: AppPalette.candyBlue),
        ),

        // Tab selection has to be unmissable.
        //
        // Material's defaults gave the selected and unselected labels the same
        // size and nearly the same colour, so on Events it was genuinely hard
        // to tell which of "My Meetings" / "Requested Meetings" was active.
        //
        // Three signals now, not one: the selected label is LARGER, heavier,
        // and full contrast, while the unselected is smaller and muted, and a
        // rounded indicator sits under it. Flutter tweens between the two
        // label styles as the tab slides, so the size change animates rather
        // than snapping.
        tabBarTheme: TabBarThemeData(
          labelColor: AppPalette.textPrimary,
          unselectedLabelColor: AppPalette.textSecondary,
          labelStyle: const TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
          indicatorSize: TabBarIndicatorSize.label,
          indicator: UnderlineTabIndicator(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(width: 3, color: AppPalette.candyBlue),
            insets: const EdgeInsets.only(bottom: 6),
          ),
          dividerColor: Colors.transparent,
          overlayColor: WidgetStatePropertyAll<Color>(Colors.transparent),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppPalette.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentTextStyle: TextStyle(
            color: AppPalette.candyBlue,
            fontSize: 13,
          ),
        ),
        // ADR-032 round 2. Material 3 defaults EVERY button to a
        // StadiumBorder — a full pill — and nothing here overrode it, so
        // "Host your own meetup" (an OutlinedButton.icon) and every other
        // OutlinedButton/TextButton/ElevatedButton in the app kept rendering
        // as a glass-era capsule even after round 1 flattened their colors.
        // Set once here rather than at ~40 call sites, matching the
        // reference image's 12px button/card radius and PrimaryButton's own
        // fixed 12.
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        // Add premium page transitions
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _ZoomPageTransitionsBuilder(),
            TargetPlatform.iOS: _ZoomPageTransitionsBuilder(),
          },
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// Custom zoom + fade transition for premium feel
class _ZoomPageTransitionsBuilder extends PageTransitionsBuilder {
  const _ZoomPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _ZoomPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _ZoomPageTransition extends StatelessWidget {
  const _ZoomPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    );
  }
}
