import 'dart:async' show Timer, unawaited;

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
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_filter_bar.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';

/// How far ahead "Happening Soon" looks. Passed through to the backend's
/// `within_days` filter — a real server-side narrowing, not a client-side
/// slice of an unbounded list, so the pagination underneath it pages through
/// only meetups in this window.
///
/// WIDENED FROM 7 TO 28 when the list started grouping by week. Grouping a
/// seven-day window into weeks produces exactly one group, which is not a
/// grouping — four weeks is the smallest window where "This week / Next week
/// / the week after" says anything. "Soon" still holds at a month for a
/// marketplace where most areas have a handful of meetups.
const happeningSoonWithinDays = 28;

/// Home's browse section — the open-meetups list that used to be a whole
/// separate "Matches" tab.
///
/// It owns the on-demand location read that browsing needs (the 40km
/// ST_DWithin filter, ADR-021 §2) because it is the only thing on Home that
/// needs one. Same read the deleted browse page did: once on mount, again on
/// pull-to-refresh, never on a timer.
///
/// Renders inside Home's single scrolling ListView, so its list is in
/// shrink-wrap mode: this section does not scroll, the page does.
///
/// # HOW THE TWO LISTS ARE ACTUALLY CONNECTED
///
/// This comment used to say "the parent owns scrolling, and therefore owns
/// infinite-scroll and pull-to-refresh too". Half of that was true and half
/// was an aspiration nothing implemented. Pull-to-refresh really is the
/// page's RefreshIndicator. Infinite scroll was NOT wired at all: the nested
/// list watched a ScrollController of its own that, in shrink-wrap mode, is
/// attached to nothing, and Home had no controller to watch instead. The
/// result was a browse list permanently stuck on page one, with no error and
/// no indicator (docs/plans/07-happening-soon-pagination-fix.md).
///
/// What connects them now is [outerScrollController]: Home owns the
/// controller on its own ListView and passes it down through here to
/// [PaginatedMeetupList], which watches that position for the near-bottom
/// threshold. Nothing else bridges the two — if this stops being passed,
/// pagination silently dies again, which is why it is required here even
/// though the underlying widget accepts null.
class HappeningSoonSection extends ConsumerStatefulWidget {
  const HappeningSoonSection({
    super.key,
    required this.intent,
    required this.trustLevel,
    required this.onSelectIntent,
    required this.outerScrollController,
  });

  /// Null means every intent — Home's "All" chip.
  final IntentType? intent;

  /// Drives which chips render as locked. Passed in rather than read here so
  /// the page and this section can never disagree about the viewer's level
  /// mid-frame — the page uses the same value for its host-side gate.
  final int trustLevel;

  /// Called with the tapped intent, or null for "All". Home owns what a
  /// locked chip does (a toast plus the verification checklist), because
  /// that is a navigation decision, not a list concern.
  final void Function(IntentType? intent) onSelectIntent;

  /// The scroll position of the page this section is embedded in — see the
  /// class comment. Required, not optional: a null here is exactly the bug
  /// this parameter exists to prevent.
  final ScrollController outerScrollController;

  @override
  ConsumerState<HappeningSoonSection> createState() =>
      _HappeningSoonSectionState();
}

enum _LocationPhase { loading, blocked, ready }

class _HappeningSoonSectionState extends ConsumerState<HappeningSoonSection> {
  /// The last page this section successfully showed, kept across an intent
  /// change.
  ///
  /// # WHY THIS IS HELD AT ALL
  ///
  /// Each intent is a different `openMeetupsProvider` family key, so
  /// switching filters watches a provider with NO cached value. The section
  /// therefore collapsed to a placeholder — and, for that placeholder's
  /// first 180ms, to nothing at all. Home's content got shorter, the scroll
  /// position clamped to the new (smaller) maxScrollExtent, and the page
  /// jumped upward under the user's thumb at the moment they tapped.
  ///
  /// Holding the previous results keeps the section roughly its own height
  /// while the new filter loads, so nothing moves. It also reads better: an
  /// empty section for a beat says "there is nothing here", which is a
  /// different and wrong message from "loading".
  PagedResult<Meetup>? _lastPage;

  /// How long a filter swap may sit on the stale list before conceding that
  /// this is a real wait and showing a skeleton.
  ///
  /// Under this, the dim alone is the right cue: swapping to a skeleton for
  /// two frames would flash. Over it, a dimmed list that never resolves stops
  /// reading as "loading" and starts reading as "broken" — a slow network
  /// deserves the same honest placeholder a first load gets.
  static const _slowSwapThreshold = Duration(milliseconds: 450);

  Timer? _slowSwapTimer;
  bool _slowSwap = false;

  _LocationPhase _phase = _LocationPhase.loading;
  LocationUnavailableException? _blockReason;
  double? _viewerLat;
  double? _viewerLng;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  @override
  void didUpdateWidget(HappeningSoonSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intent != widget.intent) {
      // A new filter starts a new wait. The timer is what decides whether
      // this swap gets the quiet dim or the full placeholder.
      _slowSwap = false;
      _slowSwapTimer?.cancel();
      _slowSwapTimer = Timer(_slowSwapThreshold, () {
        if (mounted) setState(() => _slowSwap = true);
      });
    }
  }

  @override
  void dispose() {
    _slowSwapTimer?.cancel();
    super.dispose();
  }

  /// Carried over unchanged from the deleted browse page: the single
  /// on-demand location read the whole geo-visibility behaviour hangs off,
  /// and the app's only trigger for [AuthService.updateLastKnownLocation],
  /// fired fire-and-forget so a slow location-update call never blocks the
  /// list from loading.
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
            .catchError(
              // TYPE AND A FIXED MESSAGE, never the raw error object.
              // debugPrint is not stripped from release builds, and while
              // the typed exceptions this codebase throws carry only
              // sanitized messages, an untyped one (a PlatformException
              // from the geolocator plugin, an HTTP client error) can put
              // far more into its toString() than intended.
              (error) => debugPrint(
                'updateLastKnownLocation failed: ${error.runtimeType}',
              ),
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
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: SectionLabel('HAPPENING SOON'),
        ),
        const SizedBox(height: 10),
        // Directly under the heading it belongs to, and above every body
        // state — a user whose location is blocked, or whose current filter
        // is empty, still needs to be able to change it. Rendering it only
        // alongside a populated list would strand them.
        IntentFilterBar(
          selected: widget.intent,
          trustLevel: widget.trustLevel,
          onSelect: widget.onSelectIntent,
        ),
        const SizedBox(height: 4),
        _buildBody(context, trustLevel),
      ],
    );
  }

  Widget _buildBody(BuildContext context, int trustLevel) {
    switch (_phase) {
      case _LocationPhase.loading:
        return const Padding(
          padding: EdgeInsets.only(top: 8),
          child: MeetupsSkeleton(shrinkWrap: true),
        );
      case _LocationPhase.blocked:
        return _LocationBlockedState(
          reason: _blockReason!,
          onRetry: _loadLocation,
        );
      case _LocationPhase.ready:
        final key = (
          intent: widget.intent,
          viewerLat: _viewerLat!,
          viewerLng: _viewerLng!,
          withinDays: happeningSoonWithinDays,
        );
        final meetupsAsync = ref.watch(openMeetupsProvider(key));

        // # WHY THIS IS NOT `.when()`
        //
        // Riverpod 3 retries a failed provider automatically, with backoff.
        // While a retry is pending the state is `AsyncLoading` that CARRIES
        // the error — so `.when()` takes its `loading:` branch and the user
        // sits on a shimmer indefinitely, silently, with no error and no way
        // to retry by hand. The failure card below was effectively
        // unreachable until the retries gave up.
        //
        // Ordered by what is most useful to show, which is not the same as
        // the state machine's own order:
        //
        //   1. any page we have -> show it, even mid-refresh, so a refresh
        //      never blanks the list the user is reading;
        //   2. otherwise an error -> show it as soon as the FIRST attempt
        //      fails, rather than after the retry schedule runs out. The
        //      background retry keeps going regardless, and lands on (1) if
        //      it succeeds;
        //   3. otherwise a genuine first load -> skeleton.
        // Cached during build rather than via setState: this is derived
        // from what we are already rendering, and writing it here cannot
        // schedule another frame.
        if (meetupsAsync.hasValue) {
          _lastPage = meetupsAsync.requireValue;
          // The wait is over; a later swap starts its own timer.
          _slowSwapTimer?.cancel();
          _slowSwap = false;
        }

        // Anything we can show beats showing nothing — the freshly-watched
        // key's value if it has one, otherwise whatever we last displayed.
        final page = meetupsAsync.value ?? _lastPage;

        if (page == null) {
          if (meetupsAsync.error case final error?) {
            return _ErrorState(
              error: error,
              onRetry: () => ref.invalidate(openMeetupsProvider(key)),
            );
          }
          // A genuine FIRST load, with nothing to hold on to.
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: MeetupsSkeleton(shrinkWrap: true),
          );
        }

        // Showing the previous filter's results while the new one loads.
        final stale = !meetupsAsync.hasValue;

        // A slow network gets a real placeholder rather than an indefinitely
        // dimmed list. Sized to the stale list it replaces so the page keeps
        // its height and the scroll position stays put.
        if (stale && _slowSwap) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: MeetupsSkeleton(
              shrinkWrap: true,
              cardCount: page.items.isEmpty ? 2 : page.items.length.clamp(1, 4),
            ),
          );
        }
        return AnimatedOpacity(
          // The "something is happening" cue, and the reason the swap feels
          // deliberate rather than like a stutter. A finite animation on
          // purpose: an indeterminate spinner here would never let
          // pumpAndSettle finish, the same trap the loading shimmer hit.
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          opacity: stale ? 0.35 : 1,
          child: IgnorePointer(
            // Taps during the swap would act on rows that are about to be
            // replaced — a request sent to the wrong meetup.
            ignoring: stale,
            child: PaginatedMeetupList(
              items: page.items,
              nextCursor: page.nextCursor,
              hasMore: page.hasMore,
              // Nested inside Home's own ListView — the parent scrolls, so
              // this must not. Pull-to-refresh for this section is Home's
              // RefreshIndicator, which refreshes the location read and the
              // active-meetups list together.
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              outerScrollController: widget.outerScrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              // Kept as the plain-text fallback for anything that renders
              // this list without an emptyState; `emptyState` is what actually
              // shows here.
              emptyMessage: widget.intent == null
                  ? 'No meetups happening near you in the next week yet.'
                  : 'No ${widget.intent!.label.toLowerCase()} meetups near you in the next week yet.',
              emptyState: _NoMeetupsYet(intent: widget.intent),
              onRefresh: _loadLocation,
              loadMore: (cursor) async {
                final next = await ref
                    .read(meetupServiceProvider)
                    .listOpenMeetups(
                      intent: widget.intent,
                      viewerLat: _viewerLat!,
                      viewerLng: _viewerLng!,
                      cursor: cursor,
                      withinDays: happeningSoonWithinDays,
                    );
                return (
                  items: next.items,
                  nextCursor: next.nextCursor,
                  hasMore: next.hasMore,
                );
              },
              // A week header is emitted with the first card of each week rather
              // than by a separate grouped-list widget: the list is paginated,
              // so the groups are not known up front — page two can extend the
              // last group or start a new one, and comparing against the card
              // above handles both without the list having to re-group.
              itemBuilder: (context, meetup, previous) {
                final card = MeetupCard(
                  meetup: meetup,
                  viewerTrustLevel: trustLevel,
                  onRequestToJoin: () => _requestToJoin(context, meetup, key),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MeetupDetailPage(meetupId: meetup.id),
                      ),
                    );
                    ref.invalidate(openMeetupsProvider(key));
                  },
                );

                if (!startsNewWeek(meetup, previous)) return card;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: previous == null ? 0 : 8),
                      child: SectionLabel(weekLabelFor(meetup)),
                    ),
                    const SizedBox(height: 10),
                    card,
                  ],
                );
              },
            ),
          ),
        );
    }
  }

  Future<void> _requestToJoin(
    BuildContext context,
    Meetup meetup,
    ({IntentType? intent, double viewerLat, double viewerLng, int withinDays})
    key,
  ) async {
    try {
      await ref.read(meetupServiceProvider).requestToJoin(meetup.id);
      if (!context.mounted) return;
      showSnack(context, 'Request sent.', type: ToastType.success);
      ref.invalidate(openMeetupsProvider(key));
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

/// Blocks this section (not the whole page) and shows a real prompt rather
/// than an unexplained empty list — ADR-021 §3's visible-block requirement.
/// Everything else on Home still works without a location.
class _LocationBlockedState extends StatelessWidget {
  const _LocationBlockedState({required this.reason, required this.onRetry});

  final LocationUnavailableException reason;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.location_off_outlined,
              color: AppPalette.textSecondary,
              size: 28,
            ),
            const SizedBox(height: 12),
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
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'OPEN LOCATION SETTINGS',
              height: 42,
              onPressed: () =>
                  reason.reason == LocationUnavailableReason.permissionDenied
                  ? Geolocator.openAppSettings()
                  : Geolocator.openLocationSettings(),
            ),
            const SizedBox(height: 8),
            SecondaryButton(label: 'TRY AGAIN', height: 42, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

/// Shown when the fetch FAILED — never when it succeeded and returned
/// nothing. That case is [_NoMeetupsYet], and conflating the two tells a
/// user their connection is broken when the truth is that their area is
/// quiet this week.
///
/// The connectivity copy is reserved for [MeetupOfflineException], the one
/// error type that actually means the request never left the device. A 500,
/// a 400 or a malformed body all reached the server, so blaming the user's
/// network for them would send them to go restart their router over a
/// problem on our side.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = error is MeetupOfflineException;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.wifi_off_outlined : Icons.error_outline_rounded,
              color: AppPalette.textSecondary,
              size: 26,
            ),
            const SizedBox(height: 10),
            Text(
              offline ? 'You\'re offline' : 'Could not load meetups right now',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              offline
                  ? 'Check your connection and try again.'
                  : 'This one is on us, not you. Please try again in a moment.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 14),
            PrimaryButton(label: 'RETRY', height: 40, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}

/// Shown when the fetch SUCCEEDED and there is simply nothing scheduled
/// nearby — a normal, expected state in a new area, not a failure.
///
/// So it reads as an invitation rather than an apology: it names the gap,
/// points at the HOST YOUR OWN MEETUP button that is already pinned at the
/// bottom of this page, and says what happens if they would rather wait.
///
/// Deliberately NOT its own host button: Home's CTA is permanently on
/// screen a few centimetres below this card and carries the host-side trust
/// gate (ADR-002 §4). A second entry point here would either duplicate that
/// gate or, worse, skip it.
class _NoMeetupsYet extends StatelessWidget {
  const _NoMeetupsYet({required this.intent});

  final IntentType? intent;

  @override
  Widget build(BuildContext context) {
    final scope = intent == null
        ? 'meetups'
        : '${intent!.label.toLowerCase()} meetups';

    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.groups_2_outlined, color: AppPalette.candyBlue, size: 30),
          const SizedBox(height: 12),
          Text(
            'No $scope near you this week',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to put one on the calendar... hosting takes a '
            'minute. Or check back soon: new meetups appear here as soon as '
            'someone nearby schedules one.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Monday that starts [date]'s week, at midnight local time.
///
/// Weeks are Monday-based rather than Sunday-based: the app's meetups are
/// professional ones, and "this week" for a work meeting means the working
/// week. Normalised to midnight so two meetups on the same day always land in
/// the same bucket regardless of their times.
@visibleForTesting
DateTime startOfWeek(DateTime date) {
  final midnight = DateTime(date.year, date.month, date.day);
  return midnight.subtract(Duration(days: midnight.weekday - DateTime.monday));
}

/// True when [meetup] opens a new week relative to the card above it.
///
/// [previous] null means this is the first card, which always opens a group.
@visibleForTesting
bool startsNewWeek(Meetup meetup, Meetup? previous) {
  if (meetup.windowStart == null) return false;
  if (previous?.windowStart == null) return true;
  return startOfWeek(meetup.windowStart!) !=
      startOfWeek(previous!.windowStart!);
}

/// The header shown above a week's first card.
///
/// Named relatively for the two weeks a user actually plans around, and by
/// date after that — "Week of 22 Sep" is meaningful where "In 3 weeks" makes
/// the reader do arithmetic.
@visibleForTesting
String weekLabelFor(Meetup meetup, {DateTime? now}) {
  final start = meetup.windowStart;
  if (start == null) return 'LATER';

  final thisWeek = startOfWeek(now ?? DateTime.now());
  final week = startOfWeek(start);
  final weeksAway = week.difference(thisWeek).inDays ~/ 7;

  // Negative can happen legitimately: a meetup that began before now is
  // still "happening" until its window ends, and the server includes it.
  if (weeksAway <= 0) return 'THIS WEEK';
  if (weeksAway == 1) return 'NEXT WEEK';
  return 'WEEK OF ${_shortDate(week)}';
}

String _shortDate(DateTime date) {
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return '${date.day} ${months[date.month - 1]}';
}
