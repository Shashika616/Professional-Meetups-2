import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';

/// Builds a fake JWT with the given claims in its (unsigned, for test
/// purposes) payload segment — enough to exercise
/// `AuthSession.trustLevelFromAccessToken`'s decoding, which never checks
/// the signature (that's the server's job).
String _fakeJwt(Map<String, dynamic> claims) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256'})}.${segment(claims)}.fake-signature';
}

void main() {
  group('AuthSession.trustLevelFromAccessToken', () {
    test('reads the trust_level claim from a well-formed token', () {
      final token = _fakeJwt({'trust_level': 3, 'user_id': 'user-1'});
      expect(AuthSession.trustLevelFromAccessToken(token), 3);
    });

    test('defaults to 0 for a malformed token', () {
      expect(AuthSession.trustLevelFromAccessToken('not-a-jwt'), 0);
    });

    test('defaults to 0 when the claim is missing', () {
      final token = _fakeJwt({'user_id': 'user-1'});
      expect(AuthSession.trustLevelFromAccessToken(token), 0);
    });
  });

  group('AuthSession.fromJson', () {
    test('parses a successful /v1/auth/linkedin/callback response', () {
      final accessToken = _fakeJwt({'trust_level': 1, 'user_id': 'user-1'});
      final json = {
        'user_id': 'user-1',
        'access_token': accessToken,
        'refresh_token': 'refresh-token',
        'expires_in': 900,
        'is_new_user': true,
        'full_name': 'Ada Lovelace',
        'profile_photo_url': 'https://example.com/p.jpg',
      };

      final session = AuthSession.fromJson(json);

      expect(session.userId, 'user-1');
      expect(session.accessToken, accessToken);
      expect(session.refreshToken, 'refresh-token');
      expect(session.trustLevel, 1);
      expect(session.isNewUser, isTrue);
      expect(session.fullName, 'Ada Lovelace');
      expect(session.profilePhotoUrl, 'https://example.com/p.jpg');
      expect(
        session.accessTokenExpiresAt.difference(DateTime.now()).inSeconds,
        closeTo(900, 5),
      );
    });

    test('tolerates a response with full_name/profile_photo_url omitted', () {
      final json = {
        'user_id': 'user-1',
        'access_token': _fakeJwt({'trust_level': 0}),
        'refresh_token': 'refresh-token',
        'expires_in': 900,
        'is_new_user': false,
      };

      final session = AuthSession.fromJson(json);

      expect(session.fullName, '');
      expect(session.profilePhotoUrl, '');
    });
  });
}
