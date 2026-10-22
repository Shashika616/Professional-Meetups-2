import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';

/// The last week of notifications, grouped by day.
///
/// # WHY THERE IS NO "CLEAR" BUTTON AND NO READ/UNREAD STATE
///
/// These rows are the delivery outbox, filtered to one recipient. The
/// retention job already deletes them after a week, so the list bounds and
/// clears itself — a manual clear would only hide rows that are going away
/// anyway, and a read flag would be a new column written on a screen view,
/// which is a lot of write traffic for something nobody acts on.
///
/// # WHY IT GROUPS BY DAY RATHER THAN SHOWING TIMESTAMPS
///
/// A flat list of "2 days ago" strings makes the reader do the arithmetic.
/// Today / Yesterday / an explicit date is how someone actually thinks about
/// a week of history, and it means each row only has to carry a time.
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  List<AppNotification>? _notifications;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(meetupServiceProvider).listNotifications();
      if (!mounted) return;
      setState(() {
        _notifications = rows;
        _loading = false;
      });
    } on MeetupSessionExpiredException {
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Notifications')),
      body: AppBackground(
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            color: AppPalette.candyBlue,
            backgroundColor: AppPalette.card,
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(20, 4, 20, 32),
        child: SkeletonLoader(child: _NotificationsSkeleton()),
      );
    }

    if (_error != null) {
      return SkeletonThenFailure(
        skeleton: const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20, 4, 20, 32),
          child: SkeletonLoader(child: _NotificationsSkeleton()),
        ),
        failure: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            LoadFailedState(
              failure: LoadFailure.of(_error),
              onRetry: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _load();
              },
            ),
          ],
        ),
      );
    }

    final rows = _notifications ?? const <AppNotification>[];
    if (rows.isEmpty) {
      // Scrollable so pull-to-refresh still works with nothing in the list.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          EmptyStateDeck(
            title: 'All quiet for now',
            message:
                'Join requests, accepted invites and meetup updates from the '
                'last 7 days show up here.',
            scenes: EmptyDeckScenes.inbox,
          ),
        ],
      );
    }

    // Server returns newest-first; groupByDay preserves that order.
    final groups = groupNotificationsByDay(rows);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (index > 0) const SizedBox(height: 22),
            SectionHeading(group.label),
            const SizedBox(height: 12),
            // One card per DAY, with the day's notifications as rows
            // inside it — not one card per notification.
            //
            // A column of identical cards is the lazy page structure this
            // redesign has been taking out everywhere (the Safety
            // checklist, the privacy facts, the Profile verification
            // list). Here it also fought the headings: "Today" sat above
            // four separate objects rather than above one group, so the
            // grouping the server went to the trouble of computing was
            // invisible.
            FlatCard(
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                children: [
                  for (final notification in group.notifications)
                    _NotificationRow(
                      notification: notification,
                      first: notification == group.notifications.first,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One day's notifications, with the heading to render above them.
class NotificationDay {
  const NotificationDay({required this.label, required this.notifications});

  final String label;
  final List<AppNotification> notifications;
}

/// Buckets [notifications] into days, preserving the incoming order.
///
/// `now` is injectable so a test can pin "today" instead of depending on
/// when it runs — a date-bucketing function tested against the real clock
/// fails at midnight.
@visibleForTesting
List<NotificationDay> groupNotificationsByDay(
  List<AppNotification> notifications, {
  DateTime? now,
}) {
  final today = _dayOf(now ?? DateTime.now());
  final groups = <NotificationDay>[];

  for (final notification in notifications) {
    final day = _dayOf(notification.createdAt);
    final label = _labelFor(day, today);
    if (groups.isNotEmpty && groups.last.label == label) {
      groups.last.notifications.add(notification);
      continue;
    }
    groups.add(NotificationDay(label: label, notifications: [notification]));
  }
  return groups;
}

DateTime _dayOf(DateTime value) => DateTime(value.year, value.month, value.day);

String _labelFor(DateTime day, DateTime today) {
  final difference = today.difference(day).inDays;
  if (difference <= 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  // An explicit date beyond that: "3 DAYS AGO" still makes the reader count.
  return '${day.year}/${_two(day.month)}/${_two(day.day)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.notification, this.first = false});

  final AppNotification notification;

  /// The first row in its day's card draws no rule above it.
  final bool first;

  /// The same types the foreground toast handler switches on, mapped to an
  /// icon so the list is scannable without reading every line.
  (String, Color) _glyph() => switch (notification.type) {
    'join_request' => (AppIcons.personAdd, AppPalette.candyBlue),
    'request_accepted' => (AppIcons.checkCircle, AppPalette.verified),
    // A "not this time" is pointed forward (a compass), not marked with a
    // red cross: the row should read as a nudge to look around.
    'request_declined' ||
    'meetup_full' => (AppIcons.explore, AppPalette.candyBlue),
    'meetup_cancelled' ||
    'participant_declined' => (AppIcons.xCircle, AppPalette.danger),
    'request_withdrawn' => (AppIcons.undo, AppPalette.textSecondary),
    'meetup_closed' => (AppIcons.star, AppPalette.gold),
    'meetup_starting_soon' => (AppIcons.clock, AppPalette.candyBlue),
    'safety_checklist' => (AppIcons.shield, AppPalette.verified),
    'meetup_nearby' => (AppIcons.pin, AppPalette.candyBlue),
    _ => (AppIcons.bell, AppPalette.textSecondary),
  };

  void _open(BuildContext context) {
    if (notification.meetupId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MeetupDetailPage(meetupId: notification.meetupId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = _glyph();
    final tappable = notification.meetupId.isNotEmpty;

    return Column(
      children: [
        if (!first) Divider(height: 1, color: AppPalette.hairline),
        GestureDetector(
          // opaque so the whole row is the target, not just the painted
          // glyphs — the same fix the Profile rows needed.
          behavior: HitTestBehavior.opaque,
          onTap: tappable ? () => _open(context) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppPalette.tintedSurface(
                      colour.withValues(alpha: 0.14),
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: AppIcon(icon, size: 17, color: colour),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notification.title,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        notification.body,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  formatNotificationTime(notification.createdAt),
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
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

/// 24-hour clock: the row already sits under a date heading, so the only
/// question left is what time, and am/pm adds width for nothing.
@visibleForTesting
String formatNotificationTime(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}';

class _NotificationsSkeleton extends StatelessWidget {
  const _NotificationsSkeleton();

  /// One placeholder row, traced from the real one: a 33px tinted icon
  /// tile, a title line, a body line, and the timestamp on the right.
  ///
  /// It used to be a blank 72px rectangle. A featureless block is not a
  /// skeleton of anything — it tells the eye nothing about where the text
  /// will land, so when the real rows arrive everything has to be found
  /// again from scratch.
  Widget _row({bool first = false}) => Column(
    children: [
      if (!first) Divider(height: 1, color: AppPalette.hairline),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonBox(width: 33, height: 33, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(width: 170, height: 11, opacity: 0.08),
                  SizedBox(height: 7),
                  SkeletonBox(width: 230, height: 10),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const SkeletonBox(width: 28, height: 9),
          ],
        ),
      ),
    ],
  );

  /// A day's worth of rows, in the one card the real list uses.
  Widget _day(int rows) => FlatCard(
    radius: 18,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    child: Column(
      children: [for (var i = 0; i < rows; i++) _row(first: i == 0)],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The section heading above each group.
        const SkeletonBox(width: 70, height: 11),
        const SizedBox(height: 12),
        _day(3),
        const SizedBox(height: 22),
        const SkeletonBox(width: 90, height: 11),
        const SizedBox(height: 12),
        _day(2),
      ],
    );
  }
}
