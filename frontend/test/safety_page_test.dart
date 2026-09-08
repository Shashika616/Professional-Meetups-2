import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';

import 'support/fake_geolocator_platform.dart';
import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
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
  }) : _contacts = contacts ?? [];

  final List<TrustedContact> _contacts;
  final int? triggerSosResult;
  final Object? triggerSosError;
  int triggerSosCallCount = 0;

  @override
  Future<List<TrustedContact>> listTrustedContacts() async => _contacts;

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) async {
    triggerSosCallCount++;
    if (triggerSosError != null) throw triggerSosError!;
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
  Future<void> logout(String refreshToken) async {}

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

ProviderContainer _containerWith(_FakeAuthService auth) {
  return ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
    ],
  );
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      position: testPosition(),
    );
  });

  testWidgets(
    'zero contacts routes to the manage-contacts screen instead of the '
    'confirm dialog',
    (tester) async {
      final auth = _FakeAuthService(contacts: []);
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('TRIGGER SOS'));
      await tester.pumpAndSettle();

      expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
      expect(find.text('EMERGENCY SOS'), findsNothing);
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

    await tester.tap(find.text('TRIGGER SOS'));
    await tester.pumpAndSettle();
    expect(find.text('EMERGENCY SOS'), findsOneWidget);

    await tester.tap(find.text('CONFIRM'));
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

    await tester.tap(find.text('TRIGGER SOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CONFIRM'));
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

      await tester.tap(find.text('TRIGGER SOS'));
      await tester.pumpAndSettle();

      // Present before CONFIRM is even tapped...
      expect(find.text('CALL EMERGENCY SERVICES'), findsOneWidget);

      await tester.tap(find.text('CONFIRM'));
      await tester.pumpAndSettle();

      // ...and still present after a failed trigger.
      expect(find.text('CALL EMERGENCY SERVICES'), findsOneWidget);
    },
  );
}
