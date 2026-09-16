import 'dart:async' show Timer;

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
import 'package:professional_connections_platform/core/widgets/faded_picture.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/widgets/slow_load_notice.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_filter_bar.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart';
import 'package:professional_connections_platform/features/meetups/widgets/join_confirmation_sheet.dart';
import 'package:professional_connections_platform/features/meetups/widgets/schedule_conflict_sheet.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';
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
// quantiseViewerCoordinate now lives in viewer_location_provider.dart, next
// to the read whose cache key it shapes.

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

  /// The viewer's position comes from viewerLocationProvider; HomePage
  /// starts that read when it mounts, so by the time this section is
  /// built (often below the fold) the fix is usually already in.
  Future<void> _refreshLocation() =>
      ref.read(viewerLocationProvider.notifier).refresh();

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

  @override
  Widget build(BuildContext context) {
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: SectionHeading('HAPPENING SOON'),
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
    final location = ref.watch(viewerLocationProvider);
    switch (location.status) {
      case ViewerLocationStatus.loading:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            children: [
              const MeetupsSkeleton(shrinkWrap: true),
              // Told, not left to wonder: past the slow threshold the
              // shimmer gets a sentence about what it is waiting on.
              if (location.slow)
                const SlowLoadNotice(
                  key: Key('locationSlowNotice'),
                  icon: Icons.my_location_rounded,
                  message:
                      'Still finding your location. Make sure location is '
                      'on and you have signal.',
                ),
            ],
          ),
        );
      case ViewerLocationStatus.blocked:
        return _LocationBlockedState(
          reason: location.blockReason!,
          onRetry: _refreshLocation,
        );
      case ViewerLocationStatus.ready:
        final viewerLat = location.lat!;
        final viewerLng = location.lng!;
        final key = (
          intent: widget.intent,
          viewerLat: viewerLat,
          viewerLng: viewerLng,
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
            // The skeleton stays a moment, then the failure, with the
            // picture every failed load in the app shares.
            return SkeletonThenFailure(
              skeleton: const Padding(
                padding: EdgeInsets.only(top: 8),
                child: MeetupsSkeleton(shrinkWrap: true),
              ),
              failure: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: FlatCard(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: LoadFailedState(
                    compact: true,
                    failure: LoadFailure.of(error),
                    onRetry: () => ref.invalidate(openMeetupsProvider(key)),
                  ),
                ),
              ),
            );
          }
          // A genuine FIRST load, with nothing to hold on to. The notice
          // times itself from when this skeleton mounted, so a slow network
          // is named after a few seconds instead of shimmering in silence;
          // the request's own deadline turns a dead one into _ErrorState.
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Column(
              children: [
                MeetupsSkeleton(shrinkWrap: true),
                SlowLoadNotice.after(
                  key: Key('networkSlowNotice'),
                  delay: Duration(seconds: 5),
                  icon: Icons.wifi_tethering_rounded,
                  message: 'Slow connection. Still loading meetups near you.',
                ),
              ],
            ),
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
              onRefresh: _refreshLocation,
              loadMore: (cursor) async {
                final next = await ref
                    .read(meetupServiceProvider)
                    .listOpenMeetups(
                      intent: widget.intent,
                      viewerLat: viewerLat,
                      viewerLng: viewerLng,
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
    // Who is hosting, before anything is sent — the sheet only answers
    // yes/no; the request itself still goes through the path below.
    if (!await showJoinConfirmationSheet(context, meetup: meetup)) return;
    if (!context.mounted) return;
    try {
      await ref.read(meetupServiceProvider).requestToJoin(meetup.id);
      if (!context.mounted) return;
      showSnack(context, 'Request sent.', type: ToastType.success);
      ref.invalidate(openMeetupsProvider(key));
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (context.mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } on MeetupScheduleConflictException catch (error) {
      // Already committed elsewhere in this window — see the sheet.
      if (context.mounted) {
        await showScheduleConflictSheet(context, error: error);
      }
    } on MeetupForbiddenException catch (error) {
      // The server's trust gate, which is the one that counts: the card's
      // own check can be stale (a profile that has not refreshed since a
      // verification). Same destination as the locked tap.
      if (!context.mounted) return;
      showSnack(context, error.message, type: ToastType.locked);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
      );
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
    // The app's one failure look, with the location's own sentence and the
    // way to fix it first: settings is the only thing that resolves a
    // denied permission or a disabled service, so it takes the button and
    // TRY AGAIN follows.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: FlatCard(
        radius: 16,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LoadFailedState(
          compact: true,
          failure: LoadFailure(
            LoadFailureKind.location,
            'Turn on location to see meetups near you',
            reason.message,
          ),
          retryLabel: 'OPEN LOCATION SETTINGS',
          retryIcon: Icons.settings_outlined,
          onRetry: () =>
              reason.reason == LocationUnavailableReason.permissionDenied
              ? Geolocator.openAppSettings()
              : Geolocator.openLocationSettings(),
          extraAction: SizedBox(
            width: 200,
            child: SecondaryButton(
              label: 'TRY AGAIN',
              height: 42,
              onPressed: onRetry,
            ),
          ),
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
      radius: 16,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      child: Column(
        children: [
          const FadedPicture(
            asset: 'assets/images/states/no_meetups_soon.jpg',
            height: 150,
          ),
          const SizedBox(height: 6),
          Text(
            'No $scope near you this week',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Host one and let people come to you, or stay ready to join '
            'the moment someone nearby posts one.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppPalette.textSecondary,
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
