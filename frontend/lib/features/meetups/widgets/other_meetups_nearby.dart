import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/home/widgets/happening_soon_section.dart'
    show happeningSoonWithinDays;

/// What a requester sees under a "not this time": up to three other open
/// meetups near them that they could ask to join instead, and a way to the
/// full list.
///
/// # WHY THIS EXISTS
///
/// A host turning a request down used to end the page. The requester read
/// "declined", in red, with nothing under it, and the only thing left to do
/// was back out. Being turned down by a stranger for a small table is a fit
/// decision, not a verdict, and the kindest thing the app can do is make the
/// next step obvious before the feeling settles. This is that next step.
///
/// # WHAT IT REUSES
///
/// The same [viewerLocationProvider] and [openMeetupsProvider] Home's
/// "Happening Soon" watches, with the all-intents key, so if the user has
/// been on Home this round the list is already cached and no request is
/// made. Nothing new is fetched from the server for this section.
///
/// # WHAT IT NEVER SHOWS
///
/// A failure. This section is supplementary: if location is blocked, the
/// list cannot load, or nothing else is on, it falls back to a calm line and
/// a BROWSE MEETUPS button. A red error under a "not this time" would be the
/// one thing worse than nothing.
class OtherMeetupsNearby extends ConsumerWidget {
  const OtherMeetupsNearby({
    super.key,
    required this.excludeMeetupId,
    required this.onOpen,
  });

  /// The meetup this page is about; it is never its own suggestion.
  final String excludeMeetupId;

  /// Opens a suggested meetup. The detail page owns navigation so this
  /// widget stays free of routes and testable on its own.
  final ValueChanged<Meetup> onOpen;

  /// The most suggestions shown; more than this is a list, and the list
  /// lives on Home.
  static const maxSuggestions = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(viewerLocationProvider);
    switch (location.status) {
      case ViewerLocationStatus.loading:
        return const _Frame(child: _Rows());
      case ViewerLocationStatus.blocked:
        return _Frame(child: _Fallback(onBrowse: () => _browse(context, ref)));
      case ViewerLocationStatus.ready:
        final key = (
          intent: null,
          viewerLat: location.lat!,
          viewerLng: location.lng!,
          withinDays: happeningSoonWithinDays,
        );
        final page = ref.watch(openMeetupsProvider(key));
        // Whatever the async state, a value beats a spinner and a fallback
        // beats an error. See "WHAT IT NEVER SHOWS" above.
        final items = page.value?.items;
        if (items == null) {
          return page.hasError
              ? _Frame(child: _Fallback(onBrowse: () => _browse(context, ref)))
              : const _Frame(child: _Rows());
        }
        final picks = items
            .where(
              (m) =>
                  m.id != excludeMeetupId &&
                  !m.isHostedByMe &&
                  m.myRequestStatus == null &&
                  !m.lockedForViewer &&
                  m.status == MeetupStatus.open,
            )
            .take(maxSuggestions)
            .toList();
        if (picks.isEmpty) {
          return _Frame(
            child: _Fallback(onBrowse: () => _browse(context, ref)),
          );
        }
        return _Frame(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final meetup in picks)
                _SuggestionRow(meetup: meetup, onTap: () => onOpen(meetup)),
              const SizedBox(height: 4),
              SecondaryButton(
                label: 'SEE ALL NEARBY',
                height: 40,
                onPressed: () => _browse(context, ref),
              ),
            ],
          ),
        );
    }
  }

  /// Back to Home's browse list: pop every pushed page and land on the
  /// first tab, which is where the full "Happening Soon" list lives.
  void _browse(BuildContext context, WidgetRef ref) {
    ref.read(currentTabIndexProvider.notifier).state = 0;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('OTHERS HAPPENING SOON'),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.meetup, required this.onTap});

  final Meetup meetup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final start = meetup.windowStart;
    final end = meetup.windowEnd;
    final when = start != null && end != null
        ? formatMeetupWindow(start, end)
        : 'Time to be confirmed';
    final place = meetup.locationLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FlatCard(
        radius: 12,
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppPalette.brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    meetup.intent.icon,
                    size: 20,
                    color: AppPalette.brandGreen,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meetup.intentLabel,
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.4,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meetup.hostFullName ?? 'A host near you',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        place == null || place.isEmpty
                            ? when
                            : '$when at $place',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: AppPalette.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while location or the list is on its way.
class _Rows extends StatelessWidget {
  const _Rows();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FlatCard(
              radius: 12,
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SkeletonBox(width: 60, height: 10),
                        SizedBox(height: 6),
                        SkeletonBox(width: 140, height: 12),
                        SizedBox(height: 6),
                        SkeletonBox(width: 180, height: 10),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// No suggestions to hand (location off, list unavailable, or genuinely
/// nothing else on). Still forward-looking, and still one tap from the list.
class _Fallback extends StatelessWidget {
  const _Fallback({required this.onBrowse});

  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'New meetups go up every day. Keep an eye on Happening Soon, '
            'or host one and let people come to you.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          SecondaryButton(
            label: 'BROWSE MEETUPS',
            height: 40,
            onPressed: onBrowse,
          ),
        ],
      ),
    );
  }
}
