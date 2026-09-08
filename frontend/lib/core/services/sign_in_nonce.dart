import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The nonce pair for one Apple/Google sign-in attempt — kept in its own
/// file, separate from `HttpAuthService`, so generation is unit-testable in
/// isolation (same reasoning as [OAuthState], which does this for LinkedIn's
/// `state` parameter).
///
/// ## Why there are two values and not one
///
/// The backend rejects an Apple/Google `id_token` unless the caller can
/// present the PRE-IMAGE of the token's own `nonce` claim
/// (`backend/internal/modules/auth/identity`). So:
///
/// * [hashed] is handed to Apple/Google, and is what they embed in the
///   `id_token` as its `nonce` claim.
/// * [raw] is sent to our backend, which hashes it and compares.
///
/// Sending [hashed] to the backend instead would make the check decorative:
/// a JWT's claims are readable by anyone holding the token, so an attacker
/// who obtained an `id_token` could read the nonce straight out of it and
/// submit it back. [raw] is the part they cannot derive — it never appears
/// in the token, and never leaves the device except on the one request it
/// authorizes.
///
/// This is the construction Apple documents for Sign in with Apple, and the
/// same one Firebase's `OAuthProvider.credential(idToken:rawNonce:)` uses.
class SignInNonce {
  const SignInNonce({required this.raw, required this.hashed});

  /// A fresh, cryptographically random pair. 32 random bytes, base64url
  /// without padding — the same shape [OAuthState.generate] produces, for
  /// the same reason (safe to put in a header, a query string or a JSON
  /// body without escaping).
  factory SignInNonce.generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final raw = base64Url.encode(bytes).replaceAll('=', '');
    return SignInNonce(raw: raw, hashed: hashNonce(raw));
  }

  /// Sent to our backend. Never sent to Apple or Google.
  final String raw;

  /// Sent to Apple/Google as the sign-in request's nonce. Ends up inside the
  /// `id_token` they return, which is why it is useless on its own.
  final String hashed;

  /// SHA-256, lowercase hex — byte-for-byte the same definition as the
  /// backend's `identity.HashNonce`. Hex rather than base64 because it has
  /// exactly one encoding: no padding variants, no URL-safe alphabet, and so
  /// nothing for the two sides to disagree about.
  static String hashNonce(String raw) =>
      sha256.convert(utf8.encode(raw)).toString();
}
