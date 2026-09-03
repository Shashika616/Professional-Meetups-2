import 'dart:convert';
import 'dart:math';

/// Generates the `state` parameter LinkedIn's OAuth flow uses for CSRF
/// protection (RFC 6749 §10.12) — kept in its own file, separate from
/// [HttpAuthService], so generation is unit-testable in isolation.
///
/// This was originally part of a PKCE helper (`code_verifier`/
/// `code_challenge`) per ADR-011, but LinkedIn's Sign In with LinkedIn /
/// OpenID Connect product rejects the token exchange outright when PKCE
/// parameters are present (confirmed via direct testing against LinkedIn's
/// real endpoint) — PKCE was removed, and `state` is the only value this
/// still needs to generate.
abstract final class OAuthState {
  /// A fresh, cryptographically random value every call — 32 random bytes,
  /// base64url-encoded without padding, safe to embed directly in a query
  /// parameter.
  static String generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
