import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
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
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LandingPage), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });
}
