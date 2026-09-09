import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';
import 'package:professional_connections_platform/features/meetups/review/meetup_review_page.dart';

/// A finished meetup's review, in whichever of its two states applies: still
/// owed, or already given.
///
/// # WHY IT IS ONE WIDGET AND NOT TWO SCREENS
///
/// The same section appears on a history card and, before the home card's
/// review window lapses, on the same detail page reached from Home. Whether
/// it prompts or reports is a fact about the data, not about which list you
/// arrived from — so it asks the server and renders accordingly, rather than
/// having each caller guess.
class MeetupReviewSection extends ConsumerStatefulWidget {
  const MeetupReviewSection({
    super.key,
    required this.meetupId,
    required this.hostUserId,
    this.cancelled = false,
  });

  final String meetupId;
  final String hostUserId;

  /// A cancelled meetup never happened, so it is never asked "how was it".
  /// Any ratings already given (a cancelled meetup's host is ratable — ADR-020
  /// §3) still show.
  final bool cancelled;

  @override
  ConsumerState<MeetupReviewSection> createState() =>
      _MeetupReviewSectionState();
}

class _MeetupReviewSectionState extends ConsumerState<MeetupReviewSection> {
  MeetupReview? _review;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final review = await ref
          .read(meetupServiceProvider)
          .getMeetupReview(widget.meetupId);
      if (!mounted) return;
      setState(() {
        _review = review;
        _loading = false;
      });
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (_) {
      // Optional content on a page that is already useful without it — a
      // failed read shows nothing rather than an alarming error.
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openFlow() async {
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MeetupReviewPage(
          meetupId: widget.meetupId,
          hostUserId: widget.hostUserId,
        ),
      ),
    );
    if (submitted == true && mounted) {
      // Re-read rather than assuming: the page returns "it worked", not the
      // review itself, and this section renders what the server has.
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SkeletonLoader(child: _ReviewSectionSkeleton());
    }
    final review = _review;
    if (review != null && review.completed) {
      return _GivenReview(review: review, hostUserId: widget.hostUserId);
    }
    if (widget.cancelled) {
      // Nothing to review, and saying so beats an empty gap.
      return const SizedBox.shrink();
    }
    return _ReviewInvitation(onTap: _openFlow);
  }
}

/// The prompt, matching the home card's wording so arriving from either
/// place feels like the same task.
class _ReviewInvitation extends StatelessWidget {
  const _ReviewInvitation({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('YOUR REVIEW'),
        const SizedBox(height: 10),
        FlatCard(
          radius: 12,
          tint: AppPalette.gold.withValues(alpha: 0.06),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: AppPalette.gold,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Share your thoughts about this meetup',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Rate how it went and who you met. It only takes a moment.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 14),
              PrimaryButton(
                label: 'START REVIEW',
                height: 44,
                onPressed: onTap,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the viewer gave — never what anyone else gave.
class _GivenReview extends StatelessWidget {
  const _GivenReview({required this.review, required this.hostUserId});

  final MeetupReview review;
  final String hostUserId;

  @override
  Widget build(BuildContext context) {
    final level = ExperienceLevel.fromScore(review.overallScore);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('YOUR REVIEW'),
        const SizedBox(height: 10),
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // The same face from the flow, still, at a glanceable
                  // size — so the answer you gave is recognisably the
                  // answer you gave.
                  ExperienceFace(level: level, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          level.label,
                          style: TextStyle(
                            color: level.color,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Your overall rating',
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (review.notes != null && review.notes!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '"${review.notes}"',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (review.participants.isNotEmpty) ...[
          const SizedBox(height: 18),
          const SectionLabel('HOW YOU RATED THEM'),
          const SizedBox(height: 10),
          for (final participant in review.participants)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RatedPersonRow(
                participant: participant,
                isHost: participant.userId == hostUserId,
              ),
            ),
        ],
      ],
    );
  }
}

class _RatedPersonRow extends StatelessWidget {
  const _RatedPersonRow({required this.participant, required this.isHost});

  final ReviewedParticipant participant;
  final bool isHost;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfessionalAvatar(
                name: participant.fullName,
                imageUrl: participant.profilePhotoUrl.isEmpty
                    ? null
                    : participant.profilePhotoUrl,
                size: 34,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        participant.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (isHost) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.candyBlue.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          'HOST',
                          style: TextStyle(
                            color: AppPalette.candyBlue,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Static, not a picker: ratings are immutable, so an
              // interactive-looking control here would be a lie.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 1; i <= 5; i++)
                    Icon(
                      i <= participant.score
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 16,
                      color: i <= participant.score
                          ? AppPalette.gold
                          : AppPalette.textSecondary.withValues(alpha: 0.4),
                    ),
                ],
              ),
            ],
          ),
          if (participant.traits.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final trait in participant.traits)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.candyBlue.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      // Rendered from the stored key. The label lives in the
                      // server's vocabulary and is not stored per rating, so
                      // this un-slugs it rather than shipping a second copy
                      // of the list that could drift out of step.
                      _humanizeTrait(trait),
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// `great_listener` -> `Great listener`.
String _humanizeTrait(String key) {
  if (key.isEmpty) return key;
  final words = key.split('_');
  final first = words.first;
  return [
    first[0].toUpperCase() + first.substring(1),
    ...words.skip(1),
  ].join(' ');
}

class _ReviewSectionSkeleton extends StatelessWidget {
  const _ReviewSectionSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget box(double h, {double? w}) => Container(
      height: h,
      width: w,
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(12),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [box(12, w: 90), const SizedBox(height: 12), box(112)],
    );
  }
}
