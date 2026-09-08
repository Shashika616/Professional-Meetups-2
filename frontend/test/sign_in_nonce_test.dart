import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/services/sign_in_nonce.dart';

void main() {
  group('SignInNonce', () {
    test('generates a different pair every time', () {
      final raws = <String>{};
      final hashes = <String>{};
      for (var i = 0; i < 100; i++) {
        final nonce = SignInNonce.generate();
        raws.add(nonce.raw);
        hashes.add(nonce.hashed);
      }
      expect(
        raws,
        hasLength(100),
        reason: 'a repeated raw nonce would let one attempt authorize another',
      );
      expect(hashes, hasLength(100));
    });

    test('raw is long enough to be unguessable', () {
      // 32 random bytes, base64url without padding.
      final nonce = SignInNonce.generate();
      expect(nonce.raw.length, greaterThanOrEqualTo(42));
      expect(nonce.raw, isNot(contains('=')));
      expect(
        nonce.raw,
        matches(RegExp(r'^[A-Za-z0-9_-]+$')),
        reason: 'must survive a JSON body and a query string without escaping',
      );
    });

    test('hashed is the SHA-256 of raw, lowercase hex', () {
      final nonce = SignInNonce.generate();
      final expected = sha256.convert(utf8.encode(nonce.raw)).toString();

      expect(nonce.hashed, expected);
      expect(
        nonce.hashed,
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason:
            'the backend (identity.HashNonce) produces lowercase hex; any other encoding silently fails to match',
      );
    });

    test('hashed is not the raw value', () {
      // The entire protection rests on these being different: the provider
      // (and therefore the id_token, and therefore anyone holding it) only
      // ever sees `hashed`, while the backend requires `raw`.
      final nonce = SignInNonce.generate();
      expect(nonce.hashed, isNot(nonce.raw));
    });

    test('hashNonce matches the backend definition on a known vector', () {
      // Pinned so a change to either side's hashing shows up as a test
      // failure here rather than as a production sign-in outage. Same vector
      // is asserted in the backend's own identity tests.
      expect(
        SignInNonce.hashNonce('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('hashNonce is deterministic', () {
      expect(
        SignInNonce.hashNonce('same-input'),
        SignInNonce.hashNonce('same-input'),
      );
    });
  });
}
