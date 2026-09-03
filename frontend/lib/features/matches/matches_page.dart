import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// Browse open meetups for the selected intent, within 40km of the
/// device's current location (ADR-021 §2) — replaces the old mock "nearby
/// professionals" list (ADR-013, frontend/meetup-scheduling-PLAN.md Step
/// 6). Kept as the same route/mount point as the retired MatchesPage for
/// minimal navigation churn.
///
/// Hosting a new meetup used to live behind a "+" icon in this page's own
/// AppBar — confusing, since a user opens this page to browse *other*
/// people's open meetups, not to host their own. That entry point moved to
/// a dedicated "HOST YOUR OWN MEETUP" button on HomePage instead; this page
/// only browses now.
class MatchesPage extends ConsumerStatefulWidget {
  const MatchesPage({super.key});

  @override
  ConsumerState<MatchesPage> createState() => _MatchesPageState();
}

enum _LocationPhase { loading, blocked, ready }

class _MatchesPageState extends ConsumerState<MatchesPage> {
  _LocationPhase _phase = _LocationPhase.loading;
  LocationUnavailableException? _blockReason;
  double? _viewerLat;
  double? _viewerLng;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  /// The on-demand location read this page's whole geo-visibility
  /// behavior hangs off (frontend/geo-visibility-PLAN.md Step 2) — called
  /// once on open, and again on pull-to-refresh; never on a timer, no
  /// `Stream`/continuous listener. On success this is also the one and
  /// only trigger for [AuthService.updateLastKnownLocation] anywhere in
  /// the app — fired fire-and-forget (not awaited) with the exact same
  /// coordinate, so a slow/failed location-update call never blocks the
  /// meetup list from loading.
  Future<void> _loadLocation() async {
    setState(() {
      _phase = _LocationPhase.loading;
      _blockReason = null;
    });
    try {
      final position = await requestCurrentLocation();
      if (!mounted) return;
      setState(() {
        _phase = _LocationPhase.ready;
        _viewerLat = position.latitude;
        _viewerLng = position.longitude;
      });
      unawaited(
        ref
            .read(authServiceProvider)
            .updateLastKnownLocation(
              latitude: position.latitude,
              longitude: position.longitude,
            )
            // Best-effort — the browse list itself already loaded
            // successfully from the same coordinate; a failure here just
            // means this read doesn't get cached for nearby-notification
            // purposes, not something to interrupt browsing over. Still
            // logged (2026-08-31 round-2 hardening) — silent to the user
            // is correct, silent to the developer isn't; same
            // debugPrint('<context> failed: $error') convention
            // http_auth_service.dart/onboarding_flow.dart already use for
            // their own non-fatal failures.
            .catchError(
              (error) => debugPrint('updateLastKnownLocation failed: $error'),
            ),
      );
    } on LocationUnavailableException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _LocationPhase.blocked;
        _blockReason = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final intent = ref.watch(selectedIntentProvider);
    // Level 0 is the safe default while the profile hasn't resolved yet —
    // ADR-014 made Level 0 (Apple/Google/email, no LinkedIn) a real account
    // state, so this must never assume a higher level than confirmed.
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('OPEN MEETUPS')),
      body: Column(
        children: [
          // Switching the browsed intent used to mean leaving this page
          // entirely (back to Home's intent grid, then FIND MATCHES
          // again) — these tabs let it happen without leaving the list.
          _IntentTabsBar(
            selected: intent,
            trustLevel: trustLevel,
            onSelect: (picked) {
              if (!picked.isUnlockedFor(trustLevel)) {
                showSnack(
                  context,
                  '${picked.label} requires Level ${picked.requiredTrustLevel} trust. Verify your phone, personal email, and details in Profile to unlock it.',
                  type: ToastType.locked,
                );
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const VerificationChecklistPage(),
                  ),
                );
                return;
              }
              ref.read(selectedIntentProvider.notifier).state = picked;
            },
          ),
          Expanded(child: _buildBody(context, intent, trustLevel)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, IntentType intent, int trustLevel) {
    switch (_phase) {
      case _LocationPhase.loading:
        return const _MeetupsSkeleton();
      case _LocationPhase.blocked:
        return _LocationBlockedState(
          reason: _blockReason!,
          onRetry: _loadLocation,
        );
      case _LocationPhase.ready:
        final key = (
          intent: intent,
          viewerLat: _viewerLat!,
          viewerLng: _viewerLng!,
        );
        final meetupsAsync = ref.watch(openMeetupsProvider(key));
        return RefreshIndicator(
          onRefresh: _loadLocation,
          child: meetupsAsync.when(
            loading: () => const _MeetupsSkeleton(),
            error: (error, stack) => _ErrorState(
              onRetry: () => ref.invalidate(openMeetupsProvider(key)),
            ),
            data: (page) => _MeetupList(
              page: page,
              intent: intent,
              viewerLat: _viewerLat!,
              viewerLng: _viewerLng!,
              onRequestToJoin: (meetup) => _requestToJoin(context, meetup),
              onCardTapped: (meetup) async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MeetupDetailPage(meetupId: meetup.id),
                  ),
                );
                ref.invalidate(openMeetupsProvider(key));
              },
            ),
          ),
        );
    }
  }

  Future<void> _requestToJoin(BuildContext context, Meetup meetup) async {
    try {
      await ref.read(meetupServiceProvider).requestToJoin(meetup.id);
      if (!context.mounted) return;
      showSnack(context, 'Request sent.', type: ToastType.success);
      if (_viewerLat != null && _viewerLng != null) {
        ref.invalidate(
          openMeetupsProvider((
            intent: meetup.intent,
            viewerLat: _viewerLat!,
            viewerLng: _viewerLng!,
          )),
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      showSnack(
        context,
        error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }
}

/// Blocks the browse list entirely and shows a real prompt instead of
/// silently falling back to an unfiltered list or an unexplained empty one
/// (ADR-021 §3 — this must be a visible block). The action button opens
/// the specific system settings screen the failure actually calls for.
class _LocationBlockedState extends StatelessWidget {
  const _LocationBlockedState({required this.reason, required this.onRetry});

  final LocationUnavailableException reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.location_off_outlined,
                color: AppPalette.textSecondary,
                size: 32,
              ),
              const SizedBox(height: 14),
              Text(
                'Turn on location to see meetups near you',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                reason.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: 'OPEN LOCATION SETTINGS',
                height: 44,
                onPressed: () =>
                    reason.reason == LocationUnavailableReason.permissionDenied
                    ? Geolocator.openAppSettings()
                    : Geolocator.openLocationSettings(),
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'TRY AGAIN',
                height: 44,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
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
              'Could not load meetups.',
              style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            PrimaryButton(label: 'RETRY', height: 40, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

/// (2026-08-31 round-3 hardening, Fix 1) — the backend's `listOpenMeetups`
/// already returns a real cursor (`PagedResult.nextCursor`/`hasMore`); this
/// widget is what actually uses them, appending a next page when the user
/// scrolls near the bottom instead of silently capping the list at page 1
/// forever. Stateful (not the old `StatelessWidget`) because it owns the
/// accumulated item list across pages — [page] itself only ever carries the
/// *first* page, reloaded from [openMeetupsProvider] on pull-to-refresh or
/// intent switch.
class _MeetupList extends ConsumerStatefulWidget {
  const _MeetupList({
    required this.page,
    required this.intent,
    required this.viewerLat,
    required this.viewerLng,
    required this.onRequestToJoin,
    required this.onCardTapped,
  });

  final PagedResult<Meetup> page;
  final IntentType intent;
  final double viewerLat;
  final double viewerLng;
  final void Function(Meetup meetup) onRequestToJoin;
  final void Function(Meetup meetup) onCardTapped;

  @override
  ConsumerState<_MeetupList> createState() => _MeetupListState();
}

class _MeetupListState extends ConsumerState<_MeetupList> {
  late List<Meetup> _items;
  String? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _resetFromPage(widget.page);
    _scrollController.addListener(_maybeLoadNextPage);
  }

  @override
  void didUpdateWidget(covariant _MeetupList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 2026-08-31 round-4 hardening: corrected — this does NOT handle
    // pull-to-refresh or an intent switch. Both of those flip `_buildBody`
    // through `_MeetupsSkeleton()` first (pull-to-refresh via `_phase`
    // going through `.loading`; an intent switch via `openMeetupsProvider`
    // resolving to a brand-new, never-fetched family instance), which
    // tears this whole widget down and mounts a fresh one afterwards —
    // `initState`/`_resetFromPage` above handles that case, not this one.
    // What this branch actually catches: `_MeetupList` staying mounted
    // while its *existing* `page` gets invalidated in place (e.g.
    // `_requestToJoin`'s `ref.invalidate(openMeetupsProvider(key))` on the
    // same, already-fetched key) — Riverpod's default
    // skipLoadingOnRefresh keeps `.when()` in its `data:` branch with the
    // stale value while refetching, so a new `page` instance arrives here
    // without ever passing through `loading:`/`initState` at all. Reset
    // from it the same way, so a page-2 fetch in flight when that happens
    // doesn't get appended onto a now-stale first page.
    if (!identical(widget.page, oldWidget.page)) {
      _resetFromPage(widget.page);
    }
  }

  void _resetFromPage(PagedResult<Meetup> page) {
    _items = List.of(page.items);
    _nextCursor = page.nextCursor;
    _hasMore = page.hasMore;
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
      final next = await ref
          .read(meetupServiceProvider)
          .listOpenMeetups(
            intent: widget.intent,
            viewerLat: widget.viewerLat,
            viewerLng: widget.viewerLng,
            cursor: _nextCursor,
          );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...next.items];
        _nextCursor = next.nextCursor;
        _hasMore = next.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      // Best-effort — the current page stays visible; scrolling again
      // retries. No snack/toast here since this fires from a scroll
      // listener, not a user-initiated action.
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      // Still wrapped in a scrollable (ListView, not a bare Center) so
      // RefreshIndicator's pull-to-refresh gesture keeps working even
      // when there's nothing to show yet.
      return ListView(
        controller: _scrollController,
        children: [
          SizedBox(
            height: 300,
            child: Center(
              child: Text(
                'No open meetups nearby for this intent yet.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
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
        final meetup = _items[index];
        return _MeetupCard(
          meetup: meetup,
          onRequestToJoin: () => widget.onRequestToJoin(meetup),
          onTap: () => widget.onCardTapped(meetup),
        );
      },
    );
  }
}

class _MeetupCard extends StatelessWidget {
  const _MeetupCard({
    required this.meetup,
    required this.onRequestToJoin,
    required this.onTap,
  });

  final Meetup meetup;
  final VoidCallback onRequestToJoin;
  final VoidCallback onTap;

  /// ADR-028 § 2 — a locked meetup's card tap and join-button tap both
  /// redirect here instead of reaching [onTap]/[onRequestToJoin]: a toast
  /// (same wording pattern as the intent-picker's locked-intent toasts —
  /// see intent_picker_sheet.dart), then the focused checklist. The tap
  /// never reaches RequestToJoin while locked, same as the disabled-button
  /// pattern this replaces — only the destination changes, from a dead end
  /// to somewhere that actually helps.
  void _handleLockedTap(BuildContext context) {
    showSnack(
      context,
      '${meetup.intent.label} requires Level ${meetup.intent.requiredTrustLevel} trust. Verify your phone, personal email, and details to unlock it.',
      type: ToastType.locked,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final full = meetup.acceptedCount >= meetup.capacity;
    final locked = meetup.lockedForViewer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: locked ? () => _handleLockedTap(context) : onTap,
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (locked)
                const LockedCardHeader()
              else
                _CardHeader(meetup: meetup),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _tag(meetup.intent.label),
                        // The time window is one of the fields ADR-028
                        // redacts — omitted entirely for a locked meetup
                        // rather than showing an empty tag.
                        if (!locked) _tag(meetup.formattedWindow),
                        _tag(
                          '${meetup.acceptedCount}/${meetup.capacity} JOINED',
                        ),
                      ],
                    ),
                  ),
                  MeetupStatusBadge(status: meetup.status),
                ],
              ),
              const SizedBox(height: 14),
              if (locked)
                PrimaryButton(
                  label: 'REQUEST TO JOIN',
                  height: 42,
                  onPressed: () => _handleLockedTap(context),
                )
              else if (meetup.isHostedByMe)
                _StatusPill(
                  label: 'YOU\'RE HOSTING',
                  color: AppPalette.candyBlue,
                )
              else if (meetup.myRequestStatus != null)
                _StatusPill(
                  label: switch (meetup.myRequestStatus!) {
                    MeetupRequestStatus.pending => 'REQUEST PENDING',
                    MeetupRequestStatus.accepted => 'YOU\'RE IN',
                    MeetupRequestStatus.rejected => 'REQUEST DECLINED',
                    MeetupRequestStatus.withdrawn => 'WITHDRAWN',
                  },
                  color: switch (meetup.myRequestStatus!) {
                    MeetupRequestStatus.pending => AppPalette.candyBlue,
                    MeetupRequestStatus.accepted => AppPalette.verified,
                    MeetupRequestStatus.rejected => AppPalette.danger,
                    MeetupRequestStatus.withdrawn => AppPalette.textSecondary,
                  },
                )
              else
                PrimaryButton(
                  label: full ? 'FULL' : 'REQUEST TO JOIN',
                  height: 42,
                  onPressed: full ? null : onRequestToJoin,
                ),
              const SizedBox(height: 10),
              // ADR-029 (round-8 hardening) — same lockedForViewer gate as
              // every other action on this card (LocationViewPage.open
              // handles the toast+redirect itself), shown regardless of
              // hosting/request state.
              SecondaryButton(
                label: 'VIEW LOCATION',
                height: 38,
                onPressed: () => LocationViewPage.open(context, meetup),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: AppPalette.candyBlue.withValues(alpha: 0.10),
        border: Border.all(color: AppPalette.candyBlue.withValues(alpha: 0.30)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
          color: AppPalette.candyBlue,
        ),
      ),
    );
  }
}

/// The normal (unlocked) header: real avatar/name/location/rating —
/// exactly what `_MeetupCard` always rendered before ADR-028, split out so
/// [LockedCardHeader] can stand in for it without duplicating the rest of
/// the card.
class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ProfessionalAvatar(
          name: meetup.hostFullName,
          imageUrl: (meetup.hostProfilePhotoUrl?.isEmpty ?? true)
              ? null
              : meetup.hostProfilePhotoUrl,
          size: 48,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      // hostFullName is only ever null for a locked meetup
                      // (ADR-028) — _MeetupCard never mounts this widget in
                      // that case, so this is always real data here.
                      meetup.hostFullName!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TrustLevelBadge(trustLevel: meetup.hostTrustLevel),
                  const SizedBox(width: 6),
                  StarRating(
                    average: meetup.hostRatingAverage,
                    count: meetup.hostRatingCount,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                meetup.locationLabel!,
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 6),
              VerificationBadges(trustLevel: meetup.hostTrustLevel),
            ],
          ),
        ),
      ],
    );
  }
}

/// ADR-028 § 2 — stands in for [_CardHeader] on a `lockedForViewer` meetup:
/// a frosted lock icon in place of the avatar, blurred placeholder bars
/// (reusing [SkeletonBox], this app's existing placeholder-shimmer
/// language) in place of the real name/location text, and a short caption
/// explaining why. Never renders real host data — there isn't any to
/// render, the server already redacted it.
class LockedCardHeader extends StatelessWidget {
  const LockedCardHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppPalette.textSecondary.withValues(alpha: 0.12),
            border: Border.all(
              color: AppPalette.textSecondary.withValues(alpha: 0.3),
            ),
          ),
          child: Icon(
            Icons.lock_outline_rounded,
            size: 20,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(width: 120, height: 13, opacity: 0.08),
              const SizedBox(height: 6),
              const SkeletonBox(width: 90, height: 11),
              const SizedBox(height: 6),
              Text(
                'Verify to see details',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class _MeetupsSkeleton extends StatelessWidget {
  const _MeetupsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 48, height: 48, radius: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SkeletonBox(
                          width: 120,
                          height: 12,
                          opacity: 0.08,
                        ),
                        const SizedBox(height: 6),
                        const SkeletonBox(width: 80, height: 10),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, constraints) => SkeletonBox(
                  width: constraints.maxWidth,
                  height: 38,
                  radius: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One chip per [IntentType], letting the browsed intent be switched
/// without leaving this page — matches this page's own filter
/// (`selectedIntentProvider`), same locked/unlocked visual language as
/// HomePage's IntentTile (dimmed + a lock icon, not hidden entirely).
class _IntentTabsBar extends StatelessWidget {
  const _IntentTabsBar({
    required this.selected,
    required this.trustLevel,
    required this.onSelect,
  });

  final IntentType selected;
  final int trustLevel;
  final void Function(IntentType intent) onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        itemCount: IntentType.values.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final intent = IntentType.values[index];
          final isSelected = intent == selected;
          final locked = !intent.isUnlockedFor(trustLevel);
          return GestureDetector(
            onTap: () => onSelect(intent),
            child: FlatCard(
              radius: 10,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tint: isSelected
                  ? AppPalette.candyBlue.withValues(alpha: 0.15)
                  : null,
              border: isSelected
                  ? AppPalette.candyBlue.withValues(alpha: 0.6)
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    locked ? Icons.lock_outline : intent.icon,
                    size: 15,
                    color: locked
                        ? AppPalette.textSecondary
                        : (isSelected
                              ? AppPalette.candyBlue
                              : AppPalette.textPrimary),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    intent.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: locked
                          ? AppPalette.textSecondary
                          : (isSelected
                                ? AppPalette.candyBlue
                                : AppPalette.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
