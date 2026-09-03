import 'package:flutter/foundation.dart';

/// A user's emergency trusted contact (ADR-026) — stored server-side in
/// auth's own database (ADR-017 DB split), never in meetup's. At least one
/// of [phoneNumber]/[email] is always non-empty (server-enforced,
/// `AuthService.addTrustedContact` mirrors the same check client-side for
/// instant UI feedback only).
@immutable
class TrustedContact {
  const TrustedContact({
    required this.id,
    required this.name,
    required this.phoneNumber,
    required this.email,
  });

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id'] as String,
      name: json['name'] as String,
      phoneNumber: json['phone_number'] as String? ?? '',
      email: json['email'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String phoneNumber;
  final String email;
}
