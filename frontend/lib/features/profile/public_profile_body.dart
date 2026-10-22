import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart'
    show formatMeetupWindow;
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/empty_section.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/stat_tile.dart';
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
    // On a card, not loose on the page. The screen set gives every
    // profile header a surface of its own; without one the avatar and
    // name floated above the stat tiles with nothing tying them together,
    // and the page started at its emptiest point.
    return FlatCard(
      radius: 22,
      padding: EdgeInsets.symmetric(
        horizontal: 18,
        vertical: compact ? 18 : 22,
      ),
      child: Column(
        children: [
          // Ringed, like the member's own avatar on the Profile tab and on
          // the Home header. The ring is the app's mark for a person, so
          // dropping it here made a member read as a placeholder.
          ProfessionalAvatar(
            size: compact ? 72 : 84,
            ring: true,
            showPresenceDot: true,
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
                fontSize: compact ? 19 : 21,
                fontWeight: FontWeight.w800,
                color: AppPalette.textPrimary,
              ),
            ),
          const SizedBox(height: 10),
          if (profile == null)
            const SkeletonBox(width: 64, height: 22)
          else
            TrustLevelBadge(trustLevel: profile!.trustLevel),
        ],
      ),
    );
  }
}

/// Meetups completed and rating, side by side — the two numbers a host
/// weighs when deciding whether to accept someone, and a would-be joiner
/// weighs about a host.
///
/// Two [StatTile]s, the same tiles the member's own profile uses, rather
/// than one card split by a rule: this was the odd one out, and it stacked
/// its caption above the number and a second caption below it, so "0"
/// arrived between the words "Meetups" and "completed".
class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.profile});

  final PublicProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return StatTileRow(
      tiles: [
        StatTile(
          value: p == null ? '—' : '${p.meetupsCompleted}',
          label: 'Meetups completed',
        ),
        StatTile(
          value: p == null
              ? '—'
              : p.ratingCount == 0
              ? 'No ratings yet'
              : p.ratingAverage.toStringAsFixed(1),
          label: 'Rating',
        ),
      ],
    );
  }
}

/// The small all-caps-weight label over a section ("Verified", "Recent
/// meetups").
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
      letterSpacing: 0.3,
    ),
  );
}

/// The three verifications as facts. Each row says WHAT was verified in
/// the app's vocabulary ("Professional", "Official"), and nothing about
/// the value that was checked.
class _VerificationCard extends StatelessWidget {
  const _VerificationCard({required this.profile});

  final PublicProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return FlatCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StatLabel('Verified'),
          const SizedBox(height: 6),
          _VerificationRow(
            icon: AppIcons.work,
            title: 'Professional',
            verified: p?.linkedInConnected,
          ),
          _VerificationRow(
            icon: AppIcons.verifiedBadge,
            title: 'Official',
            verified: p?.workEmailVerified,
          ),
          _VerificationRow(
            icon: AppIcons.phone,
            title: 'Phone verified',
            verified: p?.phoneVerified,
          ),
        ],
      ),
    );
  }
}

/// # NO SUBTITLE, AND NOTHING RED
///
/// Each row used to carry a second line explaining the first ("LinkedIn
/// identity linked" under "Professional"), and an unverified one was
/// drawn in the app's danger colour with a red cross. Three rows of that
/// made a member's profile look like an incident report. The screen set
/// states the fact and its status, nothing else, and keeps red for
/// cancelling and for safety — an unverified row is simply not yet true,
/// so it says so in the secondary colour.
class _VerificationRow extends StatelessWidget {
  const _VerificationRow({
    required this.icon,
    required this.title,
    required this.verified,
  });

  final String icon;
  final String title;

  /// Null while loading.
  final bool? verified;

  @override
  Widget build(BuildContext context) {
    final on = verified == true;
    final Color tint = on ? AppPalette.verified : AppPalette.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppPalette.tintedSurface(
                tint.withValues(alpha: on ? 0.14 : 0.08),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(icon, size: 17, color: tint),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: on ? AppPalette.textPrimary : AppPalette.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (verified == null)
            const SkeletonBox(width: 62, height: 16)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  on ? AppIcons.check : AppIcons.minus,
                  size: 14,
                  color: tint,
                ),
                const SizedBox(width: 5),
                Text(
                  on ? 'Verified' : 'Not yet',
                  style: TextStyle(
                    color: tint,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
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
          child: _StatLabel('Recent meetups'),
        ),
        if (meetups.isEmpty)
          // No message under the title: nothing the VIEWER can do puts a
          // meetup in someone else's history, so a "do this to fix it"
          // line would be addressed to the wrong person.
          const EmptySection(icon: AppIcons.calendar, title: 'No meetups yet')
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
      radius: 18,
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
                child: AppIcon(
                  m.intent.iconPath,
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
                      m.intentLabel,
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
                  m.hosted ? 'Hosted' : 'Joined',
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
                AppIcon(
                  AppIcons.pin,
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
              AppIcon(
                AppIcons.people,
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
        // The 3px blue rule down the left is gone, so the corners can all
        // be rounded again — the old comment here explained a constraint
        // that only existed because of the rule.
        color: AppPalette.tintedSurface(
          AppPalette.candyBlue.withValues(alpha: 0.08),
        ),
        borderRadius: BorderRadius.circular(14),
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
