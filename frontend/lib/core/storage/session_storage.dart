import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';

/// The one place access/refresh tokens ever touch disk — Keychain on iOS,
/// Keystore-backed EncryptedSharedPreferences on Android (ADR-009). No
/// service or widget should call `flutter_secure_storage` directly; go
/// through this wrapper instead.
class SecureSessionStorage {
  SecureSessionStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _accessTokenKey = 'auth.access_token';
  static const _refreshTokenKey = 'auth.refresh_token';
  static const _userIdKey = 'auth.user_id';
  static const _trustLevelKey = 'auth.trust_level';
  static const _expiresAtKey = 'auth.access_token_expires_at';
  static const _fullNameKey = 'auth.full_name';
  static const _profilePhotoUrlKey = 'auth.profile_photo_url';

  static const _allKeys = [
    _accessTokenKey,
    _refreshTokenKey,
    _userIdKey,
    _trustLevelKey,
    _expiresAtKey,
    _fullNameKey,
    _profilePhotoUrlKey,
  ];

  Future<void> saveSession(AuthSession session) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: session.accessToken),
      _storage.write(key: _refreshTokenKey, value: session.refreshToken),
      _storage.write(key: _userIdKey, value: session.userId),
      _storage.write(key: _trustLevelKey, value: session.trustLevel.toString()),
      _storage.write(
        key: _expiresAtKey,
        value: session.accessTokenExpiresAt.toIso8601String(),
      ),
      _storage.write(key: _fullNameKey, value: session.fullName),
      _storage.write(key: _profilePhotoUrlKey, value: session.profilePhotoUrl),
    ]);
  }

  /// Returns null if no session (or an incomplete one) is stored.
  Future<AuthSession?> loadSession() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    final userId = await _storage.read(key: _userIdKey);
    if (accessToken == null || refreshToken == null || userId == null) {
      return null;
    }

    final trustLevelRaw = await _storage.read(key: _trustLevelKey);
    final expiresAtRaw = await _storage.read(key: _expiresAtKey);

    return AuthSession(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
      trustLevel: int.tryParse(trustLevelRaw ?? '') ?? 0,
      // Only meaningful in the response returned at the moment of sign-in;
      // a session loaded back from storage was never new.
      isNewUser: false,
      accessTokenExpiresAt: expiresAtRaw != null
          ? DateTime.parse(expiresAtRaw)
          : DateTime.now(),
      fullName: await _storage.read(key: _fullNameKey) ?? '',
      profilePhotoUrl: await _storage.read(key: _profilePhotoUrlKey) ?? '',
    );
  }

  Future<void> clearSession() async {
    await Future.wait(_allKeys.map((key) => _storage.delete(key: key)));
  }
}
