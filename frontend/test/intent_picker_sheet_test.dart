import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_picker_sheet.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_secure_storage_platform.dart';

/// getProfile() is the only member [completeVerification] reaches below —
/// everything else is unreachable and throws if that assumption ever stops
/// holding. Same pattern as auth_session_provider_test.dart's own
/// `_FakeAuthService`.
class _FakeAuthService implements AuthService {
  _FakeAuthService(this._profile);

  final UserProfile _profile;

  @override
  Future<UserProfile> getProfile() async => _profile;

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

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async => throw UnimplementedError();

  @override
  Future<List<TrustedContact>> listTrustedContacts() async =>
      throw UnimplementedError();

  @override
  Future<void> removeTrustedContact(String contactId) async =>
      throw UnimplementedError();

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
}

class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

AuthSession _sessionAt(int trustLevel) => AuthSession(
  userId: 'user-1',
  accessToken: 'a1',
  refreshToken: 'r1',
  trustLevel: trustLevel,
  isNewUser: false,
  accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
  fullName: 'Ada Lovelace',
  profilePhotoUrl: '',
);

void main() {
  setUp(() {
    // completeVerification() below writes through the real
    // SecureSessionStorage/FlutterSecureStorage — without a fake platform
    // registered, that write hangs indefinitely under flutter_tester (no
    // real Keychain/Keystore channel available), same setup app_shell_test.dart
    // already needs for the same reason.
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets(
    'IntentPickerSheet watches trust level live — completing verification '
    'while the sheet is still open unlocks a tile immediately, without '
    'closing and reopening it (ADR-030, round-9 — this used to capture '
    'trustLevel once at construction instead of watching it live like the '
    'other 6 redirect sites)',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(
            () => _FakeAuthSessionNotifier(
              const AuthSessionState(
                profile: UserProfile(
                  id: 'user-1',
                  fullName: 'Ada',
                  trustLevel: 0,
                ),
              ),
            ),
          ),
          authServiceProvider.overrideWithValue(
            _FakeAuthService(
              const UserProfile(id: 'user-1', fullName: 'Ada', trustLevel: 2),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => IntentPickerSheet.show(context),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(find.text(IntentType.coffee.label), findsWidgets);

      // COFFEE requires trust level 2 (CLAUDE.md) — locked at 0.
      await tester.tap(find.text(IntentType.coffee.label));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      expect(find.textContaining('requires Level 2 trust'), findsOneWidget);

      // Back to the sheet, still open underneath — the locked tap never
      // closes it (matches every other redirect site's own behavior).
      Navigator.of(
        tester.element(find.byType(VerificationChecklistPage)),
      ).pop();
      await tester.pumpAndSettle();
      expect(find.byType(IntentPickerSheet), findsOneWidget);

      // Complete verification WITHOUT closing/reopening the sheet.
      await container
          .read(authSessionProvider.notifier)
          .completeVerification(_sessionAt(2));
      await tester.pumpAndSettle();

      // Now unlocked, live — tapping selects the intent and closes the
      // sheet; no redirect this time. This is what would have failed
      // before the fix (the sheet would still have enforced trustLevel 0,
      // captured at construction).
      await tester.tap(find.text(IntentType.coffee.label));
      await tester.pumpAndSettle();

      expect(find.byType(VerificationChecklistPage), findsNothing);
      expect(find.byType(IntentPickerSheet), findsNothing);
      expect(container.read(selectedIntentProvider), IntentType.coffee);
    },
  );
}
