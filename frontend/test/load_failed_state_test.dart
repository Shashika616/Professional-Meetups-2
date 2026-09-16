import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';

void main() {
  group('LoadFailure.of names the one thing the person can act on', () {
    test('offline, in the service\'s own words', () {
      final f = LoadFailure.of(const MeetupOfflineException());
      expect(f.kind, LoadFailureKind.offline);
      expect(f.title, 'You look offline');
      expect(f.message, contains('Check your network'));
    });

    test('other transport failures are offline too', () {
      expect(
        LoadFailure.of(const AuthNetworkException('x')).kind,
        LoadFailureKind.offline,
      );
      expect(
        LoadFailure.of(TimeoutException('x')).kind,
        LoadFailureKind.offline,
      );
    });

    test('a 403 is a permission matter, not a network one', () {
      final f = LoadFailure.of(const MeetupForbiddenException('nope'));
      expect(f.kind, LoadFailureKind.permission);
      expect(f.message, contains('verify your account'));
    });

    test('a location problem keeps its own sentence', () {
      final f = LoadFailure.of(
        const LocationUnavailableException(
          'Turn on location services to use this.',
          reason: LocationUnavailableReason.servicesDisabled,
        ),
      );
      expect(f.kind, LoadFailureKind.location);
      expect(f.message, 'Turn on location services to use this.');
    });

    test('anything else is on us, and never leaks the raw error', () {
      final f = LoadFailure.of(StateError('internal detail 12345'));
      expect(f.kind, LoadFailureKind.server);
      expect(f.message, isNot(contains('12345')));
    });
  });

  testWidgets('LoadFailedState shows the picture, the copy and a retry that '
      'calls back', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadFailedState(
            failure: LoadFailure.of(const MeetupOfflineException()),
            onRetry: () => retried++,
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('You look offline'), findsOneWidget);
    await tester.tap(find.text('TRY AGAIN'));
    expect(retried, 1);
  });

  testWidgets('SkeletonThenFailure holds the skeleton, then shows the '
      'failure, and cancels its timer when removed early', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SkeletonThenFailure(
          skeleton: Text('skeleton'),
          failure: Text('failure'),
          holdFor: Duration(milliseconds: 500),
        ),
      ),
    );
    expect(find.text('skeleton'), findsOneWidget);
    expect(find.text('failure'), findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('skeleton'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('failure'), findsOneWidget);
    expect(find.text('skeleton'), findsNothing);

    // Removed before the hold ends: no timer left behind (flutter_test
    // fails the test itself if one is).
    await tester.pumpWidget(
      const MaterialApp(
        home: SkeletonThenFailure(
          skeleton: Text('skeleton'),
          failure: Text('failure'),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
