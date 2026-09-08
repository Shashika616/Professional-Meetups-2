import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/rating_prompt.dart';

/// How far ahead of a meetup's `windowStart` the persistent card starts
/// showing it (ADR-025 §2/§4) — a display-only window computed from the
/// timestamps `listActiveMeetups()` already returns; the *inclusion* in
/// the active list itself is entirely server-decided.
const Duration _cardLeadTime = Duration(minutes: 30);

/// ADR-030 (round-9) — reconciles a real inconsistency: [_PersistentMeetupCard]
/// used to do its own independent `DateTime.now().isAfter(windowEnd)` check
/// to decide when to flip to a rating prompt, while [_ActiveMeetupRow] below
/// it just trusted the server's `status` field for its badge. Both already
/// read from the same [Meetup] (there's no separate cache/provider between
/// them — that theory was checked and ruled out), so once a real refetch
/// exists the two are never stale relative to *each other*, but they could
/// still disagree for a real, structural reason: the backend's lifecycle
/// poller only ticks every 60s (ADR-025 §4), so a meetup can sit with
/// `status: open`/`full` server-side for up to a minute after its
/// `windowEnd` has already passed client-side. This one helper is what both
/// widgets check now, so they agree with each other immediately the moment
/// `windowEnd` passes, not just whenever the next poller tick or refetch
/// happens to land.
MeetupStatus _effectiveStatus(Meetup meetup) {
  final windowEnd = meetup.windowEnd;
  if (windowEnd != null &&
      (meetup.status == MeetupStatus.open ||
          meetup.status == MeetupStatus.full) &&
      DateTime.now().isAfter(windowEnd)) {
    return MeetupStatus.completed;
  }
  return meetup.status;
}

/// Active-meetups dashboard section + persistent swipeable card (ADR-025,
/// frontend/active-meetups-lifecycle-PLAN.md). Supersedes the old, purely
/// client-merged `UpcomingMeetupCard` — `listActiveMeetups()` now does that
/// merge (and decides what counts as "active") server-side, matching this
/// codebase's "client never decides, only displays" principle; showing
/// both the old ad hoc card and this section side by side would just be
/// duplicate, confusing UI, so this replaces it rather than adding
/// alongside it.
///
/// A periodic local timer drives the "converts in place once windowEnd
/// passes" behavior (ADR-025 §4) and lets a not-yet-eligible meetup enter
/// its 30-minute pre-window without needing a manual refresh — purely a
/// clock re-check against timestamps already in hand, no new backend call
/// (same "no new realtime infrastructure" constraint the ADR states).
class ActiveMeetupsSection extends ConsumerStatefulWidget {
  const ActiveMeetupsSection({super.key});

  @override
  ConsumerState<ActiveMeetupsSection> createState() =>
      _ActiveMeetupsSectionState();
}

class _ActiveMeetupsSectionState extends ConsumerState<ActiveMeetupsSection> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(activeMeetupsProvider).value ?? const <Meetup>[];
    if (active.isEmpty) return const SizedBox.shrink();

    final now = DateTime.now();
    // windowStart/windowEnd/hostFullName/locationLabel are only ever null
    // for a locked ListOpenMeetups result (ADR-028) — listActiveMeetups()
    // never redacts, so `!` here documents that guarantee.
    final cardEligible = active
        .where((m) => !now.isBefore(m.windowStart!.subtract(_cardLeadTime)))
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cardEligible.isNotEmpty) ...[
            const SectionLabel('HAPPENING NOW'),
            const SizedBox(height: 16),
            _PersistentMeetupCardSet(meetups: cardEligible),
            const SizedBox(height: 24),
          ],
          const SectionLabel('ACTIVE MEETUPS'),
          const SizedBox(height: 16),
          // Deliberately `Column`/`.map`, not `ListView.builder` (2026-08-31
          // round-3 hardening, Fix 2 — see frontend/round-3-performance-
          // hardening-PLAN.md). This whole section is already mounted
          // inside HomePage's own outer `ListView`; a nested `ListView`
          // here would need `shrinkWrap: true` +
          // `NeverScrollableScrollPhysics()` to avoid double-scroll
          // conflicts, buying nothing for a list the server already scopes
          // to open/full + unexpired (realistically small) — eager build
          // here isn't the inconsistency the audit's "used everywhere else"
          // framing assumed.
          ...active.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ActiveMeetupRow(meetup: m),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders [meetups] as a single card, or a swipeable `PageView` when more
/// than one is concurrently eligible (ADR-025 §4).
///
/// # WHY THERE ARE DOTS NOW
///
/// The multi-card case was a bare `PageView` with no affordance of any kind:
/// a second meetup was reachable only by a user who happened to swipe a card
/// that gave no sign it could be swiped. Page dots are the smallest thing
/// that says "there is more here", and they double as position while
/// swiping.
///
/// The fixed height dropped from 232 to [_cardHeight]. 232 was well past
/// what the content needs, which is why the card rendered with a large dead
/// area under the location line.
class _PersistentMeetupCardSet extends StatefulWidget {
  const _PersistentMeetupCardSet({required this.meetups});

  final List<Meetup> meetups;

  @override
  State<_PersistentMeetupCardSet> createState() =>
      _PersistentMeetupCardSetState();
}

class _PersistentMeetupCardSetState extends State<_PersistentMeetupCardSet> {
  final _controller = PageController();
  int _page = 0;

  /// Sized for the real content — badge row, host name, window, and a
  /// two-line location — plus slack so a long place name or a larger text
  /// scale does not clip.
  static const double _cardHeight = 176;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.meetups.length == 1) {
      return _PersistentMeetupCard(meetup: widget.meetups.first);
    }

    return Column(
      children: [
        SizedBox(
          height: _cardHeight,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (index) => setState(() => _page = index),
            itemCount: widget.meetups.length,
            itemBuilder: (context, index) => Padding(
              // Room for the elevated card's cast shadow, which would
              // otherwise be clipped by the PageView's own bounds.
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
              child: _PersistentMeetupCard(meetup: widget.meetups[index]),
            ),
          ),
        ),
        const SizedBox(height: 4),
        _PageDots(count: widget.meetups.length, current: _page),
      ],
    );
  }
}

/// The "there is more than one of these" affordance.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // The dots are decoration; the count is the information.
      label: 'Meetup ${current + 1} of $count',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 6,
              // The active dot stretches rather than just darkening — it
              // stays legible for anyone who cannot pick the colour change
              // out.
              width: i == current ? 18 : 6,
              decoration: BoxDecoration(
                color: i == current
                    ? AppPalette.candyBlue
                    : AppPalette.textSecondary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

/// One card. Once `meetup.windowEnd` has passed, converts in place to the
/// existing [RatingPrompt] rather than a second, purpose-built prompt UI
/// (ADR-025 §4).
class _PersistentMeetupCard extends StatelessWidget {
  const _PersistentMeetupCard({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    // Unchanged from before this round — any windowEnd-passed meetup
    // flips to RatingPrompt regardless of its server status (RatingPrompt
    // self-gates on real eligibility, so mounting it early/for an
    // ineligible meetup is harmless, same reasoning as always). What this
    // round fixes is the badge _ActiveMeetupRow shows for the same
    // meetup below — see _effectiveStatus's own doc comment.
    if (DateTime.now().isAfter(meetup.windowEnd!)) {
      return FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(16),
        child: RatingPrompt(meetupId: meetup.id),
      );
    }

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MeetupDetailPage(meetupId: meetup.id),
        ),
      ),
      // # WHY THIS CARD LOOKS DIFFERENT FROM EVERY OTHER ONE
      //
      // It is the one thing on Home that is happening RIGHT NOW, so it is
      // the page's single elevated surface — see FlatCard.elevated.
      //
      // It used to signal that with a full-bleed `candyBlue @ 10%` wash and
      // a heavy 45% border. On the light theme candyBlue is a dark slate,
      // so 10% of it over white is a flat grey-blue: the card read as
      // disabled rather than as urgent, and the strong border boxed it in.
      // The accent moved to a solid left bar and a filled NOW chip, leaving
      // the surface clean — the same move a card gets in any modern app when
      // it needs to lead without shouting.
      child: FlatCard(
        radius: 14,
        elevated: true,
        border: AppPalette.hairline,
        padding: EdgeInsets.zero,
        // IntrinsicHeight so the accent bar can stretch to the card's full
        // height: `CrossAxisAlignment.stretch` needs a bounded height, and
        // the single-card path renders inside an unbounded Column. Cheap
        // here — one small, shallow subtree — and the alternative (painting
        // the bar as a left border on FlatCard's own decoration) would push
        // a one-card concern into the shared surface.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The accent, as a bar rather than a tint over the whole card.
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: AppPalette.candyBlue,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(14),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              // Solid, not a wash — a live indicator that is
                              // itself washed out defeats the purpose.
                              color: AppPalette.candyBlue,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: AppPalette.card,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  'NOW',
                                  style: TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1.0,
                                    fontWeight: FontWeight.w800,
                                    // Reads against the solid chip, in both
                                    // themes: candyBlue is dark on light and
                                    // pale on dark, so the label takes the
                                    // card colour either way.
                                    color: AppPalette.card,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          MeetupStatusBadge(status: meetup.status),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        meetup.hostFullName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        meetup.formattedWindow,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.place_outlined,
                              size: 12,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              meetup.locationLabel!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppPalette.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact row for the full "Active Meetups" list — same visual language
/// (FlatCard, palette tokens) as every other card on this page, not a new
/// style.
class _ActiveMeetupRow extends StatelessWidget {
  const _ActiveMeetupRow({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MeetupDetailPage(meetupId: meetup.id),
        ),
      ),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(meetup.intent.icon, size: 18, color: AppPalette.candyBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meetup.hostFullName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    meetup.formattedWindow,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            // _effectiveStatus (round-9), not the raw server status
            // directly — see its own doc comment. Keeps this row's badge
            // in agreement with _PersistentMeetupCard's own windowEnd
            // check above for the same meetup, instead of the two
            // disagreeing for up to a minute at a time (ADR-025 §4's
            // lifecycle-poller lag).
            MeetupStatusBadge(status: _effectiveStatus(meetup)),
          ],
        ),
      ),
    );
  }
}
