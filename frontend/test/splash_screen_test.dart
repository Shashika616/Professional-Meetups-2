import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/splash/splash_art.dart';
import 'package:professional_connections_platform/features/splash/splash_screen.dart';

class _LoggedOut extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState();
}

void main() {
  Widget app() => ProviderScope(
    overrides: [authSessionProvider.overrideWith(_LoggedOut.new)],
    child: const MaterialApp(home: SplashScreen()),
  );

  testWidgets('shows the brand while it decides', (tester) async {
    await tester.pumpWidget(app());
    expect(
      find.byKey(const ValueKey('splash-gradient-container')),
      findsOneWidget,
    );
    expect(find.text("Connect with who's here"), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  // The session is usually known in milliseconds; the brand still shows for
  // its minimum, so the launch does not flash.
  testWidgets('holds for its minimum before moving on', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(LandingPage), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('takes a signed-out user to the landing page', (tester) async {
    await tester.pumpWidget(app());
    // The spinner and the landing page both animate forever, so this pumps
    // through the route transition instead of waiting for things to settle.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.byType(LandingPage), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });

  testWidgets('the mark plays in reverse over the next screen, then is gone', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byType(SplashArt),
      findsOneWidget,
      reason: 'one copy, never two',
    );
    final art = tester.widget<SplashArt>(find.byType(SplashArt));
    expect(art.progress.value, inExclusiveRange(0, 1));
    // The next screen waits until the mark has gone.
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.byType(LandingPage),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades.any((f) => f.opacity.value == 0), isTrue);
    expect(find.byType(LandingPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byType(SplashArt), findsNothing);
  });

  testWidgets(
    'reduce motion shows the finished mark and fades, with no reverse',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(app());
      final art = tester.widget<SplashArt>(find.byType(SplashArt));
      expect(art.progress.value, 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LandingPage), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SplashArt), findsNothing);
    },
  );

  testWidgets('a slow session keeps the mark up with a spinner', (
    tester,
  ) async {
    final session = Completer<AuthSessionState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionProvider.overrideWith(() => _Slow(session.future)),
        ],
        child: const MaterialApp(home: SplashScreen()),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(BrandLoader), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BrandLoader), findsOneWidget);
    session.complete(const AuthSessionState());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(LandingPage), findsOneWidget);
  });
}

class _Slow extends AuthSessionNotifier {
  _Slow(this.result);

  final Future<AuthSessionState> result;

  @override
  Future<AuthSessionState> build() => result;
}
