import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  runApp(const ProviderScope(child: ProfessionalConnectionsApp()));
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

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
        statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: AppPalette.onyx,
        systemNavigationBarIconBrightness: isLight
            ? Brightness.dark
            : Brightness.light,
      ),
    );

    return MaterialApp(
      key: ValueKey(themeMode),
      debugShowCheckedModeBanner: false,
      title: 'Professional Connections',
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
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.0,
          ),
          iconTheme: IconThemeData(color: AppPalette.candyBlue),
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
