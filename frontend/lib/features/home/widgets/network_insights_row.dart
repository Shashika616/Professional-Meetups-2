import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';

/// Was "NETWORK INSIGHTS" showing three fabricated numbers (a hardcoded
/// 128/12/4.9 behind a fake 1-second delay, never wired to anything real).
/// Replaced with real per-user values this app already has — trust level
/// and rating come from [authSessionProvider]'s cached profile
/// (`GET /v1/users/me`), meetup count from [myMeetupsProvider] — rather
/// than a genuinely network-wide stat (e.g. "verified members nearby"),
/// which has no backend support yet (no geo-visibility endpoint exists;
/// see `docs/00-project/action-tracker.md`'s Slice D). Renamed to "YOUR
/// STATS" since the content is now personal, not network-wide — keeping
/// the old label would have been its own small lie.
class NetworkInsightsRow extends ConsumerWidget {
  const NetworkInsightsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authSessionProvider).value?.profile;
    final myMeetupsAsync = ref.watch(myMeetupsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('YOUR STATS'),
          const SizedBox(height: 16),
          myMeetupsAsync.when(
            loading: () => const Row(
              children: [
                Expanded(child: _StatSkeleton()),
                SizedBox(width: 12),
                Expanded(child: _StatSkeleton()),
                SizedBox(width: 12),
                Expanded(child: _StatSkeleton()),
              ],
            ),
            error: (_, _) => const SizedBox.shrink(),
            data: (result) {
              final meetupCount =
                  result.hosted.length + result.requested.length;
              final trustLevel = profile?.trustLevel;
              final ratingCount = profile?.ratingCount ?? 0;
              return Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      label: 'TRUST LEVEL',
                      value: trustLevel == null ? '—' : 'L$trustLevel',
                      icon: Icons.verified_user_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      label: 'YOUR MEETUPS',
                      value: '$meetupCount',
                      icon: Icons.coffee_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      label: 'YOUR RATING',
                      value: ratingCount == 0
                          ? '—'
                          : profile!.ratingAverage.toStringAsFixed(1),
                      icon: Icons.star_rounded,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppPalette.candyBlue),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 20,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              letterSpacing: 1.2,
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatSkeleton extends StatelessWidget {
  const _StatSkeleton();

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(14),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 20, height: 20),
          SizedBox(height: 12),
          SkeletonBox(width: 40, height: 20, opacity: 0.08),
          SizedBox(height: 8),
          SkeletonBox(width: 60, height: 10),
        ],
      ),
    );
  }
}
