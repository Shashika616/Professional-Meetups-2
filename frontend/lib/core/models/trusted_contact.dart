import 'package:flutter/foundation.dart';

/// A user's emergency trusted contact (ADR-013): a name and a phone number.
/// Stored server-side in auth's own database. Contacts never confirm, and
/// hear from us only when the user presses SOS or shares a meetup.
@immutable
class TrustedContact {
  const TrustedContact({
    required this.id,
    required this.name,
    required this.phoneNumber,
  });

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id'] as String,
      name: json['name'] as String,
      phoneNumber: json['phone_number'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String phoneNumber;
}
