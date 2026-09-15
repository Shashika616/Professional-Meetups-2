import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart'
    show formatMeetupWindow;
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';

/// The content of a member's public profile — header, record, verification
/// rows, and their recent meetups — as a list of slivers-free widgets so
/// the same content can sit in a full page ([PublicProfilePage]) or in a
/// bottom sheet (the join confirmation). Renders skeletons for a null
/// [profile], so callers show it immediately and let it fill in.
class PublicProfileBody extends StatelessWidget {
  const PublicProfileBody({
    super.key,
    required this.profile,
    this.fallbackName,
    this.compact = false,
  });

  final PublicProfile? profile;

  /// Shown in the header while [profile] is null.
  final String? fallbackName;

  /// Sheet mode: a tighter header and no top padding.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(profile: profile, fallbackName: fallbackName, compact: compact),
        const SizedBox(height: 18),
        _RecordCard(profile: profile),
        const SizedBox(height: 14),
        _VerificationCard(profile: profile),
        if (profile != null) ...[
          const SizedBox(height: 22),
          _RecentMeetups(meetups: profile!.recentMeetups),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.profile,
    required this.fallbackName,
    required this.compact,
  });

  final PublicProfile? profile;
  final String? fallbackName;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = profile?.fullName ?? fallbackName ?? '';
    return Column(
      children: [
        if (!compact) const SizedBox(height: 8),
        ProfessionalAvatar(
          size: compact ? 72 : 92,
          name: name.isEmpty ? null : name,
          imageUrl: (profile?.profilePhotoUrl.isNotEmpty ?? false)
              ? profile!.profilePhotoUrl
              : null,
        ),
        const SizedBox(height: 14),
        if (name.isEmpty)
          const SkeletonBox(width: 160, height: 22)
        else
          Text(
            name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 20 : 22,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
            ),
          ),
        const SizedBox(height: 8),
        if (profile == null)
          const SkeletonBox(width: 64, height: 22)
        else
          TrustLevelBadge(trustLevel: profile!.trustLevel),
      ],
    );
  }
}

/// Meetups completed and rating, side by side — the two numbers a host
/// weighs when deciding whether to accept someone, and a would-be joiner
/// weighs about a host.
class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.profile});

  final PublicProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return FlatCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: _Stat(
              label: 'MEETUPS',
              value: p == null ? null : '${p.meetupsCompleted}',
              caption: 'completed',
            ),
          ),
          Container(width: 1, height: 40, color: AppPalette.hairline),
          Expanded(
            child: p == null
                ? const _Stat(label: 'RATING', value: null, caption: '')
                : Column(
                    children: [
                      const _StatLabel('RATING'),
                      const SizedBox(height: 6),
                      if (p.ratingCount == 0)
                        Text(
                          'No ratings yet',
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        StarRating(
                          average: p.ratingAverage,
                          count: p.ratingCount,
                          size: 16,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.caption,
  });

  final String label;
  final String? value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StatLabel(label),
        const SizedBox(height: 6),
        if (value == null)
          const SkeletonBox(width: 40, height: 24)
        else
          Text(
            value!,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            caption,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _StatLabel extends StatelessWidget {
  const _StatLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: AppPalette.textSecondary,
      fontSize: 10.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.3,
    ),
  );
}

/// The three verifications as facts. Each row says WHAT was verified and
/// what that earns them in the app's vocabulary ("Professional",
/// "Official"), and nothing about the value that was checked.
class _VerificationCard extends StatelessWidget {
  const _VerificationCard({required this.profile});

  final PublicProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return FlatCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StatLabel('VERIFIED'),
          const SizedBox(height: 4),
          _VerificationRow(
            icon: Icons.work_outline_rounded,
            title: 'Professional',
            detail: 'LinkedIn identity linked',
            verified: p?.linkedInConnected,
            color: AppPalette.verified,
          ),
          _VerificationRow(
            icon: Icons.verified_rounded,
            title: 'Official',
            detail: 'Company email verified',
            verified: p?.workEmailVerified,
            color: AppPalette.gold,
          ),
          _VerificationRow(
            icon: Icons.phone_iphone_rounded,
            title: 'Phone verified',
            detail: 'Reachable on a confirmed number',
            verified: p?.phoneVerified,
            color: AppPalette.candyBlue,
          ),
        ],
      ),
    );
  }
}

class _VerificationRow extends StatelessWidget {
  const _VerificationRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.verified,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String detail;

  /// Null while loading.
  final bool? verified;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final on = verified == true;
    final off = verified == false;
    // Verified rows keep their own colour; an unverified one is called out
    // in a soft red rather than greyed out — grey reads as "disabled" and
    // gets skipped, and the absence of a verification is exactly the fact
    // a host or joiner is here to notice.
    final tint = on
        ? color
        : off
        ? AppPalette.danger.withValues(alpha: 0.85)
        : AppPalette.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: on ? 0.14 : 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: on ? AppPalette.textPrimary : tint,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  off ? 'Not verified' : detail,
                  style: TextStyle(
                    color: off ? tint : AppPalette.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (verified == null)
            const SkeletonBox(width: 20, height: 20)
          else
            Icon(
              on ? Icons.check_circle_rounded : Icons.cancel_outlined,
              size: 20,
              color: tint,
            ),
        ],
      ),
    );
  }
}

/// The member's last few meetups. Each card: the intent, when and where,
/// whether they hosted or joined, how many came, the overall rating, and
/// the written comments about the meetup — attributed only where the
/// server chose to name the author (the viewer was there too), shown as
/// "A participant" otherwise.
class _RecentMeetups extends StatelessWidget {
  const _RecentMeetups({required this.meetups});

  final List<MemberMeetup> meetups;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 10),
          child: _StatLabel('RECENT MEETUPS'),
        ),
        if (meetups.isEmpty)
          FlatCard(
            radius: 14,
            padding: const EdgeInsets.all(18),
            child: Text(
              'No meetups yet.',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
            ),
          )
        else
          for (final m in meetups) ...[
            _MemberMeetupCard(meetup: m),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _MemberMeetupCard extends StatelessWidget {
  const _MemberMeetupCard({required this.meetup});

  final MemberMeetup meetup;

  @override
  Widget build(BuildContext context) {
    final m = meetup;
    final roleColor = m.hosted ? AppPalette.brandGreen : AppPalette.candyBlue;
    return FlatCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppPalette.candyBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  m.intent.icon,
                  size: 18,
                  color: AppPalette.candyBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.intent.label,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatMeetupWindow(m.windowStart, m.windowEnd),
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: roleColor.withValues(alpha: 0.35)),
                ),
                child: Text(
                  m.hosted ? 'HOSTED' : 'JOINED',
                  style: TextStyle(
                    color: roleColor,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
          if (m.locationLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 14,
                  color: AppPalette.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m.locationLabel,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.people_outline,
                size: 14,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                m.participantCount == 1
                    ? '1 person'
                    : '${m.participantCount} people',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (m.reviewCount == 0)
                Text(
                  'Not rated yet',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12,
                  ),
                )
              else
                StarRating(
                  average: m.overallAverage,
                  count: m.reviewCount,
                  size: 14,
                ),
            ],
          ),
          if (m.comments.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: AppPalette.hairline),
            const SizedBox(height: 10),
            for (final c in m.comments) ...[
              _CommentRow(comment: c),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});

  final MemberMeetupComment comment;

  @override
  Widget build(BuildContext context) {
    final named = comment.authorName.isNotEmpty;
    // A quote block: an accent rule down the left, the note in italics
    // between real quotation marks, and the author on the line below in
    // bold with an em-dash lead — the typographic shape of a quotation,
    // which the old icon-plus-two-lines never quite read as.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppPalette.candyBlue.withValues(alpha: 0.06),
        // Only the right corners are rounded: a non-uniform Border (the
        // left rule) cannot coexist with rounded corners on its own side.
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
        border: Border(
          left: BorderSide(
            color: AppPalette.candyBlue.withValues(alpha: 0.6),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '\u201C${comment.note}\u201D',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13.5,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            named ? comment.authorName : 'A participant',
            style: TextStyle(
              color: named ? AppPalette.textPrimary : AppPalette.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
