import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
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
      appBar: AppBar(title: const Text('NOTIFICATIONS')),
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
      return _CentredMessage(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load your notifications.",
        action: PrimaryButton(
          label: 'TRY AGAIN',
          height: 44,
          onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _load();
          },
        ),
      );
    }

    final rows = _notifications ?? const <AppNotification>[];
    if (rows.isEmpty) {
      return const _CentredMessage(
        icon: Icons.notifications_none_rounded,
        title: 'Nothing yet.',
        subtitle:
            'Join requests, accepted invites and meetup updates from the '
            'last 7 days show up here.',
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
            SectionLabel(group.label),
            const SizedBox(height: 12),
            for (final notification in group.notifications)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _NotificationRow(notification: notification),
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
  if (difference <= 0) return 'TODAY';
  if (difference == 1) return 'YESTERDAY';
  // An explicit date beyond that: "3 DAYS AGO" still makes the reader count.
  return '${day.year}/${_two(day.month)}/${_two(day.day)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.notification});

  final AppNotification notification;

  /// The same types the foreground toast handler switches on, mapped to an
  /// icon so the list is scannable without reading every line.
  (IconData, Color) _glyph() => switch (notification.type) {
    'join_request' => (Icons.person_add_alt_1_rounded, AppPalette.candyBlue),
    'request_accepted' => (Icons.check_circle_rounded, AppPalette.verified),
    'request_declined' ||
    'meetup_cancelled' ||
    'meetup_full' ||
    'participant_declined' => (Icons.cancel_rounded, AppPalette.danger),
    'request_withdrawn' => (Icons.undo_rounded, AppPalette.textSecondary),
    'meetup_closed' => (Icons.auto_awesome_rounded, AppPalette.gold),
    'meetup_starting_soon' => (Icons.schedule_rounded, AppPalette.candyBlue),
    'safety_checklist' => (Icons.shield_outlined, AppPalette.verified),
    'meetup_nearby' => (Icons.place_outlined, AppPalette.candyBlue),
    _ => (Icons.notifications_none_rounded, AppPalette.textSecondary),
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

    return GestureDetector(
      // opaque so the whole card is the target, not just the painted glyphs
      // — the same fix the Profile rows needed.
      behavior: HitTestBehavior.opaque,
      onTap: tappable ? () => _open(context) : null,
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppPalette.tintedSurface(colour.withValues(alpha: 0.14)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: colour),
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
    );
  }
}

/// 24-hour clock: the row already sits under a date heading, so the only
/// question left is what time, and am/pm adds width for nothing.
@visibleForTesting
String formatNotificationTime(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}';

class _CentredMessage extends StatelessWidget {
  const _CentredMessage({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // Scrollable so pull-to-refresh still works with nothing in the list.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 120, 32, 32),
      children: [
        Icon(icon, size: 42, color: AppPalette.textSecondary),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    );
  }
}

class _NotificationsSkeleton extends StatelessWidget {
  const _NotificationsSkeleton();

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
      children: [
        box(11, w: 70),
        const SizedBox(height: 12),
        for (var i = 0; i < 3; i++) ...[box(72), const SizedBox(height: 10)],
        const SizedBox(height: 12),
        box(11, w: 90),
        const SizedBox(height: 12),
        for (var i = 0; i < 2; i++) ...[box(72), const SizedBox(height: 10)],
      ],
    );
  }
}
