import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/host_meetup_controls.dart';
import 'package:professional_connections_platform/features/meetups/widgets/rating_prompt.dart';

/// Meetups the signed-in user hosts or has requested to join, reachable in
/// one tap from Home (frontend/meetup-scheduling-PLAN.md Step 8). Tapping a
/// hosted meetup opens its request-management view; tapping a requested
/// meetup opens the ordinary detail page.
class MyMeetupsPage extends ConsumerWidget {
  /// [initialTab] deep-links straight to HOSTING (0, the default) or
  /// REQUESTED (1) — the two entry points in `home_header.dart` route here
  /// directly instead of opening on HOSTING and leaving the user to find
  /// the right tab themselves (ADR-020 §1).
  const MyMeetupsPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myMeetupsAsync = ref.watch(myMeetupsProvider);

    // Pushed as its own route from Home, not one of AppShell's bottom-nav
    // tabs — AppShell's own AppBackground wrap (app_shell.dart) only
    // covers pages[currentIndex], so a page reached via Navigator.push
    // needs this itself or it renders on a plain black canvas instead of
    // the rest of the app's glassmorphism background.
    return AppBackground(
      child: DefaultTabController(
        length: 2,
        initialIndex: initialTab,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('MY MEETUPS'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'HOSTING'),
                Tab(text: 'REQUESTED'),
              ],
            ),
          ),
          body: myMeetupsAsync.when(
            loading: () => const _MyMeetupsSkeleton(),
            error: (error, stack) => Center(
              child: FlatCard(
                radius: 12,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_outlined,
                      color: AppPalette.textSecondary,
                      size: 28,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Could not load your meetups.',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 14),
                    PrimaryButton(
                      label: 'RETRY',
                      height: 40,
                      onPressed: () => ref.invalidate(myMeetupsProvider),
                    ),
                  ],
                ),
              ),
            ),
            data: (result) => TabBarView(
              children: [
                _MeetupList(
                  isHosted: true,
                  initialItems: result.hosted,
                  initialNextCursor: result.hostedNextCursor,
                  initialHasMore: result.hostedHasMore,
                  emptyMessage: 'You aren\'t hosting any meetups yet.',
                  onTap: (meetup) async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _RequestManagementPage(meetup: meetup),
                      ),
                    );
                    ref.invalidate(myMeetupsProvider);
                  },
                ),
                _MeetupList(
                  isHosted: false,
                  initialItems: result.requested,
                  initialNextCursor: result.requestedNextCursor,
                  initialHasMore: result.requestedHasMore,
                  emptyMessage:
                      'You haven\'t requested to join any meetups yet.',
                  onTap: (meetup) async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MeetupDetailPage(meetupId: meetup.id),
                      ),
                    );
                    ref.invalidate(myMeetupsProvider);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown while [myMeetupsProvider] resolves, instead of a bare spinner —
/// mirrors the card shape [_MeetupList] renders once data actually
/// arrives, so the list doesn't visibly "pop" from blank to content.
class _MyMeetupsSkeleton extends StatelessWidget {
  const _MyMeetupsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 70, height: 11, opacity: 0.08),
                  const Spacer(),
                  const SkeletonBox(width: 28, height: 16, radius: 8),
                ],
              ),
              const SizedBox(height: 10),
              const SkeletonBox(width: 100, height: 15, opacity: 0.08),
              const SizedBox(height: 6),
              const SkeletonBox(width: 140, height: 12),
              const SizedBox(height: 10),
              const SkeletonBox(width: 90, height: 11),
            ],
          ),
        ),
      ),
    );
  }
}

/// Open vs. History is a second, orthogonal axis on top of the page's own
/// Hosting/Requested tabs (ADR-016 revives `completed`, which needs
/// somewhere to show up) — filtered client-side from the same
/// already-fetched list, not a second round trip, and not a second level
/// of [TabController] nesting for what's really just a toggle.
///
/// 2026-08-31 round-4 hardening: also owns real cursor pagination for its
/// side (hosted or requested — [isHosted] picks which), reusing
/// `matches_page.dart`'s `_MeetupList` scroll-load pattern exactly (a
/// [ScrollController] with a near-bottom listener, a `_loadingMore` guard,
/// disposed in [dispose]) rather than a second implementation of the same
/// mechanism. [initialItems]/[initialNextCursor]/[initialHasMore] are
/// [MyMeetupsPage]'s first page from `myMeetupsProvider`; this widget
/// accumulates further pages itself via direct `listMyMeetups` calls.
class _MeetupList extends ConsumerStatefulWidget {
  const _MeetupList({
    required this.isHosted,
    required this.initialItems,
    required this.initialNextCursor,
    required this.initialHasMore,
    required this.emptyMessage,
    required this.onTap,
  });

  final bool isHosted;
  final List<Meetup> initialItems;
  final String? initialNextCursor;
  final bool initialHasMore;
  final String emptyMessage;
  final void Function(Meetup meetup) onTap;

  @override
  ConsumerState<_MeetupList> createState() => _MeetupListState();
}

class _MeetupListState extends ConsumerState<_MeetupList> {
  bool _showHistory = false;
  late List<Meetup> _items;
  String? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  final _scrollController = ScrollController();

  static bool _isOpen(Meetup m) =>
      m.status == MeetupStatus.open || m.status == MeetupStatus.full;
  static bool _isHistory(Meetup m) =>
      m.status == MeetupStatus.completed || m.status == MeetupStatus.cancelled;

  @override
  void initState() {
    super.initState();
    _resetFromWidget();
    _scrollController.addListener(_maybeLoadNextPage);
  }

  @override
  void didUpdateWidget(covariant _MeetupList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.initialItems, oldWidget.initialItems)) {
      _resetFromWidget();
    }
  }

  void _resetFromWidget() {
    _items = List.of(widget.initialItems);
    _nextCursor = widget.initialNextCursor;
    _hasMore = widget.initialHasMore;
    _loadingMore = false;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadNextPage() {
    if (!_hasMore || _loadingMore) return;
    const nearBottomThreshold = 400.0;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - nearBottomThreshold) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage() async {
    if (!_hasMore || _loadingMore || _nextCursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final result = await ref
          .read(meetupServiceProvider)
          .listMyMeetups(
            hostedCursor: widget.isHosted ? _nextCursor : null,
            requestedCursor: widget.isHosted ? null : _nextCursor,
          );
      if (!mounted) return;
      final newItems = widget.isHosted ? result.hosted : result.requested;
      final newNextCursor = widget.isHosted
          ? result.hostedNextCursor
          : result.requestedNextCursor;
      final newHasMore = widget.isHosted
          ? result.hostedHasMore
          : result.requestedHasMore;
      setState(() {
        _items = [..._items, ...newItems];
        _nextCursor = newNextCursor;
        _hasMore = newHasMore;
        _loadingMore = false;
      });
    } catch (error) {
      // Best-effort, same as matches_page.dart's `_MeetupList` — the
      // current page stays visible, scrolling again retries.
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _items.where(_showHistory ? _isHistory : _isOpen).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: _OpenHistoryToggle(
                  label: 'OPEN',
                  selected: !_showHistory,
                  onTap: () => setState(() => _showHistory = false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _OpenHistoryToggle(
                  label: 'HISTORY',
                  selected: _showHistory,
                  onTap: () => setState(() => _showHistory = true),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    _showHistory ? 'Nothing here yet.' : widget.emptyMessage,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              : _MeetupListView(
                  meetups: filtered,
                  hasMore: _hasMore,
                  scrollController: _scrollController,
                  onTap: widget.onTap,
                ),
        ),
      ],
    );
  }
}

class _OpenHistoryToggle extends StatelessWidget {
  const _OpenHistoryToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? AppPalette.candyBlue.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppPalette.candyBlue : AppPalette.glassBorder,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? AppPalette.candyBlue : AppPalette.textSecondary,
            fontWeight: FontWeight.w800,
            fontSize: 12,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

class _MeetupListView extends StatelessWidget {
  const _MeetupListView({
    required this.meetups,
    required this.hasMore,
    required this.scrollController,
    required this.onTap,
  });

  final List<Meetup> meetups;
  final bool hasMore;
  final ScrollController scrollController;
  final void Function(Meetup meetup) onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: meetups.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= meetups.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final meetup = meetups[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: GestureDetector(
            onTap: () => onTap(meetup),
            child: FlatCard(
              radius: 12,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          meetup.intent.label,
                          style: TextStyle(
                            color: AppPalette.candyBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      MeetupStatusBadge(status: meetup.status),
                      const SizedBox(width: 6),
                      TrustLevelBadge(trustLevel: meetup.hostTrustLevel),
                      const SizedBox(width: 6),
                      StarRating(
                        average: meetup.hostRatingAverage,
                        count: meetup.hostRatingCount,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  VerificationBadges(trustLevel: meetup.hostTrustLevel),
                  const SizedBox(height: 6),
                  Text(
                    meetup.formattedWindow,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // locationLabel is only ever null for a locked
                  // ListOpenMeetups result (ADR-028) — this page loads via
                  // listMyMeetups, which never redacts, so `!` is safe.
                  Text(
                    meetup.locationLabel!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _statusRow(meetup),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _statusRow(Meetup meetup) {
    if (meetup.isHostedByMe) {
      return Text(
        '${meetup.acceptedCount}/${meetup.capacity} confirmed',
        style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
      );
    }
    final status = meetup.myRequestStatus;
    if (status == null) {
      return const SizedBox.shrink();
    }
    final (label, color) = switch (status) {
      MeetupRequestStatus.pending => ('REQUEST PENDING', AppPalette.candyBlue),
      MeetupRequestStatus.accepted => ('YOU\'RE IN', AppPalette.verified),
      MeetupRequestStatus.rejected =>
        meetup.myRequestAutoRejected
            ? ('NOT SELECTED — MEETUP FILLED UP', AppPalette.textSecondary)
            : ('DECLINED BY HOST', AppPalette.danger),
      MeetupRequestStatus.withdrawn => ('WITHDRAWN', AppPalette.textSecondary),
    };
    return Text(
      label,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        fontSize: 11,
      ),
    );
  }
}

/// A host's view of every request on one of their meetups — Accept/Reject
/// per pending request (frontend/meetup-scheduling-PLAN.md Step 8).
class _RequestManagementPage extends ConsumerStatefulWidget {
  const _RequestManagementPage({required this.meetup});

  final Meetup meetup;

  @override
  ConsumerState<_RequestManagementPage> createState() =>
      _RequestManagementPageState();
}

class _RequestManagementPageState
    extends ConsumerState<_RequestManagementPage> {
  late Meetup _meetup;
  List<MeetupRequestModel>? _requests;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _meetup = widget.meetup;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final service = ref.read(meetupServiceProvider);
      final requests = await service.listMeetupRequests(_meetup.id);
      // Also re-fetches the meetup itself, not just its requests — an
      // Accept here bumps acceptedCount server-side, which HostMeetupControls
      // needs to know about immediately: it hides CANCEL once a request has
      // been accepted (the backend rejects cancelling in that state), and a
      // stale local _meetup would otherwise keep showing an action that's
      // now guaranteed to 409.
      final meetup = await service.getMeetup(_meetup.id);
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _meetup = meetup;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _respond(MeetupRequestModel request, bool accept) async {
    try {
      await ref
          .read(meetupServiceProvider)
          .respondToRequest(request.id, accept: accept);
      if (!mounted) return;
      showSnack(
        context,
        accept ? 'Request accepted.' : 'Request rejected.',
        type: ToastType.success,
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: DefaultTabController(
        // Pending / Accepted / Rejected — the single combined list this
        // replaces showed every status inline in one scroll, making it
        // hard to see "who's still waiting" at a glance (ADR-020 §2).
        // Rejected also carries withdrawn requests, shown alongside
        // rejected ones since both represent "no longer pending, not
        // accepted" from the host's point of view.
        length: 3,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('REQUESTS'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'PENDING'),
                Tab(text: 'ACCEPTED'),
                Tab(text: 'REJECTED'),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Was previously missing entirely — this screen showed
                // requester cards with no context about the meetup itself,
                // and (the bug this addendum fixes) no way to close or
                // cancel it, even though tapping the calendar icon →
                // Hosting → a meetup is the normal way a host lands here
                // (ADR-016 addendum, 2026-08-20).
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: FlatCard(
                    radius: 12,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _meetup.intent.label,
                                style: TextStyle(
                                  color: AppPalette.candyBlue,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            MeetupStatusBadge(status: _meetup.status),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _meetup.formattedWindow,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        HostMeetupControls(
                          meetup: _meetup,
                          onChanged: (updated) =>
                              setState(() => _meetup = updated),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const _RequestsSkeleton()
                      : _loadError != null
                      ? Center(
                          child: Text(
                            _loadError!,
                            style: TextStyle(color: AppPalette.textSecondary),
                          ),
                        )
                      : _buildRequestTabs(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestTabs() {
    final requests = _requests!;
    final pending = requests
        .where((r) => r.status == MeetupRequestStatus.pending)
        .toList();
    final accepted = requests
        .where((r) => r.status == MeetupRequestStatus.accepted)
        .toList();
    final rejectedOrWithdrawn = requests
        .where(
          (r) =>
              r.status == MeetupRequestStatus.rejected ||
              r.status == MeetupRequestStatus.withdrawn,
        )
        .toList();

    return TabBarView(
      children: [
        _buildRequestList(pending, 'No pending requests.'),
        _buildRequestList(accepted, 'No accepted requests yet.'),
        Column(
          children: [
            Expanded(
              child: _buildRequestList(
                rejectedOrWithdrawn,
                'No rejected or withdrawn requests.',
              ),
            ),
            // A withdrawn requester becomes ratable once — this reuses the
            // same RatingPrompt widget the happened-based flow uses
            // elsewhere rather than a bespoke picker, so the score/
            // confirmation/immutability behavior is identical everywhere
            // (ADR-020 §4). It self-hides when nothing here is ratable
            // (e.g. no withdrawn requester, or all already rated), so it's
            // safe to always include on this tab.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: RatingPrompt(meetupId: _meetup.id),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRequestList(List<MeetupRequestModel> requests, String empty) {
    if (requests.isEmpty) {
      return Center(
        child: Text(
          empty,
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: requests.length,
      itemBuilder: (context, index) =>
          _RequestCard(request: requests[index], onRespond: _respond),
    );
  }
}

/// One requester's card in `_RequestManagementPage`'s Pending/Accepted/
/// Rejected tabs (ADR-020 §2) — the same row shape the old single combined
/// list used, just now reused across three filtered lists instead of one.
class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.onRespond});

  final MeetupRequestModel request;
  final void Function(MeetupRequestModel request, bool accept) onRespond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfessionalAvatar(
                  name: request.requesterFullName,
                  imageUrl: request.requesterProfilePhotoUrl.isEmpty
                      ? null
                      : request.requesterProfilePhotoUrl,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    request.requesterFullName,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TrustLevelBadge(trustLevel: request.requesterTrustLevel),
                const SizedBox(width: 6),
                StarRating(
                  average: request.requesterRatingAverage,
                  count: request.requesterRatingCount,
                ),
              ],
            ),
            const SizedBox(height: 10),
            VerificationBadges(trustLevel: request.requesterTrustLevel),
            const SizedBox(height: 12),
            if (request.status == MeetupRequestStatus.pending)
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: 'ACCEPT',
                      height: 40,
                      onPressed: () => onRespond(request, true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SecondaryButton(
                      label: 'REJECT',
                      height: 40,
                      onPressed: () => onRespond(request, false),
                    ),
                  ),
                ],
              )
            else
              Text(
                switch (request.status) {
                  MeetupRequestStatus.accepted => 'ACCEPTED',
                  MeetupRequestStatus.rejected =>
                    request.autoRejected
                        ? 'AUTO-REJECTED (CAPACITY FULL)'
                        : 'REJECTED',
                  MeetupRequestStatus.withdrawn => 'WITHDRAWN',
                  MeetupRequestStatus.pending => 'PENDING',
                },
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontSize: 11,
                ),
              ),
            // Host visibility into this accepted participant's Safety Gate
            // status (ADR-024 §6) — "he is the one who's responsible for
            // the meeting," so if an accepted participant hasn't checked
            // in, the host needs to see that here, in the same place he
            // already sees his accepted participants. The host already got
            // this via push notification the moment it happened (§4); this
            // just makes it visible without having to recall the
            // notification.
            if (request.status == MeetupRequestStatus.accepted) ...[
              const SizedBox(height: 6),
              _SafetyGateStatusLine(request: request),
            ],
            // The requester's own note left when withdrawing (ADR-020 §4) —
            // only present on a withdrawn request, shown as context ahead
            // of the "Rate" action RatingPrompt surfaces below the list.
            if (request.status == MeetupRequestStatus.withdrawn &&
                (request.withdrawalNote?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Text(
                '"${request.withdrawalNote}"',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An accepted participant's Safety Gate status, shown only on the ACCEPTED
/// tab (ADR-024 §6) — "Checked in", "Declined: `<reason>`", or "Not checked
/// in yet". [request.checkedInAt]/[request.declinedAt] are mutually
/// exclusive (enforced server-side); pending/rejected/withdrawn requests
/// never reach this widget at all (gated by the caller).
class _SafetyGateStatusLine extends StatelessWidget {
  const _SafetyGateStatusLine({required this.request});

  final MeetupRequestModel request;

  @override
  Widget build(BuildContext context) {
    if (request.checkedInAt != null) {
      return _statusRow(Icons.check_circle, AppPalette.verified, 'Checked in');
    }
    if (request.declinedAt != null) {
      final reason = request.declineReason;
      return _statusRow(
        Icons.cancel,
        AppPalette.danger,
        (reason == null || reason.isEmpty) ? 'Declined' : 'Declined: $reason',
      );
    }
    return _statusRow(
      Icons.hourglass_empty,
      AppPalette.textSecondary,
      'Not checked in yet',
    );
  }

  Widget _statusRow(IconData icon, Color color, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown while [MeetupService.listMeetupRequests] resolves — mirrors the
/// card shape `_RequestCard` renders once data actually arrives.
class _RequestsSkeleton extends StatelessWidget {
  const _RequestsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 14,
                      opacity: 0.08,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const SkeletonBox(width: 28, height: 16, radius: 8),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                      opacity: 0.04,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
