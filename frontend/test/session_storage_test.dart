import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';

import 'support/fake_secure_storage_platform.dart';

void main() {
  late FakeSecureStoragePlatform fakePlatform;
  late SecureSessionStorage storage;

  setUp(() {
    fakePlatform = FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = fakePlatform;
    storage = SecureSessionStorage(storage: const FlutterSecureStorage());
  });

  final session = AuthSession(
    userId: 'user-1',
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    trustLevel: 1,
    isNewUser: true,
    accessTokenExpiresAt: DateTime.utc(2026, 1, 1, 12),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: 'https://example.com/p.jpg',
  );

  test('loadSession returns null when nothing has been saved', () async {
    expect(await storage.loadSession(), isNull);
  });

  test('saveSession then loadSession round-trips the session', () async {
    await storage.saveSession(session);
    final loaded = await storage.loadSession();

    expect(loaded, isNotNull);
    expect(loaded!.userId, session.userId);
    expect(loaded.accessToken, session.accessToken);
    expect(loaded.refreshToken, session.refreshToken);
    expect(loaded.trustLevel, session.trustLevel);
    expect(loaded.fullName, session.fullName);
    expect(loaded.profilePhotoUrl, session.profilePhotoUrl);
    expect(loaded.accessTokenExpiresAt, session.accessTokenExpiresAt);
    // isNewUser is only meaningful in the moment-of-sign-in response, not
    // once reloaded from storage.
    expect(loaded.isNewUser, isFalse);
  });

  test('clearSession removes everything this wrapper wrote', () async {
    await storage.saveSession(session);
    await storage.clearSession();

    expect(await storage.loadSession(), isNull);
    expect(fakePlatform.values, isEmpty);
  });
}
