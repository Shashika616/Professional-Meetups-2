import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';

import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  @override
  Future<PublicProfile> getPublicProfile(String userId) =>
      throw UnimplementedError('not exercised by this test');

  // ADR-002 § 3. Unused by this test — every fake in test/ implements the
  // full AuthService surface, so a new method lands here even when the test
  // never calls it.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  _FakeAuthService({List<TrustedContact>? contacts})
    : contacts = contacts ?? [];

  List<TrustedContact> contacts;
  int addCallCount = 0;
  int removeCallCount = 0;
  int _seq = 0;

  @override
  Future<List<TrustedContact>> listTrustedContacts() async => contacts;

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async {
    addCallCount++;
    final contact = TrustedContact(
      id: 'contact-${_seq++}',
      name: name,
      phoneNumber: phoneNumber,
      email: email,
    );
    contacts = [...contacts, contact];
    return contact;
  }

  @override
  Future<void> removeTrustedContact(String contactId) async {
    removeCallCount++;
    contacts = contacts.where((c) => c.id != contactId).toList();
  }

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

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

Widget _appWith(ProviderContainer container, {bool explainSosPrompt = false}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (context) =>
              ManageTrustedContactsPage(explainSosPrompt: explainSosPrompt),
        ),
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
  });

  testWidgets('empty state shows a prompt to add a contact', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    expect(find.textContaining('No trusted contacts yet'), findsOneWidget);
  });

  testWidgets(
    'the SOS-redirect banner only shows when explainSosPrompt is set',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container, explainSosPrompt: true));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Add at least one trusted contact before you can'),
        findsOneWidget,
      );
    },
  );

  testWidgets('adding a contact with a phone number calls addTrustedContact '
      'and shows it in the list', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ADD CONTACT'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Grace');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '+94771234567',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(auth.addCallCount, 1);
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('+94771234567'), findsOneWidget);
  });

  testWidgets('SAVE stays disabled with a name and an email but no phone: '
      'the phone is mandatory, the email optional', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ADD CONTACT'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Grace');
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'grace@example.com',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(auth.addCallCount, 0);

    // The number unlocks it; the email rides along.
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '+94771234567',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();
    expect(auth.addCallCount, 1);
  });

  testWidgets('removing a contact requires confirmation, then calls '
      'removeTrustedContact', (tester) async {
    final auth = _FakeAuthService(
      contacts: [
        const TrustedContact(
          id: 'c1',
          name: 'Grace',
          phoneNumber: '+94771234567',
          email: '',
        ),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.text('REMOVE CONTACT'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(auth.removeCallCount, 0);
    expect(find.text('Grace'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('REMOVE'));
    await tester.pumpAndSettle();

    expect(auth.removeCallCount, 1);
    expect(find.text('Grace'), findsNothing);
  });

  testWidgets('ADD CONTACT is disabled once the soft cap of 3 is reached', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: List.generate(
        maxTrustedContacts,
        (i) => TrustedContact(
          id: 'c$i',
          name: 'Contact $i',
          phoneNumber: '+9477000000$i',
          email: '',
        ),
      ),
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    // Disabled — tapping ADD CONTACT does not reveal the add-contact form.
    await tester.tap(find.text('ADD CONTACT'));
    await tester.pumpAndSettle();
    expect(find.text('SAVE'), findsNothing);
  });
}
