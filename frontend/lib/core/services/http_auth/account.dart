part of '../http_auth_service.dart';

/// The signed-in user's own profile, other members' public profiles, and
/// deleting the account.
mixin _AccountMethods on _HttpAuthBase {
  @override
  Future<UserProfile> getProfile() async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/users/me'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return UserProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<PublicProfile> getPublicProfile(String userId) async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/users/${Uri.encodeComponent(userId)}'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return PublicProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    // 403 is the relationship gate: the server's sentence says why, and the
    // page shows it as a state rather than an error. Handled here rather
    // than in the shared mapper so the verification endpoints' own 403
    // behaviour is untouched.
    if (response.statusCode == 403) {
      throw ForbiddenActionException(_errorMessage(response.body));
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async {
    final response = await _authenticatedPost('/v1/auth/profile-setup', {
      'full_name': fullName,
      'company_name': ?companyName,
      'company_email': ?companyEmail,
    });
    if (response.statusCode == 200) {
      return UserProfile.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<void> deleteAccount() async {
    final headers = await _authHeaders();
    final http.Response response;
    try {
      response = await _httpClient
          .delete(Uri.parse('$_baseUrl/v1/users/me'), headers: headers)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      // Offline, or the request never came back. Nothing was confirmed, so
      // the account is still there and the person can simply try again.
      throw const AuthNetworkException(
        'We couldn’t reach TieHere. Check your connection and try again.',
      );
    }
    switch (response.statusCode) {
      case 204:
        return;
      case 409:
        throw AccountDeletionBlockedException(_errorMessage(response.body));
      case 401:
        throw const SessionExpiredException(
          'Your session has expired. Please sign in again.',
        );
      case 429:
        throw const RateLimitedException();
      default:
        throw const AuthNetworkException(
          'We couldn’t delete your account just now. Please try again in a moment.',
        );
    }
  }
}
