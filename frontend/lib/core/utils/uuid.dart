import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The UUIDs the billing and analytics flows need, without a package for
/// them.

/// A random (version 4) UUID, from the platform's secure random source:
/// the Idempotency-Key of one meetup creation.
String uuidV4() {
  final random = Random.secure();
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _format(b);
}

/// A time-ordered (version 7) UUID, RFC 9562: 48 bits of Unix milliseconds,
/// then random bits. Analytics event ids (plan 29 §4.2): unique like v4,
/// and they sort by when the event happened.
String uuidV7([DateTime? at]) {
  final random = Random.secure();
  final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _format(b);
}

/// A name-based (version 5, SHA-1) UUID, as RFC 4122 defines it: the same
/// value Go's `uuid.NewSHA1` gives for the same namespace and name.
String uuidV5(String namespace, String name) {
  final ns = _parse(namespace);
  final hash = sha1.convert([...ns, ...utf8.encode(name)]).bytes;
  final b = hash.sublist(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _format(b);
}

/// The namespace the server derives account tokens under
/// (`billing.AccountTokenNamespace`, docs/api/billing.md). Changing it
/// orphans every purchase made before the change.
const String accountTokenNamespace = '2cea7eda-3ade-4a4a-8872-aba93a04a532';

/// What a purchase by [userId] carries as `applicationUserName` (Apple's
/// appAccountToken, Google's obfuscatedAccountId). The server refuses a
/// purchase whose token is not this, which is what stops a receipt being
/// replayed on another account.
String accountToken(String userId) =>
    uuidV5(accountTokenNamespace, userId.toLowerCase());

List<int> _parse(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) throw FormatException('not a UUID: $uuid');
  return [
    for (var i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

String _format(List<int> b) {
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
