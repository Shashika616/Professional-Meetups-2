import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';

import 'support/app_icon_finder.dart';

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

  _FakeAuthService({List<TrustedContact>? contacts})
    : contacts = contacts ?? [];

  List<TrustedContact> contacts;
  int addCallCount = 0;
  int removeCallCount = 0;
  int _seq = 0;

  int updateCallCount = 0;

  @override
  Future<TrustedContact> updateTrustedContact(
    String contactId, {
    required String name,
    required String phoneNumber,
  }) async {
    updateCallCount++;
    final contact = TrustedContact(
      id: contactId,
      name: name,
      phoneNumber: phoneNumber,
    );
    contacts = [for (final c in contacts) c.id == contactId ? contact : c];
    return contact;
  }

  @override
  Future<List<TrustedContact>> listTrustedContacts() async => contacts;

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    required String phoneNumber,
  }) async {
    addCallCount++;
    final contact = TrustedContact(
      id: 'contact-${_seq++}',
      name: name,
      phoneNumber: phoneNumber,
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
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
    String? source,
    String? clientRequestId,
  }) async => throw UnimplementedError();

  @override
  Future<String> uploadProfilePhoto(Uint8List jpeg) =>
      throw UnimplementedError();

  @override
  Future<void> deleteProfilePhoto() => throw UnimplementedError();

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

  // ADR-013: a contact is active from the moment they are added.
  testWidgets('a contact is a name and a number, with no waiting state', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: const [
        TrustedContact(id: 'a', name: 'Amma', phoneNumber: '+94771111111'),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    expect(find.text('Amma'), findsOneWidget);
    expect(find.text('1 of 2 added'), findsOneWidget);
    expect(find.textContaining('confirmation'), findsNothing);
    expect(find.textContaining('Only two contacts'), findsNothing);
  });

  testWidgets('at the cap it reads 2 of 2 added', (tester) async {
    final auth = _FakeAuthService(
      contacts: const [
        TrustedContact(id: 'a', name: 'Amma', phoneNumber: '+94771111111'),
        TrustedContact(id: 'b', name: 'Nimal', phoneNumber: '+94772222222'),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    expect(find.text('2 of 2 added'), findsOneWidget);
    expect(find.textContaining('Only two contacts'), findsNothing);
  });

  // D5: an account from before the cap keeps three, and is asked to remove
  // one.
  testWidgets('an account with 3 contacts is asked to remove one', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: const [
        TrustedContact(id: 'a', name: 'Amma', phoneNumber: '+94771111111'),
        TrustedContact(id: 'b', name: 'Nimal', phoneNumber: '+94772222222'),
        TrustedContact(id: 'c', name: 'Kumari', phoneNumber: '+94773333333'),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    expect(
      find.text('Only two contacts are alerted. Remove one.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Remove Kumari'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove contact'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Only two contacts'), findsNothing);
  });

  testWidgets('a contact can be edited, and the form has no email field', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: const [
        TrustedContact(id: 'a', name: 'Amma', phoneNumber: '+94771111111'),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit Amma'));
    await tester.pumpAndSettle();
    expect(find.text('Edit contact'), findsOneWidget);
    expect(find.textContaining('Email'), findsNothing);
    expect(
      find.textContaining('They get a text only if you press SOS'),
      findsOneWidget,
    );
    await tester.enterText(find.widgetWithText(TextField, 'Amma'), 'Thaththa');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.updateCallCount, 1);
    expect(find.text('Thaththa'), findsOneWidget);
  });

  testWidgets('empty state shows a prompt to add a contact', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    // The app's own card deck, not a line of grey text.
    expect(find.byType(EmptyStateDeck), findsOneWidget);
    expect(find.text('Nobody on your list yet'), findsOneWidget);
    expect(find.textContaining('trigger SOS'), findsOneWidget);
    // The way out is the page's own ADD CONTACT button, still there.
    expect(find.text('Add contact'), findsOneWidget);
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

    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Grace');
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '+94771234567',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.addCallCount, 1);
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('+94771234567'), findsOneWidget);
  });

  testWidgets('SAVE stays disabled without a phone number', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Grace');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(auth.addCallCount, 0);

    await tester.enterText(
      find.widgetWithText(TextField, 'Phone number'),
      '+94771234567',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
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
        ),
      ],
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(findAppIcon(AppIcons.trash));
    await tester.pumpAndSettle();

    expect(find.text('Remove contact?'), findsOneWidget);

    await tester.tap(find.widgetWithText(SecondaryButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(auth.removeCallCount, 0);
    expect(find.text('Grace'), findsOneWidget);

    await tester.tap(findAppIcon(AppIcons.trash));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PrimaryButton, 'Remove contact'));
    await tester.pumpAndSettle();

    expect(auth.removeCallCount, 1);
    expect(find.text('Grace'), findsNothing);
  });

  testWidgets('ADD CONTACT is disabled once the cap of 2 is reached', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      contacts: List.generate(
        maxTrustedContacts,
        (i) => TrustedContact(
          id: 'c$i',
          name: 'Contact $i',
          phoneNumber: '+9477000000$i',
        ),
      ),
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    // Disabled — tapping ADD CONTACT does not reveal the add-contact form.
    await tester.tap(find.text('Add contact'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsNothing);
  });
}
