// The constructor's public parameter names (storage/refreshSession/
// expiryBuffer, matching this addendum's exact spec and
// app_providers.dart's call site) deliberately differ from this class's
// private field names — an initializing formal would force them to match
// and leak the underscore into the public API.
// ignore_for_file: prefer_initializing_formals

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
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
  /// stored at all. Rethrows whatever `refreshSession()` throws.
  ///
  /// ONLY A REJECTED REFRESH TOKEN CLEARS THE SESSION (V-17a). The two
  /// failures are distinguishable, despite what this comment used to say: a
  /// 401 from `/v1/auth/refresh` arrives as [SessionExpiredException], and
  /// everything else — offline, a timeout, the backend cold-starting or
  /// answering 5xx — arrives as something else and says nothing about the
  /// token. Clearing on those signed users out whenever their network was
  /// slow, which with a 15 s request deadline meant one slow refresh on a
  /// train. Now the stored session survives and the next call retries.
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
    } on SessionExpiredException {
      // Anything else is not evidence the session is dead, so it propagates
      // without touching storage: see getValidSession's comment.
      // ONE LAST LOOK BEFORE DECLARING THE SESSION DEAD.
      //
      // [_inFlightRefresh] single-flights concurrent callers, but only the
      // ones that reach [_refresh] while a refresh is actually in flight.
      // A caller whose loadSession() read was SERVED BEFORE the save above
      // and RETURNED AFTER the in-flight future was cleared holds a token
      // that has already been spent, sees no refresh running, and spends
      // it again. The backend's reuse detection is working exactly as
      // designed when it rejects that — and the result was that a valid,
      // freshly refreshed session got cleared from storage and the user
      // was bounced to the sign-in screen for no reason.
      //
      // So: re-read storage. A session there with a DIFFERENT refresh
      // token than the one that just failed can only have been written by
      // another refresh that succeeded, and if its access token is still
      // good it is the right answer to return. Nothing else in the app
      // writes a session with a different refresh token while this one is
      // running.
      //
      // Deliberately narrow. It does not retry, does not swallow the error
      // in any other case, and a genuinely rejected token (same value
      // still stored, or nothing stored) falls through to the clear-and-
      // rethrow below exactly as before, one storage read later.
      final current = await _storage.loadSession();
      if (current != null &&
          current.refreshToken != stale.refreshToken &&
          current.accessTokenExpiresAt.isAfter(
            DateTime.now().add(_expiryBuffer),
          )) {
        return current;
      }
      await _storage.clearSession();
      rethrow;
    }
  }
}
