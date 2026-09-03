import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/token_refresher.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';

import 'support/fake_secure_storage_platform.dart';

AuthSession _sessionExpiringIn(Duration delta, {String accessToken = 'a1'}) {
  return AuthSession(
    userId: 'user-1',
    accessToken: accessToken,
    refreshToken: 'refresh-1',
    trustLevel: 1,
    isNewUser: false,
    accessTokenExpiresAt: DateTime.now().add(delta),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: '',
  );
}

void main() {
  late SecureSessionStorage storage;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    storage = SecureSessionStorage(storage: const FlutterSecureStorage());
  });

  test('returns null when no session is stored', () async {
    var refreshCalls = 0;
    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async {
        refreshCalls++;
        throw StateError('should never be called');
      },
    );

    expect(await refresher.getValidSession(), isNull);
    expect(refreshCalls, 0);
  });

  test('returns the cached session unchanged when not expiring soon, without '
      'calling refreshSession', () async {
    final fresh = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(fresh);

    var refreshCalls = 0;
    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async {
        refreshCalls++;
        throw StateError('should never be called');
      },
    );

    final result = await refresher.getValidSession();

    expect(result?.accessToken, 'a1');
    expect(refreshCalls, 0);
  });

  test(
    'refreshes and persists when the stored token is already expired',
    () async {
      final stale = _sessionExpiringIn(const Duration(minutes: -1));
      await storage.saveSession(stale);

      final refreshed = _sessionExpiringIn(
        const Duration(minutes: 15),
        accessToken: 'a2',
      );
      var refreshCalls = 0;
      final refresher = TokenRefresher(
        storage: storage,
        refreshSession: (token) async {
          refreshCalls++;
          expect(token, 'refresh-1');
          return refreshed;
        },
      );

      final result = await refresher.getValidSession();

      expect(result?.accessToken, 'a2');
      expect(refreshCalls, 1);

      final persisted = await storage.loadSession();
      expect(persisted?.accessToken, 'a2');
    },
  );

  test('refreshes when the stored token is within the expiry buffer, even '
      'though not technically expired yet', () async {
    final aboutToExpire = _sessionExpiringIn(const Duration(seconds: 5));
    await storage.saveSession(aboutToExpire);

    final refreshed = _sessionExpiringIn(
      const Duration(minutes: 15),
      accessToken: 'a2',
    );
    var refreshCalls = 0;
    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async {
        refreshCalls++;
        return refreshed;
      },
    );

    final result = await refresher.getValidSession();

    expect(result?.accessToken, 'a2');
    expect(refreshCalls, 1);
  });

  test('two concurrent getValidSession() calls against an expired token result '
      'in exactly one refreshSession() call (single-flight)', () async {
    final stale = _sessionExpiringIn(const Duration(minutes: -1));
    await storage.saveSession(stale);

    var refreshCalls = 0;
    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async {
        refreshCalls++;
        // Give both concurrent callers a chance to have already called
        // getValidSession() before this resolves, so a non-single-flighted
        // implementation would have already fired a second call by now.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _sessionExpiringIn(
          const Duration(minutes: 15),
          accessToken: 'a2',
        );
      },
    );

    final results = await Future.wait([
      refresher.getValidSession(),
      refresher.getValidSession(),
    ]);

    expect(refreshCalls, 1);
    expect(results[0]?.accessToken, 'a2');
    expect(results[1]?.accessToken, 'a2');
  });

  test('clears storage and rethrows when refreshSession() throws', () async {
    final stale = _sessionExpiringIn(const Duration(minutes: -1));
    await storage.saveSession(stale);

    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async =>
          throw const SessionExpiredException('refresh token rejected'),
    );

    await expectLater(
      refresher.getValidSession(),
      throwsA(isA<SessionExpiredException>()),
    );

    expect(await storage.loadSession(), isNull);
  });

  test('getValidAccessToken() returns just the access token string', () async {
    final fresh = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(fresh);

    final refresher = TokenRefresher(
      storage: storage,
      refreshSession: (token) async =>
          throw StateError('should never be called'),
    );

    expect(await refresher.getValidAccessToken(), 'a1');
  });
}
