import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A signed-in session, parsed from the gateway's `/v1/auth/linkedin/callback`,
/// `/v1/auth/refresh` response shape (`backend/PLAN.md` Step 5's REST
/// contract). Distinct from [UserProfile] — this is transport/session state
/// (tokens, expiry), not the profile shown in the UI.
@immutable
class AuthSession {
  const AuthSession({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
    required this.trustLevel,
    required this.isNewUser,
    required this.accessTokenExpiresAt,
    required this.fullName,
    required this.profilePhotoUrl,
    this.suggestedNameUpdate = '',
  });

  final String userId;
  final String accessToken;
  final String refreshToken;

  /// Not a field in the JSON response body — the gateway's `SessionResponse`
  /// doesn't carry one. It's embedded in the signed `access_token`'s claims
  /// instead (`shared/jwt.Claims.TrustLevel`), so this is read by decoding
  /// the JWT payload client-side. That decode is display-only and doesn't
  /// verify the signature — the server remains the sole source of truth for
  /// anything that actually depends on trust level being correct.
  final int trustLevel;

  final bool isNewUser;
  final DateTime accessTokenExpiresAt;

  /// Captured once, from this same response, at sign-in time — there is no
  /// `GET /v1/users/me` endpoint yet to refetch these from later.
  final String fullName;
  final String profilePhotoUrl;

  /// What LinkedIn calls this person, when that differs from the name
  /// already on the account and the account just linked LinkedIn (Plan 22).
  /// Empty on every other response, including every sign-in.
  ///
  /// A SUGGESTION to offer, not a change the server made: linking LinkedIn
  /// deliberately never rewrites a name the user already has, so [fullName]
  /// above is still the real one. Acting on it means the user saying yes,
  /// which goes through the ordinary self-edit name update (ADR-023 §5).
  ///
  /// Not persisted by [SessionStorage] on purpose — it belongs to the one
  /// link event that produced it, and a suggestion that survived a restart
  /// would be asked again forever.
  final String suggestedNameUpdate;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token'] as String;
    final expiresInSeconds = json['expires_in'] as int;
    return AuthSession(
      userId: json['user_id'] as String,
      accessToken: accessToken,
      refreshToken: json['refresh_token'] as String,
      trustLevel: trustLevelFromAccessToken(accessToken),
      isNewUser: json['is_new_user'] as bool,
      accessTokenExpiresAt: DateTime.now().add(
        Duration(seconds: expiresInSeconds),
      ),
      fullName: json['full_name'] as String? ?? '',
      profilePhotoUrl: json['profile_photo_url'] as String? ?? '',
      // Absent from every response but a LinkedIn link's (the gateway omits
      // it entirely rather than sending ""), so the null case is the norm.
      suggestedNameUpdate: json['suggested_name_update'] as String? ?? '',
    );
  }

  /// Decodes the (unverified) middle segment of a JWT and reads its
  /// `trust_level` claim. Returns 0 (the lowest trust level) if the token
  /// is malformed or the claim is missing, rather than throwing — this is
  /// a UI-gating hint, not a security check, so failing open to "least
  /// trusted" is the safe default.
  @visibleForTesting
  static int trustLevelFromAccessToken(String accessToken) {
    final parts = accessToken.split('.');
    if (parts.length != 3) return 0;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(normalized)))
              as Map<String, dynamic>;
      final trustLevel = payload['trust_level'];
      return trustLevel is int ? trustLevel : 0;
    } catch (_) {
      return 0;
    }
  }
}
