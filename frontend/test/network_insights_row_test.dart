import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/home/widgets/network_insights_row.dart';

import 'support/scripted_meetup_service.dart';

/// Resolves immediately to a fixed [AuthSessionState] instead of reading
/// secure storage — mirrors home_page_test.dart's own fake for the same
/// reason.
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

Meetup _meetup(String id) => Meetup(
  id: id,
  hostUserId: 'someone',
  hostFullName: 'Someone',
  hostTrustLevel: 2,
  intent: IntentType.coffee,
  windowStart: DateTime.now().add(const Duration(hours: 1)),
  windowEnd: DateTime.now().add(const Duration(hours: 3)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime.now(),
);

void main() {
  Widget wrap({
    required UserProfile profile,
    required ScriptedMeetupService service,
  }) {
    return ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(
          () => _FakeAuthSessionNotifier(AuthSessionState(profile: profile)),
        ),
        meetupServiceProvider.overrideWithValue(service),
      ],
      child: const MaterialApp(home: Scaffold(body: NetworkInsightsRow())),
    );
  }

  testWidgets(
    'renders the real trust level, meetup count, and rating — not the old '
    'hardcoded 128/12/4.9',
    (tester) async {
      const profile = UserProfile(
        id: 'user-1',
        fullName: 'Ada Lovelace',
        trustLevel: 2,
        ratingAverage: 4.5,
        ratingCount: 10,
      );
      final service = ScriptedMeetupService(
        myMeetups: (
          hosted: [_meetup('meetup-1'), _meetup('meetup-2')],
          requested: [_meetup('meetup-3')],
        ),
      );

      await tester.pumpWidget(wrap(profile: profile, service: service));
      await tester.pumpAndSettle();

      expect(find.text('L2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // 2 hosted + 1 requested
      expect(find.text('4.5'), findsOneWidget);

      expect(find.text('128'), findsNothing);
      expect(find.text('12'), findsNothing);
      expect(find.text('4.9'), findsNothing);
    },
  );

  testWidgets(
    'shows "—" for a never-rated user instead of a fabricated score',
    (tester) async {
      const profile = UserProfile(id: 'user-1', fullName: 'Ada Lovelace');
      final service = ScriptedMeetupService(
        myMeetups: (hosted: const [], requested: const []),
      );

      await tester.pumpWidget(wrap(profile: profile, service: service));
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsOneWidget); // no meetups
      expect(find.text('L0'), findsOneWidget);
    },
  );
}
