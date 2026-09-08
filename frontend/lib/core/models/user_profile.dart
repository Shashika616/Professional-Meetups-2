import 'package:flutter/foundation.dart';

/// A signed-in user's profile, sourced from two places: the one-time
/// LinkedIn callback response (`id`/`fullName`/`profilePhotoUrl`/
/// `trustLevel` — see `AuthSession`) and `GET /v1/users/me` (everything
/// else here — the Level 2/3 verification addendum, `backend/PLAN.md`'s
/// matching addendum Step E).
///
/// [phoneNumber]/[personalEmail]/[legalName]/[address] (ADR-023 §4) are raw
/// PII, returned by `GetProfile`/`CompleteProfileSetup` **only about the
/// signed-in account's own owner** — Verification Model § 1's actual rule is
/// "never reveal ... to other users", which this app was over-applying as
/// "never to anyone, including the owner." These four fields are never sent
/// anywhere except back to the backend as part of an edit (e.g.
/// re-verification), and are never shown to any other user. Work email has
/// no raw field here and never will — that's ADR-003's separate, stronger
/// rule (never stored past the verification round-trip), which this model
/// still has no way to violate.
@immutable
class UserProfile {
  const UserProfile({
    required this.id,
    required this.fullName,
    this.profilePhotoUrl = '',
    // Always empty in this slice — LinkedIn's OIDC userinfo call (`scope:
    // openid profile email`) doesn't return a headline, and the backend
    // doesn't populate one. Kept as a field so it can be wired up later
    // without another model change.
    this.headline = '',
    // Level 0 (ADR-014) — a federated (Apple/Google) or email-OTP account
    // with no LinkedIn linked is a real, reachable state now, not just
    // "mid-onboarding," so an unset trustLevel must default to the
    // least-trusted value, never assume LinkedIn is already connected.
    this.trustLevel = 0,
    this.phoneVerified = false,
    this.personalEmailVerified = false,
    this.personalDetailsComplete = false,
    this.companyDomain = '',
    this.workEmailVerified = false,
    this.ratingAverage = 0,
    this.ratingCount = 0,
    this.meetupsCompleted = 0,
    this.phoneNumber = '',
    this.personalEmail = '',
    this.legalName = '',
    this.address = '',
    this.linkedInConnectedFlag = false,
    this.isGuest = false,
    this.companyName = '',
  });

  final String id;
  final String fullName;
  final String profilePhotoUrl;
  final String headline;
  final int trustLevel;
  final bool phoneVerified;
  final bool personalEmailVerified;
  final bool personalDetailsComplete;
  final String companyDomain;
  final bool workEmailVerified;

  /// Raw PII, self-view only (ADR-023 §4) — see the class doc comment.
  final String phoneNumber;
  final String personalEmail;
  final String legalName;
  final String address;

  /// Whether this account is a guest (ADR-002 §3) — no email, no phone, no
  /// LinkedIn, a generated handle, read-only. Server-sourced rather than
  /// inferred from `trustLevel == 0`: those coincide today but answer
  /// different questions, and the ladder has already been redefined once.
  final bool isGuest;

  /// Free-text organisation name (ADR-002 §2). Required for Level 3
  /// alongside a verified work email; prefills the hosting-unlock flow.
  final String companyName;

  /// Post-meetup star rating aggregate (ADR-015,
  /// docs/02-domain/domain-model.md § Rating) — 0/0 until this user has
  /// been rated at least once.
  final double ratingAverage;
  final int ratingCount;

  /// How many meetups this user has actually completed — the profile stats
  /// row's MEETUPS figure.
  ///
  /// Server-sourced (auth.users.meetups_completed, a cache the meetup module
  /// keeps current). It was a hardcoded `'12'` in `profile_page.dart` before
  /// this field existed, shown identically to an account created seconds
  /// ago. Defaults to 0, which is both the safe fallback and the correct
  /// value for a new account.
  final int meetupsCompleted;

  /// Server-sourced `linkedin_connected`. Backing field for
  /// [linkedInConnected]; read that instead.
  final bool linkedInConnectedFlag;

  /// Whether LinkedIn is actually linked to this account.
  ///
  /// THIS USED TO BE `trustLevel >= 1`, AND ADR-002 BROKE THAT. Under the old
  /// ladder Level 1 was reachable only via LinkedIn, so the inference held.
  /// ADR-002 §2 makes every real signup path Level 1, so an Apple/Google/
  /// email account with no LinkedIn is now Level 1 — and the old expression
  /// would claim LinkedIn was connected for all of them. That would show the
  /// Level 2 checklist's LinkedIn row as done and unlock the phone/email/
  /// details rows beneath it, every one of which the server then rejects
  /// (requireLinkedIn, deliberately unchanged by ADR-002).
  ///
  /// It now reads the server's own `linkedin_connected` field. Kept as a
  /// getter over a private field so every existing call site is unchanged.
  bool get linkedInConnected => linkedInConnectedFlag;

  /// Parses `GET /v1/users/me`'s response body. Distinct from
  /// `AuthSession.fromJson` — this is a different endpoint/response shape,
  /// not a re-parse of the same payload.
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['user_id'] as String,
      fullName: json['full_name'] as String? ?? '',
      profilePhotoUrl: json['profile_photo_url'] as String? ?? '',
      trustLevel: json['trust_level'] as int? ?? 0,
      phoneVerified: json['phone_verified'] as bool? ?? false,
      personalEmailVerified: json['personal_email_verified'] as bool? ?? false,
      personalDetailsComplete:
          json['personal_details_complete'] as bool? ?? false,
      companyDomain: json['company_domain'] as String? ?? '',
      workEmailVerified: json['work_email_verified'] as bool? ?? false,
      ratingAverage: (json['rating_average'] as num?)?.toDouble() ?? 0,
      ratingCount: json['rating_count'] as int? ?? 0,
      meetupsCompleted: json['meetups_completed'] as int? ?? 0,
      phoneNumber: json['phone_number'] as String? ?? '',
      personalEmail: json['personal_email'] as String? ?? '',
      legalName: json['legal_name'] as String? ?? '',
      address: json['address'] as String? ?? '',
      linkedInConnectedFlag: json['linkedin_connected'] as bool? ?? false,
      isGuest: json['is_guest'] as bool? ?? false,
      companyName: json['company_name'] as String? ?? '',
    );
  }

  UserProfile copyWith({
    String? fullName,
    String? profilePhotoUrl,
    String? headline,
    int? trustLevel,
    bool? phoneVerified,
    bool? personalEmailVerified,
    bool? personalDetailsComplete,
    String? companyDomain,
    bool? workEmailVerified,
    double? ratingAverage,
    int? ratingCount,
    int? meetupsCompleted,
    String? phoneNumber,
    String? personalEmail,
    String? legalName,
    String? address,
    bool? linkedInConnectedFlag,
    bool? isGuest,
    String? companyName,
  }) {
    return UserProfile(
      id: id,
      fullName: fullName ?? this.fullName,
      profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
      headline: headline ?? this.headline,
      trustLevel: trustLevel ?? this.trustLevel,
      phoneVerified: phoneVerified ?? this.phoneVerified,
      personalEmailVerified:
          personalEmailVerified ?? this.personalEmailVerified,
      personalDetailsComplete:
          personalDetailsComplete ?? this.personalDetailsComplete,
      companyDomain: companyDomain ?? this.companyDomain,
      workEmailVerified: workEmailVerified ?? this.workEmailVerified,
      ratingAverage: ratingAverage ?? this.ratingAverage,
      ratingCount: ratingCount ?? this.ratingCount,
      meetupsCompleted: meetupsCompleted ?? this.meetupsCompleted,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      personalEmail: personalEmail ?? this.personalEmail,
      legalName: legalName ?? this.legalName,
      address: address ?? this.address,
      linkedInConnectedFlag:
          linkedInConnectedFlag ?? this.linkedInConnectedFlag,
      isGuest: isGuest ?? this.isGuest,
      companyName: companyName ?? this.companyName,
    );
  }
}
