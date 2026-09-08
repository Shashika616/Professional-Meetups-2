import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';

import 'support/fake_meetup_service.dart';
import 'support/scripted_meetup_service.dart';

/// Resolves immediately to a fixed [AuthSessionState] instead of reading
/// secure storage — HomePage only ever reads `.profile` off this provider,
/// so there's no need for ProfilePage's full secure-storage-seeding setup.
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

void main() {
  group('HomeHeader (frontend/PLAN.md Step 13)', () {
    testWidgets(
      'renders the profile photo via ProfessionalAvatar when imageUrl is provided',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: HomeHeader(
                userName: 'Ada Lovelace',
                imageUrl: 'https://example.com/photo.jpg',
              ),
            ),
          ),
        );
        await tester.pump();

        final avatar = tester.widget<ProfessionalAvatar>(
          find.byType(ProfessionalAvatar),
        );
        expect(avatar.imageUrl, 'https://example.com/photo.jpg');

        final avatarImage = find.descendant(
          of: find.byType(ProfessionalAvatar),
          matching: find.byType(Image),
        );
        final image = tester.widget<Image>(avatarImage);
        // ProfessionalAvatar sets cacheWidth/cacheHeight (2026-08-31
        // round-3 hardening, Fix 3) — Image.network wraps the underlying
        // NetworkImage in a ResizeImage whenever either is set, so the
        // provider under test is no longer a bare NetworkImage.
        final resized = image.image as ResizeImage;
        expect(
          (resized.imageProvider as NetworkImage).url,
          'https://example.com/photo.jpg',
        );
      },
    );

    testWidgets('falls back to initials when imageUrl is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HomeHeader(userName: 'Ada Lovelace')),
        ),
      );
      await tester.pump();

      final avatar = tester.widget<ProfessionalAvatar>(
        find.byType(ProfessionalAvatar),
      );
      expect(avatar.imageUrl, isNull);
      expect(
        find.descendant(
          of: find.byType(ProfessionalAvatar),
          matching: find.byType(Image),
        ),
        findsNothing,
      );
    });
  });

  group('HomePage (frontend/PLAN.md Step 13)', () {
    testWidgets(
      "shows the real signed-in user's name instead of any hardcoded string",
      (tester) async {
        const profile = UserProfile(
          id: 'user-1',
          fullName: 'Grace Hopper',
          profilePhotoUrl: 'https://example.com/grace.jpg',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionProvider.overrideWith(
                () => _FakeAuthSessionNotifier(
                  const AuthSessionState(profile: profile),
                ),
              ),
              // ActiveMeetupsSection reads activeMeetupsProvider and
              // HappeningSoonSection reads openMeetupsProvider (both backed
              // by this) — without an override they default to the real
              // HttpMeetupService and attempt live network calls.
              meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
            ],
            child: const MaterialApp(home: HomePage()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Grace Hopper'), findsOneWidget);
        expect(find.text('Shashika Fernando'), findsNothing);

        final header = tester.widget<HomeHeader>(find.byType(HomeHeader));
        expect(header.imageUrl, 'https://example.com/grace.jpg');
      },
    );

    testWidgets('falls back to "Member" when no profile is loaded yet', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authSessionProvider.overrideWith(
              () => _FakeAuthSessionNotifier(const AuthSessionState()),
            ),
            meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Member'), findsOneWidget);
      expect(find.text('Shashika Fernando'), findsNothing);
    });

    testWidgets('HOST YOUR OWN MEETUP opens ScheduleFlowPage directly for an '
        'unlocked user — hosting used to be reachable only via a "+" icon '
        'on the browse/Matches page, which this button replaces as the '
        'primary entry point. CHANGED VALUE (ADR-002 § 4): the fixture was '
        'Level 2, which used to be enough to host coffee; hosting now needs '
        'Level 3, so this regression guard for the still-working unlocked '
        'case had to move up with it.', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authSessionProvider.overrideWith(
              () => _FakeAuthSessionNotifier(
                const AuthSessionState(
                  profile: UserProfile(
                    id: 'user-1',
                    fullName: 'Ada',
                    // CHANGED (ADR-002 § 4): was 2. Hosting an ordinary
                    // intent needs Level 3 now.
                    trustLevel: 3,
                  ),
                ),
              ),
            ),
            meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      // HOST YOUR OWN MEETUP sits in a fixed block below the scrolling
      // area, so it is on screen without scrolling — but the page's own
      // ListView is still what a stray drag would hit, and there are now
      // several nested Scrollables (the intent filter row, the browse
      // list), so the button is targeted by key rather than by position.
      expect(find.byKey(const Key('hostYourOwnMeetup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hostYourOwnMeetup')));
      await tester.pumpAndSettle();

      expect(find.byType(ScheduleFlowPage), findsOneWidget);
    });

    testWidgets(
      'round-7 hardening: HOST YOUR OWN MEETUP now has a real trust gate '
      'of its own — a locked (Level 0) user\'s tap does not push '
      'ScheduleFlowPage at all, shows the locked toast, and redirects to '
      'HostingUnlockPage (CHANGED by ADR-002 § 4: the destination was '
      'VerificationChecklistPage, which is the wrong page for this gap — a '
      'user short of the HOST bar may already be Level 2 and would be shown '
      'a checklist of things they finished long ago)',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionProvider.overrideWith(
                () => _FakeAuthSessionNotifier(const AuthSessionState()),
              ),
              meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
            ],
            child: const MaterialApp(home: HomePage()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('hostYourOwnMeetup')));
        await tester.pumpAndSettle();

        expect(find.byType(ScheduleFlowPage), findsNothing);
        // CHANGED (ADR-002 § 4): was 'requires Level 2 trust'.
        expect(find.textContaining('requires Level 3 trust'), findsOneWidget);
        expect(find.byType(HostingUnlockPage), findsOneWidget);
      },
    );

    testWidgets('pulling to refresh refetches the active-meetups list from the '
        'network (ADR-030, round-9 — one of the two real, event-triggered '
        'refetch paths, alongside AppShell\'s app-resume hook)', (
      tester,
    ) async {
      final service = ScriptedMeetupService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authSessionProvider.overrideWith(
              () => _FakeAuthSessionNotifier(
                const AuthSessionState(
                  profile: UserProfile(
                    id: 'user-1',
                    fullName: 'Ada',
                    trustLevel: 2,
                  ),
                ),
              ),
            ),
            meetupServiceProvider.overrideWithValue(service),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(service.listActiveMeetupsCallCount, 1);

      // The page's own outer ListView, which owns the RefreshIndicator.
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(
        service.listActiveMeetupsCallCount,
        2,
        reason:
            'pull-to-refresh must actually call the network again, '
            'not just recompute local state',
      );
    });
  });

  /// # WHAT THE HOME/EVENTS RESTRUCTURE REMOVED
  ///
  /// These are removal guards, not styling assertions. FIND MATCHES existed
  /// only to navigate to a separate browse tab; that tab is gone and its
  /// list is inline on this page, so the button has nowhere to go. A
  /// hidden-but-present button would be a dead control, and "Your Stats"
  /// (NetworkInsightsRow) was deleted outright — both must stay gone rather
  /// than quietly returning in a later edit.
  group('removed controls stay removed', () {
    Widget app() => ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(
          () => _FakeAuthSessionNotifier(
            const AuthSessionState(
              profile: UserProfile(
                id: 'user-1',
                fullName: 'Ada',
                trustLevel: 2,
              ),
            ),
          ),
        ),
        meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
      ],
      child: const MaterialApp(home: HomePage()),
    );

    testWidgets('FIND MATCHES is gone entirely, not merely hidden', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('FIND MATCHES'), findsNothing);
      expect(find.textContaining('FIND MATCH'), findsNothing);
    });

    testWidgets('"Your Stats" / NetworkInsightsRow is gone', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Your Stats'), findsNothing);
    });

    testWidgets(
      'the header\'s two Events entry chips are gone — that is a bottom-nav '
      'destination now, not a chip on Home',
      (tester) async {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();

        expect(find.text('Your Meetings'), findsNothing);
        expect(find.text('Requested Meetups'), findsNothing);
      },
    );

    testWidgets(
      'HOST YOUR OWN MEETUP is the page\'s only bottom CTA, and it is the '
      'primary (filled) one now that it no longer shares the block',
      (tester) async {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();

        expect(find.byType(FilledButton), findsOneWidget);
        expect(find.byKey(const Key('hostYourOwnMeetup')), findsOneWidget);
      },
    );
  });
}
