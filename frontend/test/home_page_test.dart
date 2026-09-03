import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

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
              // UpcomingMeetupCard and NetworkInsightsRow both read
              // myMeetupsProvider (backed by this) — without an override
              // it defaults to the real HttpMeetupService and attempts a
              // live network call.
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
        'primary entry point. Level 2 (round-7 hardening added a real gate '
        'here — coffee, the default selected intent, requires 2) so this '
        'is the regression guard for the still-working unlocked case.', (
      tester,
    ) async {
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
            meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      // A real profile here (vs. the null-profile fixture the pre-existing
      // sibling test below uses) renders slightly more content earlier in
      // the list, pushing this button just past the outer ListView's
      // sliver cache extent in the default test viewport — drag that
      // specific ListView (IntentGrid's own internal GridView is also a
      // Scrollable, so scrollUntilVisible's automatic detection isn't
      // reliable here) to bring it into view before tapping.
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(find.text('HOST YOUR OWN MEETUP'), findsOneWidget);
      await tester.tap(find.text('HOST YOUR OWN MEETUP'));
      await tester.pumpAndSettle();

      expect(find.byType(ScheduleFlowPage), findsOneWidget);
    });

    testWidgets(
      'round-7 hardening: HOST YOUR OWN MEETUP now has a real trust gate '
      'of its own — a locked (Level 0) user\'s tap does not push '
      'ScheduleFlowPage at all, shows the locked toast, and redirects to '
      'VerificationChecklistPage instead',
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

        await tester.tap(find.text('HOST YOUR OWN MEETUP'));
        await tester.pumpAndSettle();

        expect(find.byType(ScheduleFlowPage), findsNothing);
        expect(find.textContaining('requires Level 2 trust'), findsOneWidget);
        expect(find.byType(VerificationChecklistPage), findsOneWidget);
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

      // Same drag-the-outer-ListView target as the sibling test above.
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
}
