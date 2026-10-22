import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/app_icon_finder.dart';

import 'support/fake_geolocator_platform.dart';
import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  // Not exercised here: no test in this file drives the claim-an-existing-
  // account ceremony. Present because AuthService declares it.
  @override
  Future<AuthSession> completeAccountClaim({
    required String ticket,
    required String code,
  }) => throw UnimplementedError('not exercised by this test');

  @override
  Future<int> resendAccountClaimCode(String ticket) =>
      throw UnimplementedError('not exercised by this test');
  @override
  Future<PublicProfile> getPublicProfile(String userId) =>
      throw UnimplementedError('not exercised by this test');

  // ADR-002 § 3. Unused by this test — every fake in test/ implements the
  // full AuthService surface, so a new method lands here even when the test
  // never calls it.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  _FakeAuthService({
    List<TrustedContact>? contacts,
    this.triggerSosResult,
    this.triggerSosError,
    this.listContactsError,
  }) : _contacts = contacts ?? [];

  final List<TrustedContact> _contacts;
  final int? triggerSosResult;
  final Object? triggerSosError;

  /// Thrown by [listTrustedContacts] when set — stands in for the server
  /// refusing a caller the client thought was allowed (ADR-003).
  final Object? listContactsError;

  int triggerSosCallCount = 0;

  /// What the dialog actually sent. null/null is the #78 case: no usable
  /// fix, alert sent anyway.
  double? lastLatitude;
  double? lastLongitude;

  /// When true, triggerSosError applies to the first attempt only.
  bool failOnlyFirstAttempt = false;

  /// Proves a gated tap never reaches the service at all, rather than being
  /// refused after the call.
  int listContactsCallCount = 0;

  @override
  Future<List<TrustedContact>> listTrustedContacts() async {
    listContactsCallCount++;
    final error = listContactsError;
    if (error != null) throw error;
    return _contacts;
  }

  @override
  Future<int> triggerSos({
    required String contextMessage,
    double? latitude,
    double? longitude,
  }) async {
    triggerSosCallCount++;
    lastLatitude = latitude;
    lastLongitude = longitude;
    final error = triggerSosError;
    // Only the FIRST attempt fails when failOnlyFirstAttempt is set, so a
    // test can prove Retry actually retries rather than just redrawing.
    if (error != null && !(failOnlyFirstAttempt && triggerSosCallCount > 1)) {
      throw error;
    }
    return triggerSosResult!;
  }

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async => throw UnimplementedError();

  @override
  Future<void> removeTrustedContact(String contactId) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signInWithApple({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signInWithGoogle({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> linkLinkedIn() async => throw UnimplementedError();

  @override
  Future<int> startEmailSignupOtp(String email) async =>
      throw UnimplementedError();

  @override
  Future<int> startEmailLoginOtp(String email) async =>
      throw UnimplementedError();

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> refreshSession(String refreshToken) async =>
      throw UnimplementedError();

  @override
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) async {}

  @override
  Future<UserProfile> getProfile() async =>
      const UserProfile(id: 'user-1', fullName: 'Ada Lovelace');

  @override
  Future<int> startPhoneVerification(String phoneNumber) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) async =>
      throw UnimplementedError();

  @override
  Future<int> startPersonalEmailVerification(String email) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPersonalEmailCode(
    String email,
    String code,
  ) async => throw UnimplementedError();

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async => throw UnimplementedError();

  @override
  Future<int> startCorporateEmailVerification(String email) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) async => throw UnimplementedError();
}

Widget _appWith(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) =>
            MaterialPageRoute(builder: (context) => const SafetyPage()),
      ),
    ),
  );
}

/// [trustLevel] defaults to 2 because that is what the safety features now
/// require (ADR-003) — every test in this file except the gate's own
/// exercises behaviour BEHIND that gate, so the default is the level that
/// gets through it.
ProviderContainer _containerWith(_FakeAuthService auth, {int trustLevel = 2}) {
  return ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
      authSessionProvider.overrideWith(
        () => _StubAuthSession(trustLevel: trustLevel),
      ),
    ],
  );
}

/// A session notifier pinned to one trust level. Overriding the provider
/// rather than the storage keeps the test independent of how a session is
/// restored — it only needs the profile the page reads.
class _StubAuthSession extends AuthSessionNotifier {
  _StubAuthSession({required this.trustLevel});

  final int trustLevel;

  @override
  Future<AuthSessionState> build() async => AuthSessionState(
    profile: UserProfile(
      id: 'user-1',
      fullName: 'Ada Lovelace',
      trustLevel: trustLevel,
    ),
  );
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      position: testPosition(),
    );
  });

  _sosFailurePathTests();

  testWidgets(
    'zero contacts routes to the manage-contacts screen instead of the '
    'confirm dialog',
    (tester) async {
      final auth = _FakeAuthService(contacts: []);
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trigger SOS'));
      await tester.pumpAndSettle();

      expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
      expect(find.text('Emergency SOS'), findsNothing);
      expect(auth.triggerSosCallCount, 0);
    },
  );

  testWidgets('successful trigger shows the real contacts-alerted count', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: [
        const TrustedContact(
          id: 'c1',
          name: 'Grace',
          phoneNumber: '+94771111111',
          email: '',
        ),
        const TrustedContact(
          id: 'c2',
          name: 'Ada',
          phoneNumber: '',
          email: 'ada@example.com',
        ),
      ],
      triggerSosResult: 2,
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trigger SOS'));
    await tester.pumpAndSettle();
    expect(find.text('Emergency SOS'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(auth.triggerSosCallCount, 1);
    expect(find.text('2 trusted contacts were alerted.'), findsOneWidget);
  });

  testWidgets('failed trigger shows a real error state', (tester) async {
    final auth = _FakeAuthService(
      contacts: [
        const TrustedContact(
          id: 'c1',
          name: 'Grace',
          phoneNumber: '+94771111111',
          email: '',
        ),
      ],
      triggerSosError: const AuthNetworkException('Something went wrong.'),
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trigger SOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(auth.triggerSosCallCount, 1);
    expect(find.text('Something went wrong.'), findsOneWidget);
  });

  testWidgets(
    '"Call emergency services" stays available even after a failed trigger',
    (tester) async {
      final auth = _FakeAuthService(
        contacts: [
          const TrustedContact(
            id: 'c1',
            name: 'Grace',
            phoneNumber: '+94771111111',
            email: '',
          ),
        ],
        triggerSosError: const AuthNetworkException('Something went wrong.'),
      );
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trigger SOS'));
      await tester.pumpAndSettle();

      // Present before CONFIRM is even tapped...
      expect(find.text('Call emergency services'), findsOneWidget);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      // ...and still present after a failed trigger.
      expect(find.text('Call emergency services'), findsOneWidget);
    },
  );

  // ADR-003 — trusted contacts and SOS require Level 2, the same floor as
  // joining a meetup. The page itself stays visible so a guest still learns
  // the feature exists and what it is worth verifying for.
  group('safety features are gated at Level 2 (ADR-003)', () {
    for (final trustLevel in [0, 1]) {
      testWidgets('level $trustLevel gets the locked toast and the unlock '
          'checklist instead of the SOS flow', (tester) async {
        final auth = _FakeAuthService(contacts: []);
        final container = _containerWith(auth, trustLevel: trustLevel);
        addTearDown(container.dispose);

        await tester.pumpWidget(_appWith(container));
        await tester.pumpAndSettle();

        // The button is present, not hidden — the lock is explained on tap.
        expect(find.text('Trigger SOS'), findsOneWidget);

        await tester.tap(find.text('Trigger SOS'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('require Level 2 trust'),
          findsOneWidget,
          reason: 'the toast must say what is locked and why',
        );
        expect(find.byType(VerificationChecklistPage), findsOneWidget);
        expect(find.text('Unlock safety features'), findsOneWidget);
        // Safety-specific framing, not the meetup-joining default.
        expect(find.textContaining('trusted contacts and SOS'), findsWidgets);

        // Nothing reached the service, and the confirm dialog never opened.
        expect(auth.listContactsCallCount, 0);
        expect(auth.triggerSosCallCount, 0);
        expect(find.byType(ManageTrustedContactsPage), findsNothing);
      });
    }

    testWidgets('level 2 proceeds normally', (tester) async {
      final auth = _FakeAuthService(contacts: []);
      final container = _containerWith(auth, trustLevel: 2);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trigger SOS'));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsNothing);
      expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
    });

    // A cached profile can be behind the real trust level. The client check
    // passes, the server refuses, and the user must still land somewhere
    // useful rather than on a raw error toast.
    testWidgets('a server 403 despite a passing client check routes to the '
        'same unlock page', (tester) async {
      final auth = _FakeAuthService(
        contacts: [],
        listContactsError: const ForbiddenActionException(),
      );
      final container = _containerWith(auth, trustLevel: 2);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Trigger SOS'));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      expect(find.text('Unlock safety features'), findsOneWidget);

      // Let the locked toast's own auto-dismiss timer run out, so it does
      // not outlive the widget tree.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  // Adding a trusted contact used to be reachable from exactly one place —
  // the SOS button, and only with ZERO contacts. The moment someone added
  // their first, the remaining two slots became unreachable.
  group('trusted contacts are visible and the remaining slots reachable', () {
    const grace = TrustedContact(
      id: 'c1',
      name: 'Grace Hopper',
      phoneNumber: '+94771111111',
      email: '',
    );
    const ada = TrustedContact(
      id: 'c2',
      name: 'Ada Lovelace',
      phoneNumber: '',
      email: 'ada@example.com',
    );
    const alan = TrustedContact(
      id: 'c3',
      name: 'Alan Turing',
      phoneNumber: '+94773333333',
      email: '',
    );

    Future<void> pump(WidgetTester tester, _FakeAuthService auth) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();
    }

    testWidgets('existing contacts are listed with the count and the cap', (
      tester,
    ) async {
      await pump(tester, _FakeAuthService(contacts: [grace, ada]));

      expect(find.text('Trusted contacts'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      // Names only on this summary — the number or address each contact
      // was added with belongs on the Trusted contacts page the section
      // leads to, not under every name here.
      expect(find.text('+94771111111'), findsNothing);
      expect(find.text('ada@example.com'), findsNothing);
      // The cap is stated before it is hit, not discovered by being refused.
      expect(find.textContaining('2 of 3 added'), findsOneWidget);
    });

    testWidgets('with one contact the section still offers the other two '
        'slots — this is the case that was unreachable', (tester) async {
      await pump(tester, _FakeAuthService(contacts: [grace]));

      expect(find.textContaining('1 of 3 added'), findsOneWidget);

      await tester.tap(find.textContaining('Add a contact'));
      await tester.pumpAndSettle();

      expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
    });

    testWidgets('at the cap it says so instead of offering another', (
      tester,
    ) async {
      await pump(tester, _FakeAuthService(contacts: [grace, ada, alan]));

      expect(find.textContaining('All 3 contacts added'), findsOneWidget);
      expect(find.textContaining('Add a contact'), findsNothing);
      // Still reachable — removing one is how you make room.
      await tester.tap(find.textContaining('All 3 contacts added'));
      await tester.pumpAndSettle();
      expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
    });

    testWidgets('with none it prompts rather than showing an empty card', (
      tester,
    ) async {
      await pump(tester, _FakeAuthService(contacts: []));

      expect(find.textContaining('No one yet'), findsOneWidget);
      expect(find.textContaining('0 of 3 added'), findsOneWidget);
    });

    testWidgets('below Level 2 it shows the lock and never asks the server '
        'for a list it could not add to', (tester) async {
      final auth = _FakeAuthService(contacts: [grace]);
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = _containerWith(auth, trustLevel: 1);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      expect(find.textContaining('Verify your account'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsNothing);
      expect(auth.listContactsCallCount, 0);

      await tester.tap(find.textContaining('Verify your account'));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    // UI review #20: the checklist rows carried green check_circle icons,
    // which claim the user has already done these things. They are advice,
    // and nothing in the app knows whether they were followed.
    testWidgets('the pre-meetup checklist does not claim to be completed', (
      tester,
    ) async {
      final auth = _FakeAuthService(contacts: [grace]);
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = _containerWith(auth, trustLevel: 2);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      expect(find.text('Pre meetup checklist'), findsOneWidget);
      expect(
        findAppIcon(AppIcons.checkCircle),
        findsNothing,
        reason: 'a tick says the user has done these; nothing knows that',
      );
      expect(
        findAppIcon(AppIcons.checkbox),
        findsNothing,
        reason: 'an empty box implies these are tickable; they are not',
      );
      // The repeated lightbulb went too: five identical glyphs down one
      // list carry no information. The advice itself is what has to be
      // on screen.
      expect(find.text('Meet in a public place'), findsOneWidget);
      expect(find.text('Never share OTP codes'), findsOneWidget);
    });

    // UI review #21. The card always routed to the unlock screen — the test
    // above proves that — but a lock icon over a grey sentence reads as a
    // disabled state, and the one thing a disabled state tells you is not to
    // bother tapping. So the affordance was missing, not the action.
    testWidgets('the locked card says that tapping it leads somewhere', (
      tester,
    ) async {
      final auth = _FakeAuthService(contacts: [grace]);
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = _containerWith(auth, trustLevel: 1);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      expect(
        find.text('Verify'),
        findsOneWidget,
        reason: 'the locked card offers no visible way forward',
      );
      expect(
        findAppIcon(AppIcons.forward),
        findsWidgets,
        reason: 'nothing marks the card as leading anywhere',
      );

      // And it still costs nothing: adding the affordance must not have
      // turned a locked card into a request for a list it cannot use.
      expect(auth.listContactsCallCount, 0);
    });
  });
}

// Tracker #78 (review findings N-D1, N-D2, N-D3): the SOS sheet must
// always reach a state the user can act on, and a missing location must
// never be the reason an alert is not sent.
//
// These five are the cases the plan named: offline, timeout, no
// location, 5xx and session expired.
void _sosFailurePathTests() {
  List<TrustedContact> oneContact() => const [
    TrustedContact(
      id: 'c1',
      name: 'Grace',
      phoneNumber: '+94771111111',
      email: '',
    ),
  ];

  Future<void> openAndConfirm(
    WidgetTester tester,
    _FakeAuthService auth,
  ) async {
    final container = _containerWith(auth);
    addTearDown(container.dispose);
    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trigger SOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
  }

  testWidgets('no location fix: the alert is still sent, without coordinates', (
    tester,
  ) async {
    // The whole point of #78. Indoors, permission denied, or the read
    // timed out — SOS used to refuse to send at all.
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      permission: LocationPermission.denied,
      position: null,
    );
    final auth = _FakeAuthService(contacts: oneContact(), triggerSosResult: 1);

    await openAndConfirm(tester, auth);

    expect(
      auth.triggerSosCallCount,
      1,
      reason: 'the alert was suppressed because there was no GPS fix',
    );
    expect(auth.lastLatitude, isNull);
    expect(auth.lastLongitude, isNull);
    expect(find.text('1 trusted contact was alerted.'), findsOneWidget);
    // And the sender is told, because their contact was told.
    expect(
      find.textContaining('location could not be determined'),
      findsOneWidget,
    );
  });

  testWidgets(
    'offline: a failure state with Retry and Call emergency services',
    (tester) async {
      final auth = _FakeAuthService(
        contacts: oneContact(),
        triggerSosError: const AuthNetworkException(
          'Could not reach the server. Check your connection and try again.',
        ),
      );

      await openAndConfirm(tester, auth);

      expect(find.textContaining('Could not reach the server'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Call emergency services'), findsOneWidget);
    },
  );

  testWidgets('Retry actually retries', (tester) async {
    final auth = _FakeAuthService(
      contacts: oneContact(),
      triggerSosResult: 1,
      triggerSosError: const AuthNetworkException('Offline.'),
    )..failOnlyFirstAttempt = true;

    await openAndConfirm(tester, auth);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(auth.triggerSosCallCount, 2);
    expect(find.text('1 trusted contact was alerted.'), findsOneWidget);
  });

  testWidgets('an unexpected error does not strand the sheet on "sending"', (
    tester,
  ) async {
    // N-D3: anything that was not an AuthException used to escape
    // _confirm entirely, leaving the sheet spinning forever — during an
    // emergency.
    final auth = _FakeAuthService(
      contacts: oneContact(),
      triggerSosError: StateError('something nobody predicted'),
    );

    await openAndConfirm(tester, auth);

    expect(
      find.textContaining('Getting your location'),
      findsNothing,
      reason: 'the sheet is still claiming to be sending',
    );
    expect(find.textContaining('Could not send the alert'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Call emergency services'), findsOneWidget);
  });

  testWidgets('a 5xx is a retryable failure, not a crash', (tester) async {
    final auth = _FakeAuthService(
      contacts: oneContact(),
      triggerSosError: const AuthNetworkException(
        'Something went wrong. Please try again.',
      ),
    );

    await openAndConfirm(tester, auth);

    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a session that expired signs out instead of offering Retry', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: oneContact(),
      triggerSosError: const SessionExpiredException('Please sign in again.'),
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);
    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trigger SOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));

    // pump, not pumpAndSettle: forceSignOut tears the session down and
    // the sign-out route animates, so settling here waits on work this
    // test is not about. A bounded pump is enough to run _confirm's
    // SessionExpiredException branch.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Nothing to retry against: the session is gone, so the sheet must
    // not invite the user to try the same call again.
    expect(find.text('Retry'), findsNothing);
    expect(auth.triggerSosCallCount, 1);
  });
}
