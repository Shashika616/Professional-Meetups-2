import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';
import 'package:professional_connections_platform/features/home/widgets/happening_soon_section.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_filter_bar.dart';
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_auth_service.dart';
import 'support/fake_geolocator_platform.dart';
import 'support/scripted_meetup_service.dart';

/// # WHERE THIS FILE CAME FROM
///
/// `matches_page_test.dart`, deleted with the page it covered. Browsing open
/// meetups is now a SECTION on Home ([HappeningSoonSection]) rather than its
/// own tab, so every test here mounts [HomePage] and asserts on the browse
/// list inside it.
///
/// The behaviour under test is deliberately unchanged by that move — this
/// file is the proof of that, not a rewrite. The two exceptions, both called
/// out at their assertions:
///
///   * The intent selector is Home's [IntentFilterBar] (with an "All"
///     option) rather than the old page's own tab row, so the tests that
///     drove that row drive the chips instead.
///   * The list is nested inside Home's scrollable, so scroll-triggered
///     pagination is inert here by design. Those tests moved to
///     `paginated_meetup_list_test.dart`, which owns that machinery now.
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
  MeetupStatus status = MeetupStatus.open,
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
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
  // ADR-002 § 5: the guest tier KEEPS the location deliberately — seeing
  // that real meetups are happening nearby is the whole point of it — so a
  // locked response carries a real label. Carried over verbatim from the
  // deleted browse page's fixture; if this ever reverts to null for a
  // locked meetup, the redaction contract changed, not just the fixture.
  locationLabel: 'Colombo Fort Cafe',
  capacity: capacity,
  acceptedCount: acceptedCount,
  status: status,
  createdAt: DateTime.now(),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
  lockedForViewer: lockedForViewer,
);

/// Mounts [HomePage] with the given meetup service and a session fixed at
/// [trustLevel].
///
/// Coffee (this file's fixture intent) needs Level 2 to join, so most tests
/// pass `trustLevel: 2` for the unlocked path; the guest group passes 0.
Widget _appWith(
  MeetupService service, {
  required int trustLevel,
  ImmediateAuthService? authService,
}) {
  return ProviderScope(
    overrides: [
      meetupServiceProvider.overrideWithValue(service),
      // HappeningSoonSection's on-demand location read (ADR-021 §2) fires a
      // fire-and-forget authServiceProvider.updateLastKnownLocation() on
      // every successful read — ImmediateAuthService rather than
      // MockAuthService, whose deliberate 600ms latency is a pending-Timer
      // trap here.
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
    child: const MaterialApp(home: HomePage()),
  );
}

/// Home stacks a header, a filter row, the active-meetups section and the
/// browse list in one scrollable. At the 800x600 default the browse list
/// falls outside the viewport AND the sliver cache extent, so its cards are
/// never built and `find.text` reports nothing — which would make every
/// assertion below pass or fail for the wrong reason. A tall viewport puts
/// the whole page on screen instead of scattering `drag()` calls through
/// tests that are not about scrolling.
/// Enough frames for the location read, the provider fetch and the
/// resulting rebuild to land, for the tests that cannot use pumpAndSettle.
Future<void> _pumpAFew(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      position: testPosition(),
    );
  });

  group('guest tier — the locked-card treatment survived the widget move '
      '(ADR-002 § 6, ADR-028)', () {
    testWidgets(
      'a locked meetup card in Happening Soon shows the blur/lock treatment, '
      'not real host data — and still shows the location, which the guest '
      'tier deliberately keeps',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [
            _meetup(acceptedCount: 1, capacity: 4, lockedForViewer: true),
          ],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        // Redacted: host identity and the exact time window.
        expect(find.text('Grace Hopper'), findsNothing);
        // Kept: the location label (ADR-002 § 5) and the never-redacted
        // fields (intent, joined count).
        expect(find.text('Colombo Fort Cafe'), findsOneWidget);
        expect(find.text('Sign up to see who\'s hosting'), findsOneWidget);
        expect(find.text('1/4 JOINED'), findsOneWidget);
      },
    );

    testWidgets(
      'the join button on a locked card is enabled (ADR-028 drops the '
      'disabled-button pattern), not a dead end',
      (tester) async {
        _useTallViewport(tester);
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

    testWidgets('tapping a locked card\'s join button shows a toast and pushes '
        'VerificationChecklistPage — never reaches requestToJoin, never '
        'opens the meetup detail page', (tester) async {
      _useTallViewport(tester);
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
    });

    testWidgets(
      'tapping a locked card itself (not just its join button) shows the '
      'same toast-and-redirect, never the meetup detail page',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-77', lockedForViewer: true)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        // Tap the card's own container, not the button text — find the lock
        // icon that only the locked header renders.
        await tester.tap(find.byIcon(Icons.lock_outline_rounded).first);
        await tester.pumpAndSettle();

        expect(find.byType(VerificationChecklistPage), findsOneWidget);
      },
    );

    testWidgets('an unlocked meetup card behaves exactly as before — the '
        'control run for the group above', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-42')],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('Colombo Fort Cafe'), findsOneWidget);
      expect(find.text('Sign up to see who\'s hosting'), findsNothing);

      await tester.tap(find.text('REQUEST TO JOIN'));
      await tester.pumpAndSettle();

      expect(service.lastRequestToJoinMeetupId, 'meetup-42');
      expect(find.byType(VerificationChecklistPage), findsNothing);
    });
  });

  group('the browse list itself', () {
    testWidgets('renders real Meetup data from openMeetupsProvider', (
      tester,
    ) async {
      _useTallViewport(tester);
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
        _useTallViewport(tester);
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

    testWidgets(
      'a full meetup shows FULL instead of an enabled request button',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(acceptedCount: 4, capacity: 4)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(find.text('FULL'), findsOneWidget);
        expect(find.text('REQUEST TO JOIN'), findsNothing);
      },
    );

    testWidgets(
      'the browse card shows the meetup\'s own lifecycle status badge, '
      'additively alongside the JOINED count (ADR-016 addendum)',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(status: MeetupStatus.full)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<MeetupStatusBadge>(
                find.descendant(
                  of: find.byType(HappeningSoonSection),
                  matching: find.byType(MeetupStatusBadge),
                ),
              )
              .status,
          MeetupStatus.full,
        );
      },
    );

    testWidgets(
      'a successful fetch that returns nothing shows the invitation, NOT '
      'the failure state — an empty area is a normal outcome, and telling '
      'the user their connection is broken over it is a lie',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(find.text('No meetups near you this week'), findsOneWidget);
        expect(find.byIcon(Icons.groups_2_outlined), findsOneWidget);
        expect(
          find.textContaining('Be the first to put one on the calendar'),
          findsOneWidget,
        );

        // None of the failure affordances.
        expect(find.text('RETRY'), findsNothing);
        expect(find.byIcon(Icons.wifi_off_outlined), findsNothing);
        expect(find.textContaining('Could not load'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('the empty-state copy names the selected intent, so "no coffee '
        'meetups" is not mistaken for "no meetups at all"', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(openMeetups: const []);

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      await tester.tap(find.text(IntentType.networking.label));
      await tester.pumpAndSettle();

      expect(
        find.text('No networking meetups near you this week'),
        findsOneWidget,
      );
    });
  });

  /// # THE POINT OF THIS GROUP
  ///
  /// The failure card used to say "Could not load meetups near you" for
  /// EVERY error, and the empty list showed a bare sentence. So a user in a
  /// quiet area and a user whose server returned a 500 were both told,
  /// implicitly, to go check their wifi. These tests pin the three outcomes
  /// apart: offline, server-side failure, and simply nothing scheduled.
  group('failure vs. emptiness are different states', () {
    testWidgets('a genuine connectivity failure gets the offline copy and the '
        'offline icon', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetupsError: const MeetupOfflineException(),
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('You\'re offline'), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off_outlined), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);
    });

    testWidgets(
      'a SERVER-side failure does not blame the user\'s network — it reached '
      'the server, so telling them to check their connection would send '
      'them to restart a router over our bug',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetupsError: const MeetupNetworkException('boom'),
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(find.text('Could not load meetups right now'), findsOneWidget);
        expect(find.textContaining('on us, not you'), findsOneWidget);
        expect(find.byIcon(Icons.wifi_off_outlined), findsNothing);
        expect(find.textContaining('Check your connection'), findsNothing);
        expect(find.text('RETRY'), findsOneWidget);
      },
    );

    testWidgets(
      'RETRY on the failure card refetches rather than only redrawing',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetupsError: const MeetupOfflineException(),
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        final before = service.listOpenMeetupsCallCount;
        expect(before, greaterThanOrEqualTo(1));

        await tester.tap(find.text('RETRY'));
        await tester.pumpAndSettle();

        // Not pinned to an exact count: Riverpod retries a failed provider
        // on its own schedule, so background attempts land in here too. What
        // this test owns is that the BUTTON causes a fetch — which a
        // strictly-greater count proves regardless of how many retries the
        // framework fired alongside it.
        expect(
          service.listOpenMeetupsCallCount,
          greaterThan(before),
          reason: 'RETRY must refetch, not only redraw the card',
        );
      },
    );

    testWidgets(
      'an unexpected error type still shows the neutral failure copy, not a '
      'raw exception — the offline branch is opt-in, never the default',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetupsError: StateError('internal detail 12345'),
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(find.text('Could not load meetups right now'), findsOneWidget);
        expect(find.textContaining('12345'), findsNothing);
      },
    );
  });

  group('the Happening Soon query (§B\'s new backend filters)', () {
    testWidgets(
      'the default "All" filter asks for every intent — a nil intent, which '
      'is a distinct backend query, not six client-side unions',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        expect(service.listOpenMeetupsCallCount, 1);
        expect(service.lastListOpenMeetupsIntent, isNull);
        expect(service.lastListOpenMeetupsWithinDays, happeningSoonWithinDays);
      },
    );

    testWidgets(
      'selecting an intent chip re-queries with that intent, still bounded '
      'to the Happening Soon window',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.tap(find.text(IntentType.networking.label));
        await tester.pumpAndSettle();

        expect(service.lastListOpenMeetupsIntent, IntentType.networking);
        expect(service.lastListOpenMeetupsWithinDays, happeningSoonWithinDays);
        expect(service.listOpenMeetupsCallCount, 2);
      },
    );

    testWidgets(
      'tapping an intent the viewer cannot JOIN does not change the filter — '
      'it explains the gate instead, and the list keeps showing what it had',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);

        // Level 0: coffee needs Level 2 to join.
        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        expect(service.listOpenMeetupsCallCount, 1);

        await tester.tap(find.text(IntentType.coffee.label));
        await tester.pumpAndSettle();

        expect(find.textContaining('requires Level 2 trust'), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsOneWidget);
        // No new query fired — the filter never moved off "All".
        expect(service.listOpenMeetupsCallCount, 1);
        expect(service.lastListOpenMeetupsIntent, isNull);
      },
    );
  });

  group(
    '40km geo-visibility (ADR-021) — carried over from the browse page',
    () {
      testWidgets(
        'a successful location read passes those exact coordinates into '
        'listOpenMeetups',
        (tester) async {
          _useTallViewport(tester);
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

      testWidgets(
        'updateLastKnownLocation is called exactly once per successful '
        'location read, not on every rebuild',
        (tester) async {
          _useTallViewport(tester);
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
          // fresh location read/update — only mount and explicit
          // pull-to-refresh do.
          await tester.tap(find.text(IntentType.networking.label));
          await tester.pumpAndSettle();

          expect(auth.updateLastKnownLocationCallCount, 1);
          expect(auth.lastUpdateLastKnownLocationLat, 6.9271);
          expect(auth.lastUpdateLastKnownLocationLng, 79.8612);
        },
      );

      testWidgets(
        'permission denied blocks THIS SECTION with a real prompt, not an '
        'unfiltered or silently empty list — and the rest of Home still works',
        (tester) async {
          _useTallViewport(tester);
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
          // CHANGED BY THE RESTRUCTURE: browsing used to be a whole page, so
          // a location block took the whole page with it. It is a section on
          // Home now, and blocking it must not block Home's own controls.
          expect(find.byKey(const Key('hostYourOwnMeetup')), findsOneWidget);
        },
      );

      testWidgets(
        'location services disabled also shows the blocked state, with the '
        'matching settings action',
        (tester) async {
          _useTallViewport(tester);
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
    },
  );

  group('View Location from a browse card (ADR-029, ADR-002 § 5)', () {
    testWidgets(
      'a Level 1+ viewer\'s VIEW LOCATION opens LocationViewPage showing the '
      'meetup\'s real label',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-42')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.tap(find.text('VIEW LOCATION'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsNothing);
      },
    );

    testWidgets(
      'a guest\'s VIEW LOCATION is gated — the card\'s coarse label is '
      'ADR-002 § 5\'s guest tier, the exact-coordinate map page is not',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-99', lockedForViewer: true)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        await tester.tap(find.text('VIEW LOCATION'));
        await tester.pumpAndSettle();

        expect(find.byType(LocationViewPage), findsNothing);
        expect(find.byType(VerificationChecklistPage), findsOneWidget);
      },
    );
  });

  /// The role pills come from `isHostedByMe`/`myRequestStatus`, which every
  /// `ListOpenMeetups` row already carries — §B added a WHERE clause and
  /// deliberately left those fields alone, so a browse card that showed
  /// them before must still show them now.
  group('hosted-by-you / requested badges on the browse card', () {
    testWidgets('a meetup the viewer hosts shows YOU\'RE HOSTING instead of '
        'a join button', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(isHostedByMe: true)],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('YOU\'RE HOSTING'), findsOneWidget);
      expect(find.text('REQUEST TO JOIN'), findsNothing);
    });

    testWidgets('a meetup the viewer already requested shows its request '
        'status instead of a join button', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(myRequestStatus: MeetupRequestStatus.pending)],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('REQUEST PENDING'), findsOneWidget);
      expect(find.text('REQUEST TO JOIN'), findsNothing);
    });

    testWidgets('an accepted request shows YOU\'RE IN', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(myRequestStatus: MeetupRequestStatus.accepted)],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('YOU\'RE IN'), findsOneWidget);
    });
  });

  /// # THE TEST THIS FILE SHOULD HAVE HAD
  ///
  /// The previous version of this group drove `loadNextPageForTest()`, the
  /// escape hatch. It proved `loadMore` reaches the service with the right
  /// arguments — which was true — and proved nothing about whether anything
  /// ever calls it. Nothing did: the nested list watched a ScrollController
  /// that, in shrink-wrap mode, was attached to no scrollable, and Home had
  /// no controller to hand it. Home's browse list was capped at page one,
  /// silently (docs/plans/07-happening-soon-pagination-fix.md).
  ///
  /// So this drives the REAL page: it scrolls Home's own ListView, the thing
  /// a user's thumb moves, and never touches the escape hatch.
  group('Happening Soon pagination, driven by scrolling Home itself', () {
    /// The DEFAULT viewport, deliberately — not `_useTallViewport`. A tall
    /// viewport fits the whole page on screen, leaving Home's ListView no
    /// scroll extent at all, which would make a scroll test vacuous.
    Future<void> pumpHome(WidgetTester tester, MeetupService service) async {
      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      // Not pumpAndSettle: `hasMore` is true throughout, and the list's
      // footer spinner never settles on its own.
      await _pumpAFew(tester);
    }

    /// Home's own outer ListView — first in tree order, ahead of the intent
    /// filter row's horizontal list and the nested browse list.
    Finder homeList() => find.byType(ListView).first;

    /// Scrolls Home the way a thumb would. Repeated drags rather than one
    /// huge fling: the section is laid out lazily, so it has to be scrolled
    /// into existence before the scroll that crosses its threshold can
    /// matter — the same sequence a real device produces.
    Future<void> scrollHomeToBottom(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.drag(homeList(), const Offset(0, -400));
        await tester.pump();
      }
      await _pumpAFew(tester);
    }

    testWidgets(
      'scrolling Home to the bottom loads the next page of nearby meetups, '
      'with the same intent, window and cursor the first page used',
      (tester) async {
        final service = ScriptedMeetupService(
          // Enough rows that the page is genuinely taller than the viewport.
          openMeetups: List.generate(6, (i) => _meetup(id: 'meetup-$i')),
          openMeetupsNextCursor: 'cursor-1',
          openMeetupsHasMore: true,
          openMeetupsPage2: [
            _meetup(id: 'meetup-page-2', acceptedCount: 2, capacity: 5),
          ],
        );

        await pumpHome(tester, service);
        expect(
          service.listOpenMeetupsCallCount,
          1,
          reason: 'only the first page before any scrolling',
        );

        await scrollHomeToBottom(tester);

        expect(
          service.listOpenMeetupsCallCount,
          greaterThan(1),
          reason:
              'scrolling Home past the near-bottom threshold must fetch the '
              'next page — this is the trigger that was dead',
        );
        expect(service.listOpenMeetupsCursors.last, 'cursor-1');
        expect(service.lastListOpenMeetupsIntent, isNull);
        expect(service.lastListOpenMeetupsWithinDays, happeningSoonWithinDays);
        expect(service.lastListOpenMeetupsViewerLat, 6.9271);
        expect(find.text('2/5 JOINED'), findsOneWidget);
      },
    );

    testWidgets(
      'the next page keeps the SELECTED intent — a filtered list must not '
      'silently widen to every intent when it pages',
      (tester) async {
        final service = ScriptedMeetupService(
          openMeetups: List.generate(6, (i) => _meetup(id: 'meetup-$i')),
          openMeetupsNextCursor: 'cursor-1',
          openMeetupsHasMore: true,
          openMeetupsPage2: [
            _meetup(id: 'meetup-page-2', acceptedCount: 2, capacity: 5),
          ],
        );

        await pumpHome(tester, service);
        await tester.tap(find.text(IntentType.networking.label));
        await _pumpAFew(tester);

        await scrollHomeToBottom(tester);

        expect(service.listOpenMeetupsCursors.last, 'cursor-1');
        expect(service.lastListOpenMeetupsIntent, IntentType.networking);
        expect(service.lastListOpenMeetupsWithinDays, happeningSoonWithinDays);
      },
    );

    testWidgets(
      'a list with no further pages fetches nothing however far Home is '
      'scrolled — hasMore is still respected through the new path',
      (tester) async {
        final service = ScriptedMeetupService(
          openMeetups: List.generate(6, (i) => _meetup(id: 'meetup-$i')),
        );

        await pumpHome(tester, service);
        expect(service.listOpenMeetupsCallCount, 1);

        await scrollHomeToBottom(tester);

        expect(service.listOpenMeetupsCallCount, 1);
      },
    );
  });

  /// # WEEK GROUPING
  ///
  /// The window widened from 7 to 28 days at the same time, and the two are
  /// not independent: grouping a seven-day window into weeks yields exactly
  /// one group, which is not a grouping.
  group('weekly grouping', () {
    Meetup atDay(int daysFromNow, {String? id}) {
      final start = DateTime.now().add(Duration(days: daysFromNow));
      return Meetup(
        id: id ?? 'meetup-d$daysFromNow',
        hostUserId: 'host-1',
        hostFullName: 'Grace Hopper',
        hostTrustLevel: 3,
        intent: IntentType.coffee,
        windowStart: start,
        windowEnd: start.add(const Duration(hours: 2)),
        locationLat: 6.9271,
        locationLng: 79.8612,
        locationLabel: 'Colombo Fort Cafe',
        capacity: 4,
        acceptedCount: 0,
        status: MeetupStatus.open,
        createdAt: DateTime.now(),
      );
    }

    test('the window is wide enough for weeks to mean something', () {
      expect(
        happeningSoonWithinDays,
        greaterThan(7),
        reason: 'a 7-day window grouped by week is a single bucket',
      );
    });

    test('a week starts on Monday, normalised to midnight', () {
      // 10 Sep 2026 is a Thursday.
      final thursday = DateTime(2026, 9, 10, 19, 30);
      expect(startOfWeek(thursday), DateTime(2026, 9, 7));

      // Sunday belongs to the week that began the previous Monday, not the
      // next one — the usual off-by-one in Monday-based weeks.
      final sunday = DateTime(2026, 9, 13, 23, 0);
      expect(startOfWeek(sunday), DateTime(2026, 9, 7));
    });

    test('a new group starts only when the week changes', () {
      final mon = atDay(0, id: 'a');
      final sameWeek = Meetup(
        id: 'b',
        hostUserId: 'h',
        hostFullName: 'x',
        hostTrustLevel: 1,
        intent: IntentType.coffee,
        windowStart: mon.windowStart!.add(const Duration(hours: 3)),
        windowEnd: mon.windowEnd!.add(const Duration(hours: 3)),
        locationLat: 1,
        locationLng: 1,
        locationLabel: 'x',
        capacity: 2,
        acceptedCount: 0,
        status: MeetupStatus.open,
        createdAt: DateTime.now(),
      );

      expect(
        startsNewWeek(mon, null),
        isTrue,
        reason: 'the first card always opens a group',
      );
      expect(startsNewWeek(sameWeek, mon), isFalse);
      expect(startsNewWeek(atDay(14), mon), isTrue);
    });

    test('labels are relative for the weeks people plan around', () {
      final now = DateTime(2026, 9, 10); // a Thursday
      expect(weekLabelFor(atDay(0), now: now), 'THIS WEEK');

      String labelForWeeksAhead(int weeks) {
        final start = startOfWeek(now).add(Duration(days: 7 * weeks + 1));
        return weekLabelFor(
          Meetup(
            id: 'm',
            hostUserId: 'h',
            hostFullName: 'x',
            hostTrustLevel: 1,
            intent: IntentType.coffee,
            windowStart: start,
            windowEnd: start.add(const Duration(hours: 1)),
            locationLat: 1,
            locationLng: 1,
            locationLabel: 'x',
            capacity: 2,
            acceptedCount: 0,
            status: MeetupStatus.open,
            createdAt: now,
          ),
          now: now,
        );
      }

      expect(labelForWeeksAhead(1), 'NEXT WEEK');
      // Beyond that, a date beats arithmetic: "WEEK OF 21 SEP" is readable
      // where "IN 2 WEEKS" makes the reader compute.
      expect(labelForWeeksAhead(2), startsWith('WEEK OF '));
    });

    testWidgets('the list renders a header above each week, once', (
      tester,
    ) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [
          atDay(0, id: 'a'),
          atDay(1, id: 'b'),
          atDay(9, id: 'c'),
        ],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(
        find.text('NEXT WEEK'),
        findsOneWidget,
        reason: 'three meetups across two weeks means two headers, not three',
      );
    });

    testWidgets('a single week shows one header, not a header per card', (
      tester,
    ) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [
          atDay(0, id: 'a'),
          atDay(1, id: 'b'),
        ],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(find.text('NEXT WEEK'), findsNothing);
    });
  });

  /// The two facts that decide whether someone can come used to be the least
  /// legible things on the card: the time sat in a grey pill between the
  /// intent and the joined count, and the place was a caption under the
  /// host's name.
  group('card shows when and where clearly', () {
    testWidgets('the time and the place each get their own row', (
      tester,
    ) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(openMeetups: [_meetup()]);

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.event_outlined), findsWidgets);
      expect(find.byIcon(Icons.place_outlined), findsWidgets);
      expect(
        find.text('Colombo Fort Cafe'),
        findsOneWidget,
        reason: 'exactly once — it used to also sit under the host name',
      );
    });

    testWidgets(
      'a LOCKED card shows neither row — the time is redacted, and the '
      'location is already rendered by the locked header',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(lockedForViewer: true)],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 0));
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.event_outlined), findsNothing);
        expect(
          find.text('Colombo Fort Cafe'),
          findsOneWidget,
          reason: 'the guest tier keeps the location, but prints it once',
        );
      },
    );
  });

  /// The visible cue that a swap is underway.
  group('the loading cue while a filter is switching', () {
    testWidgets('the stale list dims, then comes back to full strength', (
      tester,
    ) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-1')],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      double opacity() => tester
          .widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(HappeningSoonSection),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;

      expect(opacity(), 1, reason: 'nothing is loading yet');

      await tester.tap(find.text(IntentType.networking.label));
      await tester.pump();

      expect(
        opacity(),
        lessThan(1),
        reason: 'the dim is what tells the user the tap registered',
      );

      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });

    testWidgets(
      'the stale list ignores taps — a request sent while rows are about to '
      'be replaced would go to the wrong meetup',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-1')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.tap(find.text(IntentType.networking.label));
        await tester.pump();

        // `.first` and an ancestor lookup: Flutter inserts IgnorePointers of
        // its own inside scrollables, so "any IgnorePointer in the section"
        // is ambiguous. The one wrapping the list is the one under test.
        final ignoring = tester
            .widgetList<IgnorePointer>(
              find.ancestor(
                of: find.byType(PaginatedMeetupList),
                matching: find.byType(IgnorePointer),
              ),
            )
            .any((w) => w.ignoring);
        expect(ignoring, isTrue);
      },
    );
  });

  /// # WHERE THE FILTER LIVES
  ///
  /// It used to sit at the top of Home, above ActiveMeetupsSection — which
  /// it does not filter. That read as a page-wide control and implied the
  /// active-meetups strip was being filtered too. It only ever narrowed this
  /// one list, so it belongs to this section.
  group('the intent filter belongs to this section', () {
    testWidgets('it renders inside HappeningSoonSection, not above it', (
      tester,
    ) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(openMeetups: const []);

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.byType(IntentFilterBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HappeningSoonSection),
          matching: find.byType(IntentFilterBar),
        ),
        findsOneWidget,
        reason: 'it filters this list, so it lives with this list',
      );
    });

    testWidgets(
      'it sits BELOW the section heading — the heading names what the chips '
      'narrow',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        final heading = tester.getTopLeft(find.text('HAPPENING SOON')).dy;
        final chips = tester.getTopLeft(find.byType(IntentFilterBar)).dy;
        expect(chips, greaterThan(heading));
      },
    );

    testWidgets(
      'it is still reachable when the location is blocked — a user who '
      'cannot load the list must still be able to change what it would show',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(openMeetups: const []);
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
        expect(
          find.byType(IntentFilterBar),
          findsOneWidget,
          reason:
              'rendering it only alongside a populated list would strand '
              'the user on whatever filter they last picked',
        );
      },
    );

    testWidgets('it is still reachable when the list is empty', (tester) async {
      _useTallViewport(tester);
      final service = ScriptedMeetupService(openMeetups: const []);

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      expect(find.text('No meetups near you this week'), findsOneWidget);
      expect(find.byType(IntentFilterBar), findsOneWidget);
    });
  });

  /// # TAPPING A FILTER MUST NOT MOVE THE PAGE
  ///
  /// Switching intent switches to a DIFFERENT `openMeetupsProvider` family
  /// key, which has no cached value — so the section collapsed to a
  /// placeholder (and, for the placeholder's first 180ms, to nothing at
  /// all). Home's content got shorter, the scroll position clamped to the
  /// new maxScrollExtent, and the page jumped upward under the user's thumb
  /// at the exact moment they were reading it.
  group('switching intent keeps the page still', () {
    testWidgets('the scroll position does not move when a chip is tapped', (
      tester,
    ) async {
      // Default viewport: a tall one leaves Home unscrollable, which would
      // make this assertion vacuous.
      final service = ScriptedMeetupService(
        openMeetups: List.generate(6, (i) => _meetup(id: 'meetup-$i')),
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      // Scroll down so there is somewhere to jump FROM.
      scrollable.position.jumpTo(120);
      await tester.pump();
      final before = scrollable.position.pixels;
      expect(before, 120);

      await tester.tap(find.text(IntentType.networking.label));
      // One frame — the collapse happened immediately on tap.
      await tester.pump();

      expect(
        scrollable.position.pixels,
        before,
        reason:
            'the list must not collapse while the new filter loads; the page '
            'jumping under the user is what that collapse looks like',
      );
    });

    testWidgets(
      'the previous results stay on screen while the new filter loads, '
      'rather than the section emptying out',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-1')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();
        expect(find.text('Grace Hopper'), findsOneWidget);

        await tester.tap(find.text(IntentType.networking.label));
        await tester.pump();

        expect(
          find.text('Grace Hopper'),
          findsOneWidget,
          reason:
              'holding the stale list is what keeps the height stable — and '
              'an empty section for a beat reads as "there is nothing" '
              'rather than "loading"',
        );
      },
    );
  });

  /// # WHAT A GENUINELY SLOW NETWORK LOOKS LIKE
  ///
  /// Holding the stale list is right for a swap that resolves in a moment.
  /// It is wrong for one that takes seconds: a permanently dimmed list stops
  /// reading as "loading" and starts reading as "broken". Past the
  /// threshold the section commits to a real skeleton.
  group('a slow filter swap falls back to a skeleton', () {
    testWidgets(
      'a FAST swap never shows a skeleton — swapping one in for two frames '
      'would be the flash the delay exists to prevent',
      (tester) async {
        _useTallViewport(tester);
        final service = ScriptedMeetupService(
          openMeetups: [_meetup(id: 'meetup-1')],
        );

        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        await tester.tap(find.text(IntentType.networking.label));
        await tester.pumpAndSettle();

        expect(find.byType(MeetupsSkeleton), findsNothing);
      },
    );

    testWidgets('a SLOW swap shows one once the wait is real', (tester) async {
      _useTallViewport(tester);
      final gate = Completer<void>();
      final service = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-1')],
      );

      await tester.pumpWidget(_appWith(service, trustLevel: 2));
      await tester.pumpAndSettle();

      // From here on, every fetch hangs until the gate opens.
      final slowService = ScriptedMeetupService(
        openMeetups: [_meetup(id: 'meetup-2')],
        openMeetupsGate: gate.future,
      );
      await tester.pumpWidget(_appWith(slowService, trustLevel: 2));
      await tester.pump();

      await tester.tap(find.text(IntentType.networking.label));
      await tester.pump();

      // Just after the tap: still the stale list, dimmed.
      expect(find.byType(MeetupsSkeleton), findsNothing);

      // Past the threshold: a real placeholder.
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byType(MeetupsSkeleton),
        findsOneWidget,
        reason: 'an indefinitely dimmed list reads as broken, not as loading',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(MeetupsSkeleton), findsNothing);
    });

    testWidgets(
      'the skeleton is sized to the list it replaces, so the page keeps its '
      'height and the scroll position stays put',
      (tester) async {
        _useTallViewport(tester);
        final gate = Completer<void>();

        final service = ScriptedMeetupService(
          openMeetups: List.generate(3, (i) => _meetup(id: 'meetup-$i')),
        );
        await tester.pumpWidget(_appWith(service, trustLevel: 2));
        await tester.pumpAndSettle();

        final slowService = ScriptedMeetupService(
          openMeetups: const [],
          openMeetupsGate: gate.future,
        );
        await tester.pumpWidget(_appWith(slowService, trustLevel: 2));
        await tester.pump();

        await tester.tap(find.text(IntentType.networking.label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final skeleton = tester.widget<MeetupsSkeleton>(
          find.byType(MeetupsSkeleton),
        );
        expect(
          skeleton.cardCount,
          3,
          reason:
              'three stale cards means three placeholders — a shorter '
              'skeleton would resize the page and move the scroll',
        );

        gate.complete();
        await tester.pumpAndSettle();
      },
    );
  });
}
