// The constructor's public parameter names (storage/refreshSession/
// expiryBuffer, matching this addendum's exact spec and
// app_providers.dart's call site) deliberately differ from this class's
// private field names — an initializing formal would force them to match
// and leak the underscore into the public API.
// ignore_for_file: prefer_initializing_formals

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';

/// Proactively refreshes the stored access token before it expires, and
/// persists the result — the piece that was missing (`frontend/PLAN.md`'s
/// "Session refresh wiring fix" addendum): `HttpAuthService.refreshSession()`
/// was fully implemented but nothing ever called it, so a session silently
/// went dead after 15 minutes even though its refresh token was still good
/// for 30 days.
///
/// Not a Riverpod notifier and not session state of its own — `AuthSession`
/// in [SecureSessionStorage] remains the single source of truth, same
/// principle `HttpAuthService` already follows for its own `getAccessToken`
/// callback.
class TokenRefresher {
  TokenRefresher({
    required SecureSessionStorage storage,
    required Future<AuthSession> Function(String refreshToken) refreshSession,
    Duration expiryBuffer = const Duration(seconds: 30),
  }) : _storage = storage,
       _refreshSession = refreshSession,
       _expiryBuffer = expiryBuffer;

  final SecureSessionStorage _storage;
  final Future<AuthSession> Function(String refreshToken) _refreshSession;
  final Duration _expiryBuffer;

  // Single-flighted: the backend rotates refresh tokens on every use with
  // reuse/replay detection, so two concurrent callers both reading the same
  // now-stale refresh token and both POSTing it would have the second one
  // rejected as a replay — incorrectly killing a perfectly good session.
  // Caching the in-flight future and handing it to every concurrent caller
  // avoids that.
  Future<AuthSession>? _inFlightRefresh;

  /// Full session, refreshed and persisted first if the stored access token
  /// is expired or within [_expiryBuffer] of expiring. Null if no session is
  /// stored at all. Rethrows whatever `refreshSession()` throws
  /// (`SessionExpiredException` on a rejected/rotated-away refresh token,
  /// `AuthNetworkException` on a transient failure) after clearing the
  /// stored session — a rejected refresh token really does mean the session
  /// is gone; a network blip clearing storage is an acceptable
  /// simplification here since there's no good way to distinguish the two
  /// from a single failed HTTP call, and re-login is always a safe fallback
  /// even for the network-blip case.
  Future<AuthSession?> getValidSession() async {
    final session = await _storage.loadSession();
    if (session == null) return null;

    if (session.accessTokenExpiresAt.isAfter(
      DateTime.now().add(_expiryBuffer),
    )) {
      return session;
    }

    return _refresh(session);
  }

  /// Convenience wrapper for the `getAccessToken` callback shape
  /// [HttpAuthService] already expects.
  Future<String?> getValidAccessToken() async =>
      (await getValidSession())?.accessToken;

  Future<AuthSession> _refresh(AuthSession stale) {
    return _inFlightRefresh ??= _doRefresh(stale).whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<AuthSession> _doRefresh(AuthSession stale) async {
    try {
      final refreshed = await _refreshSession(stale.refreshToken);
      await _storage.saveSession(refreshed);
      return refreshed;
    } catch (_) {
      await _storage.clearSession();
      rethrow;
    }
  }
}
