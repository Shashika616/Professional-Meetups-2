import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
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
  // --- the claim-an-existing-account ceremony, scriptable ---

  /// Set to make [signInWithGoogle] report that the address is already on
  /// an account, which is what opens the claim sheet.
  AccountClaimRequiredException? googleClaimRequired;

  /// The code [completeAccountClaim] accepts. Anything else is rejected the
  /// way the server rejects a wrong one.
  String acceptedClaimCode = '123456';

  /// Recorded so a test can prove the sheet does NOT send a code on mount
  /// (the 409 already sent one) and does send one on Resend.
  int resendClaimCalls = 0;

  /// Recorded so a test can prove the ticket travels unchanged.
  String? claimedWithTicket;

  @override
  Future<AuthSession> completeAccountClaim({
    required String ticket,
    required String code,
  }) async {
    claimedWithTicket = ticket;
    if (code != acceptedClaimCode) {
      throw const InvalidVerificationCodeException(
        'That code is not right. Please check and try again.',
      );
    }
    return _claimedSession;
  }

  @override
  Future<int> resendAccountClaimCode(String ticket) async {
    resendClaimCalls++;
    claimedWithTicket = ticket;
    return 60;
  }

  /// The session a successful claim yields: the EXISTING account, so
  /// isNewUser is false and the trust level is whatever that account had.
  static final AuthSession _claimedSession = AuthSession(
    userId: 'existing-user-1',
    accessToken: 'claimed-access-token',
    refreshToken: 'claimed-refresh-token',
    trustLevel: 2,
    isNewUser: false,
    accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: '',
  );

  /// Settable so a widget test can script what another member's profile
  /// looks like; defaults to a plain Level-2 member with a phone badge.
  PublicProfile Function(String userId) publicProfileFor = (id) =>
      PublicProfile(
        id: id,
        fullName: 'Member $id',
        trustLevel: 2,
        phoneVerified: true,
      );

  @override
  Future<PublicProfile> getPublicProfile(String userId) async =>
      publicProfileFor(userId);

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
  Future<AuthSession> signInWithGoogle({required bool ageConfirmedOver18}) {
    final claim = googleClaimRequired;
    if (claim != null) throw claim;
    throw UnimplementedError();
  }

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
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) => throw UnimplementedError();

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
    double? latitude,
    double? longitude,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteAccount() async {}

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
