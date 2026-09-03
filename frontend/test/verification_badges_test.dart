import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/verification_badges.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets(
    'workEmailVerifiedOverride true shows Official regardless of trust '
    'level (ADR-023 §2 — the self-view case)',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const VerificationBadges(
            trustLevel: 1,
            workEmailVerifiedOverride: true,
          ),
        ),
      );

      expect(find.text('Official'), findsOneWidget);
      expect(find.text('Professional'), findsOneWidget);
    },
  );

  testWidgets(
    'workEmailVerifiedOverride false hides Official even at trust level 3',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const VerificationBadges(
            trustLevel: 3,
            workEmailVerifiedOverride: false,
          ),
        ),
      );

      expect(find.text('Official'), findsNothing);
      expect(find.text('Professional'), findsOneWidget);
    },
  );

  testWidgets(
    'null override (every other-user-facing call site) falls back to the '
    'existing trustLevel >= 3 behavior, unchanged',
    (tester) async {
      await tester.pumpWidget(wrap(const VerificationBadges(trustLevel: 2)));
      expect(find.text('Official'), findsNothing);
      expect(find.text('Professional'), findsOneWidget);
    },
  );

  testWidgets(
    'null override at trust level 3 still shows Official — the pre-ADR-023 '
    'behavior every browse/request card still depends on',
    (tester) async {
      await tester.pumpWidget(wrap(const VerificationBadges(trustLevel: 3)));
      expect(find.text('Official'), findsOneWidget);
      expect(find.text('Professional'), findsOneWidget);
    },
  );
}
