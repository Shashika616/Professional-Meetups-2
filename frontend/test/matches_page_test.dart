import 'dart:async' show Completer;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/features/matches/matches_page.dart';
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_auth_service.dart';
import 'support/fake_geolocator_platform.dart';
import 'support/scripted_meetup_service.dart';

/// Resolves immediately to a fixed [AuthSessionState] instead of reading
/// secure storage — same pattern as HomePage's/ScheduleFlowPage's own test
/// files (each defines this locally rather than sharing one, per this
/// suite's existing convention).
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

Meetup _meetup({
  String id = 'meetup-1',
  int acceptedCount = 0,
  int capacity = 4,
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
  MeetupStatus status = MeetupStatus.open,
  // ADR-028 — server-authoritative; defaults false (unlocked), same as a
  // real ListOpenMeetups response for a viewer who meets the bar.
  bool lockedForViewer = false,
}) => Meetup(
  id: id,
  hostUserId: 'host-1',
  hostFullName: lockedForViewer ? null : 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: lockedForViewer
      ? null
      : DateTime.now().add(const Duration(hours: 1)),
  windowEnd: lockedForViewer
      ? null
      : DateTime.now().add(const Duration(hours: 3)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: lockedForViewer ? null : 'Colombo Fort Cafe',
  capacity: capacity,
  acceptedCount: acceptedCount,
  status: status,
  createdAt: DateTime.now(),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
  lockedForViewer: lockedForViewer,
);

/// Wraps [MatchesPage] with the given meetup service and an
/// authSessionProvider fixed at [trustLevel] — coffee (this file's default
/// test intent) requires trust level 2, so most tests pass `trustLevel: 2`
/// to exercise the unlocked path; the dedicated Level 0 group below passes
/// 0 deliberately (ADR-014's Level 0 read-only audit, Step 6).
Widget _appWith(
  MeetupService service, {
  required int trustLevel,
  ImmediateAuthService? authService,
}) {
  return ProviderScope(
    overrides: [
      meetupServiceProvider.overrideWithValue(service),
      // MatchesPage's on-demand location read (ADR-021 §2) fires a
      // fire-and-forget authServiceProvider.updateLastKnownLocation() call
      // on every successful read — ImmediateAuthService (not
      // MockAuthService, whose deliberate 600ms latency is a pending-Timer
      // trap here, same reasoning as ImmediateMeetupService) so every test
      // below gets a safe no-op without each needing its own fake; tests
      // that need to assert on the call itself pass their own instance.
      authServiceProvider.overrideWithValue(
        authService ?? ImmediateAuthService(),
      ),
      authSessionProvider.overrideWith(
        () => _FakeAuthSessionNotifier(
          AuthSessionState(
            profile: UserProfile(
              id: 'user-1',
              fullName: 'Grace',
              trustLevel: trustLevel,
            ),
          ),
        ),
      ),
    ],
    child: const MaterialApp(home: MatchesPage()),
  );
}

void main() {
  setUp(() {
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      position: testPosition(),
    );
  });

  testWidgets('renders real Meetup data from openMeetupsProvider', (
    tester,
  ) async {
    final service = ScriptedMeetupService(
      openMeetups: [_meetup(acceptedCount: 1, capacity: 4)],
    );

    await tester.pumpWidget(_appWith(service, trustLevel: 2));
    await tester.pumpAndSettle();

    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(find.text('Colombo Fort Cafe'), findsOneWidget);
    expect(find.text('1/4 JOINED'), findsOneWidget);
    expect(find.text('REQUEST TO JOIN'), findsOneWidget);
  });

  testWidgets(
    'tapping REQUEST TO JOIN calls requestToJoin with the meetup id',
    (tester) async {
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-42')],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      await tester.tap(find.text('REQUEST TO JOIN'));
      await tester.pumpAndSettle();

      expect(service.lastRequestToJoinMeetupId, 'meetup-42');
      expect(find.text('Request sent.'), findsOneWidget);
    },
  );

  testWidgets('a full meetup shows FULL instead of an enabled request button', (
    tester,
  ) async {
    final service = ScriptedMeetupService(
      openMeetups: [_meetup(acceptedCount: 4, capacity: 4)],
    );

    await tester.pumpWidget(_appWith(service, trustLevel: 2));
    await tester.pumpAndSettle();

    expect(find.text('FULL'), findsOneWidget);
    expect(find.text('REQUEST TO JOIN'), findsNothing);
  });

  testWidgets('the browse card shows the meetup\'s own lifecycle status badge, '
      'additively alongside the JOINED count (ADR-016 addendum, 2026-08-20)', (
    tester,
  ) async {
    final service = ScriptedMeetupService(
      openMeetups: [_meetup(status: MeetupStatus.full)],
    );

    await tester.pumpWidget(_appWith(service, trustLevel: 2));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MeetupStatusBadge>(find.byType(MeetupStatusBadge)).status,
      MeetupStatus.full,
    );
  });

  testWidgets('an empty list shows the empty-state message, not a spinner', (
    tester,
  ) async {
    final service = ScriptedMeetupService(openMeetups: const []);

    await tester.pumpWidget(_appWith(service, trustLevel: 2));
    await tester.pumpAndSettle();

    expect(
      find.text('No open meetups nearby for this intent yet.'),
      findsOneWidget,
    );
  });

  testWidgets('no longer has an AppBar "+" — hosting moved to a separate entry '
      'point on HomePage so browsing and hosting aren\'t mixed on one page', (
    tester,
  ) async {
    final service = ScriptedMeetupService(openMeetups: const []);

    await tester.pumpWidget(_appWith(service, trustLevel: 2));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.add_circle_outline), findsNothing);
  });

  testWidgets(
    'intent tabs switch selectedIntentProvider without leaving the page',
    (tester) async {
      final service = ScriptedMeetupService(openMeetups: const []);
      late final ProviderContainer container;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meetupServiceProvider.overrideWithValue(service),
            authServiceProvider.overrideWithValue(ImmediateAuthService()),
            authSessionProvider.overrideWith(
              () => _FakeAuthSessionNotifier(
                const AuthSessionState(
                  profile: UserProfile(
                    id: 'user-1',
                    fullName: 'Grace',
                    trustLevel: 2,
                  ),
                ),
              ),
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: MatchesPage());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(selectedIntentProvider), IntentType.coffee);
      expect(find.text('NETWORKING'), findsOneWidget);

      await tester.tap(find.text('NETWORKING'));
      await tester.pumpAndSettle();

      expect(container.read(selectedIntentProvider), IntentType.networking);
    },
  );

  group('Level 0 read-only audit (ADR-014)', () {
    testWidgets(
      'browsing still works at Level 0 — an unlocked meetup (real backend '
      'data, since Level 0 already meets an under-2 intent... n/a here, '
      'this exercises the read-only-browse guarantee itself) still renders',
      (tester) async {
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(acceptedCount: 1, capacity: 4)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        // Browsing itself is never trust-gated (ADR-013 § 2) — a meetup
        // the server chose not to lock (lockedForViewer: false, the
        // default) renders in full regardless of the viewer's own level.
        expect(find.text('Grace Hopper'), findsOneWidget);
        expect(find.text('Colombo Fort Cafe'), findsOneWidget);
        expect(find.text('1/4 JOINED'), findsOneWidget);
      },
    );
  });

  group(
    'ADR-028 trust-gated visibility — server-authoritative locked_for_viewer',
    () {
      testWidgets(
        'a locked meetup card shows the blur/lock treatment, not real host '
        'data — never-redacted fields (intent, count, status) still show',
        (tester) async {
          final service = ScriptedMeetupService(
            openMeetups: [
              _meetup(acceptedCount: 1, capacity: 4, lockedForViewer: true),
            ],
          );

          await tester.pumpWidget(_appWith(service, trustLevel: 0));
          await tester.pumpAndSettle();

          expect(find.text('Grace Hopper'), findsNothing);
          expect(find.text('Colombo Fort Cafe'), findsNothing);
          expect(find.text('Verify to see details'), findsOneWidget);
          expect(find.text('1/4 JOINED'), findsOneWidget);
        },
      );

      testWidgets(
        'the join button on a locked card is enabled (ADR-028 drops the '
        'disabled-button pattern), not a dead end',
        (tester) async {
          final service = ScriptedMeetupService(
            openMeetups: [_meetup(lockedForViewer: true)],
          );

          await tester.pumpWidget(_appWith(service, trustLevel: 0));
          await tester.pumpAndSettle();

          final button = tester.widget<PrimaryButton>(
            find.widgetWithText(PrimaryButton, 'REQUEST TO JOIN'),
          );
          expect(button.onPressed, isNotNull);
        },
      );

      testWidgets(
        'tapping a locked card\'s join button shows a toast and pushes '
        'VerificationChecklistPage — never reaches requestToJoin, never '
        'opens the meetup detail page',
        (tester) async {
          final service = ScriptedMeetupService(
            openMeetups: [_meetup(id: 'meetup-99', lockedForViewer: true)],
          );

          await tester.pumpWidget(_appWith(service, trustLevel: 0));
          await tester.pumpAndSettle();

          await tester.tap(find.text('REQUEST TO JOIN'));
          await tester.pumpAndSettle();

          expect(service.lastRequestToJoinMeetupId, isNull);
          expect(find.byType(VerificationChecklistPage), findsOneWidget);
          expect(find.textContaining('requires Level 2 trust'), findsOneWidget);
        },
      );

      testWidgets(
        'tapping a locked card itself (not just its join button) shows the '
        'same toast-and-redirect, never the meetup detail page',
        (tester) async {
          final service = ScriptedMeetupService(
            openMeetups: [_meetup(id: 'meetup-77', lockedForViewer: true)],
          );

          await tester.pumpWidget(_appWith(service, trustLevel: 0));
          await tester.pumpAndSettle();

          // Tap the card's own FlatCard container, not the button text —
          // find the lock icon that only the locked header renders.
          await tester.tap(find.byIcon(Icons.lock_outline_rounded).first);
          await tester.pumpAndSettle();

          expect(find.byType(VerificationChecklistPage), findsOneWidget);
        },
      );

      testWidgets('an unlocked meetup card behaves exactly as before ADR-028 — '
          'regression guard', (tester) async {
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-42')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(find.text('Grace Hopper'), findsOneWidget);
        expect(find.text('Colombo Fort Cafe'), findsOneWidget);
        expect(find.text('Verify to see details'), findsNothing);

        await tester.tap(find.text('REQUEST TO JOIN'));
        await tester.pumpAndSettle();

        expect(service.lastRequestToJoinMeetupId, 'meetup-42');
        expect(find.byType(VerificationChecklistPage), findsNothing);
      });
    },
  );

  group('cursor pagination (2026-08-31 round-3 hardening, Fix 1)', () {
    testWidgets(
      'scrolling near the bottom with hasMore=true requests the next page '
      'via the returned cursor and appends its items',
      (tester) async {
        final firstPage = List.generate(10, (i) => _meetup(id: 'meetup-$i'));
        final service = ScriptedMeetupService(
          openMeetups: firstPage,
          openMeetupsNextCursor: 'cursor-1',
          openMeetupsHasMore: true,
          openMeetupsPage2: [
            _meetup(id: 'meetup-page-2', acceptedCount: 2, capacity: 5),
          ],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(service.listOpenMeetupsCallCount, 1);
        expect(find.text('2/5 JOINED'), findsNothing);

        // Drag the list far enough to reach its scroll extent, then let
        // the in-flight next-page fetch resolve.
        await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
        await tester.pumpAndSettle();

        expect(service.listOpenMeetupsCallCount, 2);
        expect(service.listOpenMeetupsCursors, [null, 'cursor-1']);
        expect(find.text('2/5 JOINED'), findsOneWidget);
      },
    );

    testWidgets('scrolling near the bottom with hasMore=false does not request '
        'another page', (tester) async {
      final firstPage = List.generate(10, (i) => _meetup(id: 'meetup-$i'));
      final service = ScriptedMeetupService(openMeetups: firstPage);

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(service.listOpenMeetupsCallCount, 1);

      await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(service.listOpenMeetupsCallCount, 1);
    });

    testWidgets(
      'switching intent while a second page is still loading does not '
      'leak stale page-2 items into the new intent\'s list '
      '(2026-08-31 round-5 hardening — actually added this time, not '
      'just claimed)',
      (tester) async {
        final firstPage = List.generate(10, (i) => _meetup(id: 'meetup-$i'));
        final gate = Completer<void>();
        final service = ScriptedMeetupService(
          openMeetups: firstPage,
          openMeetupsNextCursor: 'cursor-1',
          openMeetupsHasMore: true,
          openMeetupsPage2: [
            _meetup(id: 'meetup-page-2', acceptedCount: 2, capacity: 5),
          ],
          openMeetupsPage2Gate: gate.future,
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        // Trigger the page-2 fetch — it's now in flight, blocked on
        // `gate`, which we control deliberately instead of racing a real
        // delay against pumpAndSettle.
        await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
        await tester.pump();

        // Switch intent before the in-flight fetch resolves — this tears
        // down the old `_MeetupList`/State entirely (a fresh
        // `_MeetupsSkeleton()` mounts first, per the corrected
        // `didUpdateWidget` comment) and mounts a brand-new one for the
        // new intent.
        await tester.tap(find.text('NETWORKING'));
        await tester.pumpAndSettle();

        expect(find.text('2/5 JOINED'), findsNothing);

        // Now let the stale fetch actually resolve — its own `mounted`
        // guard must make this a no-op against the disposed old widget,
        // not something that reaches into the new intent's list.
        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('2/5 JOINED'), findsNothing);
      },
    );

    testWidgets(
      'a listOpenMeetups failure during scroll-triggered pagination is '
      'silently swallowed — the current page stays visible and the '
      '_loadingMore flag actually clears, proven by a later scroll being '
      'allowed to retry rather than blocked (2026-08-31 round-5 hardening '
      '— actually added this time, not just claimed)',
      (tester) async {
        final firstPage = List.generate(10, (i) => _meetup(id: 'meetup-$i'));
        final service = ScriptedMeetupService(
          openMeetups: firstPage,
          openMeetupsNextCursor: 'cursor-1',
          openMeetupsHasMore: true,
          openMeetupsPage2Error: Exception('network error'),
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
        // Not pumpAndSettle: `hasMore` deliberately stays true after a
        // failed fetch (this round doesn't change that, only tests it),
        // and the footer's indeterminate CircularProgressIndicator (shown
        // whenever hasMore is true, regardless of whether a fetch is
        // actually in flight) never settles on its own — a few explicit
        // pumps are enough for the caught error's setState to land. Since
        // `hasMore` never flips false on failure (unlike the success
        // path), a single `drag()`'s own internal sequence of incremental
        // pointer-move events can retrigger the listener — and, because
        // this fake fails near-instantly with no delay, more than once
        // before the drag gesture finishes — so the exact count isn't
        // pinned to 2 here, only that at least one attempt happened.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final countAfterFirstDrag = service.listOpenMeetupsCallCount;
        expect(
          countAfterFirstDrag,
          greaterThanOrEqualTo(2),
          reason: 'at least the initial page-2 attempt should have fired',
        );
        // The original page is still rendered, not blanked or crashed by
        // the failed page-2 fetch(es) (ListView.builder virtualizes
        // offscreen items, so this checks presence, not the exact visible
        // count).
        expect(find.text('Grace Hopper'), findsWidgets);

        // Scroll up, then back down near the bottom again — a repeat drag
        // to an unchanged scroll position wouldn't re-fire the listener at
        // all, so this genuinely re-triggers `_maybeLoadNextPage` after
        // things have settled. If `_loadingMore` were still (incorrectly)
        // stuck true from an earlier failed attempt, this whole retry
        // would be silently blocked and the count would stop moving.
        await tester.drag(find.byType(ListView).last, const Offset(0, 200));
        await tester.pump();
        await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          service.listOpenMeetupsCallCount,
          greaterThan(countAfterFirstDrag),
          reason:
              'a later scroll must still be able to retry — _loadingMore '
              'must not be left permanently stuck true by a failed fetch',
        );
      },
    );
  });

  group('40km geo-visibility (ADR-021, frontend/geo-visibility-PLAN.md)', () {
    testWidgets(
      'a successful location read passes those exact coordinates into '
      'listOpenMeetups',
      (tester) async {
        final service = ScriptedMeetupService(openMeetups: const []);
        GeolocatorPlatform.instance = FakeGeolocatorPlatform(
          position: testPosition(lat: 6.9271, lng: 79.8612),
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(service.lastListOpenMeetupsViewerLat, 6.9271);
        expect(service.lastListOpenMeetupsViewerLng, 79.8612);
      },
    );

    testWidgets('updateLastKnownLocation is called exactly once per successful '
        'location read, not on every rebuild', (tester) async {
      final service = ScriptedMeetupService(openMeetups: const []);
      final auth = ImmediateAuthService();
      GeolocatorPlatform.instance = FakeGeolocatorPlatform(
        position: testPosition(lat: 6.9271, lng: 79.8612),
      );

      await tester.pumpWidget(
        _appWith(service, trustLevel: 2, authService: auth),
      );
      await tester.pumpAndSettle();
      // A rebuild (switching the browsed intent) must not re-trigger a
      // fresh location read/update — only page open and explicit
      // pull-to-refresh do (Step 2 of the plan).
      await tester.tap(find.text('NETWORKING'));
      await tester.pumpAndSettle();

      expect(auth.updateLastKnownLocationCallCount, 1);
      expect(auth.lastUpdateLastKnownLocationLat, 6.9271);
      expect(auth.lastUpdateLastKnownLocationLng, 79.8612);
    });

    testWidgets(
      'permission denied shows the blur+prompt state, not an unfiltered '
      'or silently empty list',
      (tester) async {
        final service = ScriptedMeetupService(openMeetups: [_meetup()]);
        GeolocatorPlatform.instance = FakeGeolocatorPlatform(
          serviceEnabled: true,
          permission: LocationPermission.deniedForever,
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(
          find.text('Turn on location to see meetups near you'),
          findsOneWidget,
        );
        // The blocked state never even calls listOpenMeetups — no
        // unfiltered fallback, no silent empty list (ADR-021 §3).
        expect(service.listOpenMeetupsCallCount, 0);
        expect(find.text('Grace Hopper'), findsNothing);
      },
    );

    testWidgets(
      'location services disabled also shows the blocked state, with the '
      'matching settings action',
      (tester) async {
        final service = ScriptedMeetupService(openMeetups: const []);
        GeolocatorPlatform.instance = FakeGeolocatorPlatform(
          serviceEnabled: false,
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(
          find.text('Turn on location to see meetups near you'),
          findsOneWidget,
        );
        expect(find.text('OPEN LOCATION SETTINGS'), findsOneWidget);
      },
    );
  });

  group('View Location (ADR-029, round-8 hardening)', () {
    tearDown(() => debugLaunchUrlOverride = null);

    testWidgets('a locked meetup\'s VIEW LOCATION shows a toast and pushes '
        'VerificationChecklistPage — never opens LocationViewPage', (
      tester,
    ) async {
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-99', lockedForViewer: true)],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 0));
      await tester.pumpAndSettle();

      await tester.tap(find.text('VIEW LOCATION'));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      expect(find.byType(LocationViewPage), findsNothing);
      expect(find.textContaining('requires Level 2 trust'), findsOneWidget);
    });

    testWidgets(
      'an unlocked meetup\'s VIEW LOCATION opens LocationViewPage showing '
      'the meetup\'s real label',
      (tester) async {
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-42')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.tap(find.text('VIEW LOCATION'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsNothing);
        expect(find.text('Colombo Fort Cafe'), findsOneWidget);
      },
    );

    testWidgets(
      'GET DIRECTIONS deep-links to Google Maps directions on Android '
      '(and every non-iOS platform), not in-app routing',
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
      'GET DIRECTIONS deep-links to Apple Maps on iOS, not Google Maps — '
      'iOS already has its own map app, no reason to route through '
      'Google\'s',
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
        // debug var is back to its default as soon as the test body
        // completes, before any addTearDown callback would run (see
        // onboarding_flow_test.dart's matching comment on this same reset).
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
