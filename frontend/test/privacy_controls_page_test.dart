import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyControlsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('lists each thing the app does with your data', (tester) async {
    await pumpPage(tester);
    for (final title in [
      'Who can see you',
      'Your location',
      'Trusted contacts',
      'Searching for a place',
      'Ratings you give',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'missing "$title"');
    }
  });

  // Each fact is collapsed until tapped.
  Future<void> open(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  // #94: place search sends what you type to outside services. The policy
  // has to name them, on both platforms.
  testWidgets('names every service a place search reaches', (tester) async {
    await pumpPage(tester);
    await open(tester, 'Searching for a place');
    for (final service in ['Apple Maps', 'Photon by komoot', 'Nominatim']) {
      expect(
        find.textContaining(service),
        findsOneWidget,
        reason: '"$service" is not disclosed',
      );
    }
  });

  // #80: adding a contact now texts them once. The page used to say nobody
  // contacts them but you, which stopped being true.
  testWidgets('says a new trusted contact is texted once to agree', (
    tester,
  ) async {
    await pumpPage(tester);
    await open(tester, 'Trusted contacts');
    expect(
      find.textContaining('we text them once to ask whether they agree'),
      findsOneWidget,
    );
  });
}
