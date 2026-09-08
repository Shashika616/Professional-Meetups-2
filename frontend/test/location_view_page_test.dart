import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// # WHERE THIS FILE CAME FROM
///
/// The "View Location" group of the deleted `matches_page_test.dart`. The
/// page it covers did not move or change; only the page that USED to launch
/// it did, so its tests now live under their own subject's name.
///
/// The trust gate group is new. [LocationViewPage.open]'s gate has moved
/// three times (see its own doc comment) and is currently keyed on
/// `viewerTrustLevel`, not `lockedForViewer` — so it is tested as a control
/// run in both directions rather than in one.
Meetup _meetup({bool lockedForViewer = false}) => Meetup(
  id: 'meetup-1',
  hostUserId: 'host-1',
  hostFullName: lockedForViewer ? null : 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: lockedForViewer ? null : DateTime(2026, 9, 7, 10),
  windowEnd: lockedForViewer ? null : DateTime(2026, 9, 7, 12),
  locationLat: 6.9271,
  locationLng: 79.8612,
  // A locked meetup still carries a real label — ADR-002 § 5's guest tier.
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime(2026, 9, 1),
  lockedForViewer: lockedForViewer,
);

/// Mounts a bare button whose only job is to call [LocationViewPage.open]
/// with the given viewer trust level, so the gate is exercised through its
/// real entry point (rather than by constructing the page directly, which
/// would bypass the very thing under test).
/// The ProviderScope is not incidental: the blocked branch pushes
/// VerificationChecklistPage, which reads authSessionProvider, so a bare
/// MaterialApp would fail with "No ProviderScope found" — and would fail the
/// same way whether the gate worked or not.
Widget _opener({required int viewerTrustLevel, required Meetup meetup}) {
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(
        () => _FakeAuthSessionNotifier(
          AuthSessionState(
            profile: UserProfile(
              id: 'user-1',
              fullName: 'Grace',
              trustLevel: viewerTrustLevel,
            ),
          ),
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => LocationViewPage.open(
                context,
                meetup,
                viewerTrustLevel: viewerTrustLevel,
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

void main() {
  group('the trust gate on open() — control run in both directions', () {
    testWidgets('a guest (Level 0) is redirected: the toast and '
        'VerificationChecklistPage, never the map page', (tester) async {
      await tester.pumpWidget(
        _opener(viewerTrustLevel: 0, meetup: _meetup(lockedForViewer: true)),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(find.byType(LocationViewPage), findsNothing);
      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      expect(
        find.text('Sign up to see exactly where this meetup is happening.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'Level 1 — the very next rung — opens the page unconditionally',
      (tester) async {
        await tester.pumpWidget(
          _opener(viewerTrustLevel: 1, meetup: _meetup()),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsNothing);
      },
    );

    // The two tests below are the halves that prove the gate keys on the
    // VIEWER's level and NOT on `lockedForViewer` — the two happen to
    // coincide in production today (after ADR-002 § 6 only guests are
    // locked), so only mismatched pairs can tell them apart. Kept as
    // separate tests rather than one: each needs its own Navigator, and
    // re-pumping a new root inside one test leaves the first push on the
    // old one.
    testWidgets(
      'a Level 1 viewer holding a meetup the server still marked locked '
      'gets in — lockedForViewer alone does not close this gate',
      (tester) async {
        await tester.pumpWidget(
          _opener(viewerTrustLevel: 1, meetup: _meetup(lockedForViewer: true)),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsNothing);
      },
    );

    testWidgets(
      'a Level 0 viewer holding an UNLOCKED meetup is still blocked — '
      'lockedForViewer alone does not open it either',
      (tester) async {
        await tester.pumpWidget(
          _opener(viewerTrustLevel: 0, meetup: _meetup()),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsNothing);
        expect(find.byType(VerificationChecklistPage), findsOneWidget);
      },
    );
  });

  group('GET DIRECTIONS (ADR-029)', () {
    tearDown(() => debugLaunchUrlOverride = null);

    testWidgets(
      'deep-links to Google Maps directions on Android (and every non-iOS '
      'platform), not in-app routing',
      (tester) async {
        Uri? launchedUri;
        LaunchMode? launchedMode;
        debugLaunchUrlOverride =
            (url, {mode = LaunchMode.platformDefault}) async {
              launchedUri = url;
              launchedMode = mode;
              return true;
            };

        await tester.pumpWidget(
          MaterialApp(home: LocationViewPage(meetup: _meetup())),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('GET DIRECTIONS'));
        await tester.pumpAndSettle();

        expect(launchedMode, LaunchMode.externalApplication);
        expect(launchedUri, isNotNull);
        expect(launchedUri!.scheme, 'https');
        expect(launchedUri!.host, 'www.google.com');
        expect(launchedUri!.path, '/maps/dir/');
        expect(launchedUri!.queryParameters['api'], '1');
        expect(launchedUri!.queryParameters['destination'], '6.9271,79.8612');
      },
    );

    testWidgets(
      'deep-links to Apple Maps on iOS, not Google Maps — iOS already has '
      'its own map app, no reason to route through Google\'s',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        Uri? launchedUri;
        LaunchMode? launchedMode;
        debugLaunchUrlOverride =
            (url, {mode = LaunchMode.platformDefault}) async {
              launchedUri = url;
              launchedMode = mode;
              return true;
            };

        await tester.pumpWidget(
          MaterialApp(home: LocationViewPage(meetup: _meetup())),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('GET DIRECTIONS'));
        await tester.pumpAndSettle();

        // Reset before the test body returns — the framework asserts every
        // debug var is back to its default as soon as the body completes,
        // before any addTearDown callback would run.
        debugDefaultTargetPlatformOverride = null;

        expect(launchedMode, LaunchMode.externalApplication);
        expect(launchedUri, isNotNull);
        expect(launchedUri!.scheme, 'https');
        expect(launchedUri!.host, 'maps.apple.com');
        expect(launchedUri!.queryParameters['daddr'], '6.9271,79.8612');
      },
    );
  });
}
