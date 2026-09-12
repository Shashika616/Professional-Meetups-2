import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/splash/splash_screen.dart';

// The landing page is the first thing anyone sees, and until the TieHere
// rebrand it never said the product's name anywhere on it - the hero read
// "CONNECT BEYOND THE OFFICE." over a generic subline. The brand was in the
// launcher label and nowhere else, which is why the app still "looked like"
// the old one after the name had in fact been changed.
//
// These assert the two things a landing page owes the brand: the name, and
// the one line that says what it is for.
void main() {
  Future<void> pumpLanding(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LandingPage())),
    );
    await tester.pump();
  }

  testWidgets('the wordmark is on the page, split across its two brand '
      'colours', (tester) async {
    await pumpLanding(tester);

    // RichText, not two Texts, so find.text cannot see it - walk the spans.
    final spans = <String, Color?>{};
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          spans[span.text!] = span.style?.color;
        }
        return true;
      });
    }

    expect(
      spans.containsKey('Tie'),
      isTrue,
      reason: 'wordmark half "Tie" missing',
    );
    expect(
      spans.containsKey('Here'),
      isTrue,
      reason: 'wordmark half "Here" missing',
    );
    expect(
      spans['Here'],
      AppPalette.brandGreen,
      reason: '"Here" carries the brand green, as the brand sheet sets it',
    );
  });

  testWidgets('the tagline is the one the brand actually uses', (tester) async {
    await pumpLanding(tester);
    expect(find.text("Connect with who's here"), findsOneWidget);
  });

  _splashTests();

  testWidgets('the retired placeholder copy is gone', (tester) async {
    await pumpLanding(tester);
    expect(find.textContaining('CONNECT BEYOND'), findsNothing);
    expect(find.textContaining('Meet verified professionals'), findsNothing);
    expect(find.textContaining('PROFESSIONAL CONNECTIONS'), findsNothing);
  });
}

// The splash is the first surface anyone sees, and it carried the old name in
// tracked-out caps ("PROFESSIONAL\nCONNECTIONS") long after the launcher label
// had been changed - which is why the app kept looking un-renamed.
void _splashTests() {
  testWidgets('the splash shows the wordmark, not the retired name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SplashScreen())),
    );
    await tester.pump();

    final texts = <String>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      rt.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) texts.add(span.text!);
        return true;
      });
    }

    expect(texts, contains('Tie'));
    expect(texts, contains('Here'));
    expect(find.textContaining('PROFESSIONAL'), findsNothing);
    expect(find.textContaining('Connect Beyond'), findsNothing);

    // The maker's mark: middle dots (U+00B7), not full stops.
    expect(texts, contains('From '));
    expect(texts, contains('·SAI·'));

    // Let the 2s navigation timer drain so the test does not end with one
    // pending.
    await tester.pump(const Duration(seconds: 3));
  });
}
