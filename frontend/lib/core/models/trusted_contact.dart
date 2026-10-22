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
    this.status = TrustedContactStatus.confirmed,
  });

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id'] as String,
      name: json['name'] as String,
      phoneNumber: json['phone_number'] as String? ?? '',
      email: json['email'] as String? ?? '',
      status: TrustedContactStatus.fromWire(json['status'] as String?),
    );
  }

  final String id;
  final String name;
  final String phoneNumber;
  final String email;

  /// Whether this contact has agreed to receive alerts (#80). Only a
  /// confirmed contact is alerted.
  final TrustedContactStatus status;
}

/// A trusted contact's consent state (#80).
enum TrustedContactStatus {
  confirmed,

  /// Texted a link to agree, has not used it yet.
  pending,

  /// The link lapsed unused; remove and add them again to send a new one.
  expired;

  /// An absent or unknown value reads as confirmed: a server older than
  /// consent sends no status, and every contact it has is confirmed.
  static TrustedContactStatus fromWire(String? value) => switch (value) {
    'pending' => pending,
    'expired' => expired,
    _ => confirmed,
  };
}
