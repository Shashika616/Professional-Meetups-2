import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/meetups/participants_page.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/participants_strip.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_auth_service.dart';
import 'support/scripted_meetup_service.dart';

/// What the server sends a verified (level 2+) viewer.
const _named = MeetupParticipants(
  participants: [
    MeetupParticipant(
      userId: 'host-1',
      isHost: true,
      fullName: 'Grace Hopper',
      trustLevel: 3,
    ),
    MeetupParticipant(
      userId: 'guest-1',
      isHost: false,
      fullName: 'Ada Lovelace',
      trustLevel: 2,
    ),
  ],
  totalCount: 2,
);

/// What the server sends a level 0/1 viewer: the shape of the list and the
/// count, and nothing that identifies anyone. This is the real wire payload,
/// not a client-side censoring of the one above.
const _redacted = MeetupParticipants(
  participants: [
    MeetupParticipant(isHost: true),
    MeetupParticipant(isHost: false),
  ],
  redacted: true,
  totalCount: 2,
);

Widget _stripIn(ScriptedMeetupService service) => ProviderScope(
  overrides: [meetupServiceProvider.overrideWithValue(service)],
  child: const MaterialApp(
    home: Scaffold(body: ParticipantsStrip(meetupId: 'meetup-1')),
  ),
);

Widget _pageIn(ScriptedMeetupService service) => ProviderScope(
  overrides: [meetupServiceProvider.overrideWithValue(service)],
  child: const MaterialApp(home: ParticipantsPage(meetupId: 'meetup-1')),
);

/// A redacted list as the server now sends it to a verified outsider: the
/// host named, everyone else blank.
const _redactedHostNamed = MeetupParticipants(
  participants: [
    MeetupParticipant(
      userId: 'host-1',
      isHost: true,
      fullName: 'Grace Hopper',
      trustLevel: 3,
    ),
    MeetupParticipant(isHost: false),
  ],
  totalCount: 2,
  redacted: true,
);

class _SessionAs extends AuthSessionNotifier {
  _SessionAs(this.id);
  final String id;
  @override
  Future<AuthSessionState> build() async => AuthSessionState(
    profile: UserProfile(id: id, fullName: 'Viewer', trustLevel: 2),
  );
}

class _SessionAt extends AuthSessionNotifier {
  _SessionAt(this.level);
  final int level;
  @override
  Future<AuthSessionState> build() async => AuthSessionState(
    profile: UserProfile(id: 'viewer', fullName: 'Viewer', trustLevel: level),
  );
}

void main() {
  group('participants strip', () {
    testWidgets('shows the faces and the count for a verified viewer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _stripIn(ScriptedMeetupService()..participants = _named),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 going'), findsOneWidget);
      expect(find.byType(ProfessionalAvatar), findsNWidgets(2));
      expect(find.byType(RedactedFace), findsNothing);
    });

    testWidgets('a redacted list still says how many are coming — that is '
        'the part that makes a meetup worth joining', (tester) async {
      await tester.pumpWidget(
        _stripIn(ScriptedMeetupService()..participants = _redacted),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 going · verify to see who'), findsOneWidget);
      expect(find.byType(RedactedFace), findsNWidgets(2));
      // Not one real avatar: ProfessionalAvatar renders initials from a
      // name, so using it here would show a letter derived from someone the
      // viewer is not allowed to identify.
      expect(find.byType(ProfessionalAvatar), findsNothing);
    });

    testWidgets('with nobody on the meetup it renders nothing at all rather '
        'than an empty row', (tester) async {
      await tester.pumpWidget(_stripIn(ScriptedMeetupService()));
      await tester.pumpAndSettle();

      expect(find.byType(RedactedFace), findsNothing);
      expect(find.textContaining('going'), findsNothing);
    });

    testWidgets('tapping it opens the full list', (tester) async {
      await tester.pumpWidget(
        _stripIn(ScriptedMeetupService()..participants = _named),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('2 going'));
      await tester.pumpAndSettle();

      expect(find.byType(ParticipantsPage), findsOneWidget);
    });
  });

  group('participants page', () {
    testWidgets('names the people for a verified viewer, host badged first', (
      tester,
    ) async {
      await tester.pumpWidget(
        _pageIn(ScriptedMeetupService()..participants = _named),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 people'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('GET VERIFIED'), findsNothing);
    });

    testWidgets('a redacted list shows no names, no fake names, and the '
        'route to fixing it', (tester) async {
      await tester.pumpWidget(
        _pageIn(ScriptedMeetupService()..participants = _redacted),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 people'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsNothing);
      // Inventing a placeholder like "Member" would read as somebody's
      // actual display name.
      expect(find.text('Member'), findsNothing);
      expect(find.byType(RedactedFace), findsNWidgets(2));
      // Knowing a meetup HAS a host is not the same as knowing who they are.
      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('Verify to see who’s coming'), findsOneWidget);
    });

    testWidgets('GET VERIFIED routes to the checklist rather than being a '
        'dead end', (tester) async {
      await tester.pumpWidget(
        _pageIn(ScriptedMeetupService()..participants = _redacted),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('GET VERIFIED'));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsOneWidget);
    });
  });

  group('participant rows open the public profile', () {
    Widget pageWith(ScriptedMeetupService service, ImmediateAuthService auth) =>
        ProviderScope(
          overrides: [
            meetupServiceProvider.overrideWithValue(service),
            authServiceProvider.overrideWithValue(auth),
          ],
          child: const MaterialApp(
            home: ParticipantsPage(meetupId: 'meetup-1'),
          ),
        );

    testWidgets('tapping a named participant opens their profile', (
      tester,
    ) async {
      final auth = ImmediateAuthService()
        ..publicProfileFor = (id) =>
            PublicProfile(id: id, fullName: 'Ada Lovelace', trustLevel: 2);
      await tester.pumpWidget(
        pageWith(ScriptedMeetupService()..participants = _named, auth),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ada Lovelace'));
      await tester.pumpAndSettle();

      expect(find.byType(PublicProfilePage), findsOneWidget);
    });

    testWidgets('a redacted row opens nothing — there is no identity behind '
        'it to show', (tester) async {
      final auth = ImmediateAuthService();
      await tester.pumpWidget(
        pageWith(ScriptedMeetupService()..participants = _redacted, auth),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(RedactedFace).first);
      await tester.pumpAndSettle();

      expect(find.byType(PublicProfilePage), findsNothing);
    });
  });

  group('redaction says the right reason', () {
    Widget pageAt(int level, MeetupParticipants data) => ProviderScope(
      overrides: [
        meetupServiceProvider.overrideWithValue(
          ScriptedMeetupService()..participants = data,
        ),
        authServiceProvider.overrideWithValue(ImmediateAuthService()),
        authSessionProvider.overrideWith(() => _SessionAt(level)),
      ],
      child: const MaterialApp(home: ParticipantsPage(meetupId: 'meetup-1')),
    );

    testWidgets('below Level 2 it is a verification prompt', (tester) async {
      await tester.pumpWidget(pageAt(1, _redacted));
      await tester.pumpAndSettle();
      expect(find.text('Verify to see who’s coming'), findsOneWidget);
      expect(find.text('GET VERIFIED'), findsOneWidget);
      expect(find.text('Join to see who\'s coming'), findsNothing);
    });

    testWidgets('at Level 2+ it says join — there is nothing to verify', (
      tester,
    ) async {
      await tester.pumpWidget(pageAt(2, _redactedHostNamed));
      await tester.pumpAndSettle();
      expect(find.text('Join to see who\'s coming'), findsOneWidget);
      expect(find.text('GET VERIFIED'), findsNothing);
    });

    testWidgets('a named host row in a redacted list is shown and opens the '
        'host profile; the blank rows stay blurred and inert', (tester) async {
      await tester.pumpWidget(pageAt(2, _redactedHostNamed));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.byType(RedactedFace), findsOneWidget);

      await tester.tap(find.text('Grace Hopper'));
      await tester.pumpAndSettle();
      expect(find.byType(PublicProfilePage), findsOneWidget);
    });
  });

  group('role tags and the viewer', () {
    testWidgets('the signed-in user\'s own row carries a YOU tag; the host '
        'row carries HOST; no open-spot rows are drawn', (tester) async {
      final auth = ImmediateAuthService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meetupServiceProvider.overrideWithValue(
              ScriptedMeetupService()..participants = _named,
            ),
            authServiceProvider.overrideWithValue(auth),
            // The fake session's profile id is guest-1 — Ada's row.
            authSessionProvider.overrideWith(() => _SessionAs('guest-1')),
          ],
          child: const MaterialApp(
            home: ParticipantsPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('Open spot'), findsNothing);
    });
  });
}
