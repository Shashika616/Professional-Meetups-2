part of '../http_auth_service.dart';

/// The trust-level verifications: phone, personal email, personal
/// details and work email.
mixin _VerificationMethods on _HttpAuthBase {
  @override
  Future<int> startPhoneVerification(String phoneNumber) => _startVerification(
    '/v1/verification/phone/start',
    {'phone_number': phoneNumber},
  );

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) =>
      _verifyCode('/v1/verification/phone/verify', {
        'phone_number': phoneNumber,
        'code': code,
      });

  @override
  Future<int> startPersonalEmailVerification(String email) =>
      _startVerification('/v1/verification/personal-email/start', {
        'email': email,
      });

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) =>
      _verifyCode('/v1/verification/personal-email/verify', {
        'email': email,
        'code': code,
      });

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async {
    final response = await _authenticatedPost(
      '/v1/verification/personal-details',
      {'legal_name': legalName, 'address': address},
    );
    return _parseVerificationSession(response);
  }

  @override
  Future<int> startCorporateEmailVerification(String email) =>
      _startVerification('/v1/verification/corporate-email/start', {
        'email': email,
      }, on400: (message) => WorkEmailDomainRejectedException(message));

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) => _verifyCode('/v1/verification/corporate-email/verify', {
    'email': email,
    'code': code,
    'company_name': companyName,
  });
}
