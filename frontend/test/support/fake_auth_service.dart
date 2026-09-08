import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';

/// An [AuthService] that resolves everything immediately, no simulated
/// latency — same reasoning as [ImmediateMeetupService]'s own doc comment
/// (fake_meetup_service.dart): [MockAuthService]'s deliberate 600ms
/// latency is a pending-Timer trap for a test where some incidental call
/// (e.g. MatchesPage's fire-and-forget updateLastKnownLocation, ADR-021
/// §3) isn't what the test is actually about.
class ImmediateAuthService implements AuthService {
  // ADR-002 § 3.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  int updateLastKnownLocationCallCount = 0;
  double? lastUpdateLastKnownLocationLat;
  double? lastUpdateLastKnownLocationLng;

  @override
  Future<AuthSession> signInWithLinkedIn({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> signInWithApple({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> signInWithGoogle({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) => throw UnimplementedError();

  @override
  Future<int> startEmailLoginOtp(String email) => throw UnimplementedError();

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) => throw UnimplementedError();

  @override
  Future<AuthSession> linkLinkedIn() => throw UnimplementedError();

  @override
  Future<int> startEmailSignupOtp(String email) => throw UnimplementedError();

  @override
  Future<AuthSession> refreshSession(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<void> logout(String refreshToken) => throw UnimplementedError();

  @override
  Future<int> startPhoneVerification(String phoneNumber) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) =>
      throw UnimplementedError();

  @override
  Future<int> startPersonalEmailVerification(String email) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> submitPersonalDetails(String legalName, String address) =>
      throw UnimplementedError();

  @override
  Future<int> startCorporateEmailVerification(String email) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) => throw UnimplementedError();

  @override
  Future<UserProfile> getProfile() => throw UnimplementedError();

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) => throw UnimplementedError();

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) => throw UnimplementedError();

  @override
  Future<List<TrustedContact>> listTrustedContacts() =>
      throw UnimplementedError();

  @override
  Future<void> removeTrustedContact(String contactId) =>
      throw UnimplementedError();

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) => throw UnimplementedError();

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async {
    updateLastKnownLocationCallCount++;
    lastUpdateLastKnownLocationLat = latitude;
    lastUpdateLastKnownLocationLng = longitude;
  }
}
