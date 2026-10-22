import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/token_refresher.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';

import 'support/fake_secure_storage_platform.dart';

AuthSession _sessionExpiringIn(
  Duration delta, {
  String accessToken = 'a1',
  // Only the reuse-detection tests care which refresh token a session
  // carries; everything else keeps the original single value.
  String refreshToken = 'refresh-1',
}) {
  return AuthSession(
    userId: 'user-1',
    accessToken: accessToken,
    refreshToken: refreshToken,
    trustLevel: 1,
    isNewUser: false,
    accessTokenExpiresAt: DateTime.now().add(delta),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: '',
  );
}

/// Serves exactly one STALE read once [armed], then behaves normally.
///
/// This is the interleaving `_doRefresh` guards against, and it cannot be
/// produced through one real storage: the caller has to be holding a
/// session that storage itself has already replaced. A read that was
/// SERVED before the refresh's save and RETURNED after the in-flight
/// future was cleared is exactly that, and this reproduces it exactly once
/// and deterministically.
class _StaleReadOnceStorage extends SecureSessionStorage {
  _StaleReadOnceStorage({required this.stale})
    : super(storage: const FlutterSecureStorage());

  final AuthSession stale;
  bool armed = false;
  bool _served = false;

  @override
  Future<AuthSession?> loadSession() async {
    if (armed && !_served) {
      _served = true;
      return stale;
    }
    return super.loadSession();
  }
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

  // V-17a. A network failure is not evidence the session is dead. It used to
  // clear storage exactly like a rejected token, so one slow refresh — with
  // a 15 s request deadline, an ordinary moment on a train — signed the user
  // out.
  for (final (name, failure) in [
    ('offline', const AuthNetworkException('no connection')),
    ('timed out', const AuthNetworkException('timed out')),
  ]) {
    test(
      'keeps the stored session when the refresh fails because $name',
      () async {
        final stale = _sessionExpiringIn(const Duration(minutes: -1));
        await storage.saveSession(stale);

        final refresher = TokenRefresher(
          storage: storage,
          refreshSession: (token) async => throw failure,
        );

        await expectLater(
          refresher.getValidSession(),
          throwsA(isA<AuthNetworkException>()),
        );

        final kept = await storage.loadSession();
        expect(
          kept,
          isNotNull,
          reason: 'a network failure signed the user out',
        );
        expect(kept!.refreshToken, stale.refreshToken);
      },
    );
  }

  test(
    'the kept session refreshes normally once the network is back',
    () async {
      final stale = _sessionExpiringIn(const Duration(minutes: -1));
      await storage.saveSession(stale);

      var online = false;
      final refresher = TokenRefresher(
        storage: storage,
        refreshSession: (token) async {
          if (!online) throw const AuthNetworkException('no connection');
          return _sessionExpiringIn(
            const Duration(minutes: 15),
            accessToken: 'a2',
            refreshToken: 'refresh-2',
          );
        },
      );

      await expectLater(refresher.getValidSession(), throwsA(anything));
      online = true;
      final session = await refresher.getValidSession();
      expect(session?.accessToken, 'a2');
    },
  );

  // The hole single-flighting alone leaves. See _doRefresh's comment.
  group('a caller holding a token another refresh already spent', () {
    test('returns the session that refresh wrote, instead of being logged '
        'out by the backend\'s own reuse detection', () async {
      final stale = _sessionExpiringIn(const Duration(minutes: -1));
      final staleStorage = _StaleReadOnceStorage(stale: stale);
      await staleStorage.saveSession(stale);

      var refreshCalls = 0;
      final refresher = TokenRefresher(
        storage: staleStorage,
        refreshSession: (token) async {
          refreshCalls++;
          if (token != 'refresh-1') {
            throw StateError('unexpected token $token');
          }
          // The second presentation of the same refresh token is a replay
          // as far as the backend is concerned, and it says so.
          if (refreshCalls > 1) {
            throw const SessionExpiredException('refresh token reused');
          }
          return _sessionExpiringIn(
            const Duration(minutes: 15),
            accessToken: 'a2',
            refreshToken: 'refresh-2',
          );
        },
      );

      // The refresh that wins: storage now holds refresh-2.
      expect((await refresher.getValidSession())?.accessToken, 'a2');

      // The straggler, still holding refresh-1 and seeing no refresh in
      // flight. Its own call is rejected — and it must still come back
      // with the good session rather than wiping it.
      staleStorage.armed = true;
      final late = await refresher.getValidSession();

      expect(refreshCalls, 2, reason: 'the straggler did spend its token');
      expect(late?.accessToken, 'a2');
      expect(
        (await staleStorage.loadSession())?.accessToken,
        'a2',
        reason: 'a valid session must not be cleared out from under the app',
      );
    });

    test('a genuinely rejected token is still cleared and rethrown — the '
        'recovery must not swallow a real expiry', () async {
      final stale = _sessionExpiringIn(const Duration(minutes: -1));
      final staleStorage = _StaleReadOnceStorage(stale: stale);
      await staleStorage.saveSession(stale);

      final refresher = TokenRefresher(
        storage: staleStorage,
        refreshSession: (token) async =>
            throw const SessionExpiredException('refresh token rejected'),
      );

      // Armed, so the re-read also sees the SAME refresh token the failed
      // call used: nothing else succeeded, so there is nothing to recover.
      staleStorage.armed = true;
      await expectLater(
        refresher.getValidSession(),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(await staleStorage.loadSession(), isNull);
    });
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
