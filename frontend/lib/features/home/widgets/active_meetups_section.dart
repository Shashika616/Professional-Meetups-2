import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/ambient_animation.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/meetup_role_chips.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/review/meetup_review_page.dart';

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
    // THREE STATES, THREE DECKS. Everything the server puts on the active
    // list is one of: still going ahead (live), finished and owed a review
    // (waiting), or called off and owed a review (cancelled). Each gets its
    // own heading so a finished meetup never sits under "Happening Now" and
    // reads as still on. `_effectiveStatus` is what sorts a live meetup into
    // "waiting" the moment its window passes, ahead of the server's poller.
    final cancelled = <Meetup>[];
    final waitingReview = <Meetup>[];
    final live = <Meetup>[];
    for (final m in active) {
      switch (_effectiveStatus(m)) {
        case MeetupStatus.cancelled:
          cancelled.add(m);
        case MeetupStatus.completed:
          waitingReview.add(m);
        case MeetupStatus.open:
        case MeetupStatus.full:
          live.add(m);
      }
    }
    // windowStart/windowEnd/hostFullName/locationLabel are only ever null
    // for a locked ListOpenMeetups result (ADR-028) — listActiveMeetups()
    // never redacts, so `!` here documents that guarantee.
    final happeningNow = live
        .where((m) => !now.isBefore(m.windowStart!.subtract(_cardLeadTime)))
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cancelled.isNotEmpty) ...[
            const SectionLabel('CANCELLED'),
            const SizedBox(height: 16),
            for (final m in cancelled) ...[
              _ReviewInvitationCard(meetup: m),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
          ],
          if (happeningNow.isNotEmpty) ...[
            const SectionLabel('HAPPENING NOW'),
            const SizedBox(height: 16),
            _PersistentMeetupCardSet(meetups: happeningNow),
            const SizedBox(height: 24),
          ],
          if (waitingReview.isNotEmpty) ...[
            const SectionLabel('WAITING FOR YOUR REVIEW'),
            const SizedBox(height: 16),
            _PersistentMeetupCardSet(meetups: waitingReview),
            const SizedBox(height: 24),
          ],
          // Only what is genuinely still active. A finished or cancelled
          // meetup has its card above; repeating it here as a greyed row
          // made the list read as a history it is not.
          if (live.isNotEmpty) ...[
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
            ...live.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ActiveMeetupRow(meetup: m),
              ),
            ),
          ],
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
/// The height is no longer a constant at all — see the Stack in build().
/// (History: it was 232, then a fixed 176 — the first left a large dead
/// area under the location line, the second overflowed the moment a long
/// address wrapped onto a second line.)
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
        // A PageView needs a definite height, and the cards' height now
        // depends on content (an address wraps rather than truncates). So
        // the box is sized by the cards themselves: every card is laid out
        // once, invisibly, in a Stack, and the PageView fills that. No
        // constant to fall out of date with the card, no overflow when a
        // venue has a long name. maintainSize keeps the invisible copies in
        // layout without painting them.
        Stack(
          children: [
            for (final meetup in widget.meetups)
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
                  child: _PersistentMeetupCard(meetup: meetup),
                ),
              ),
            Positioned.fill(
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
          ],
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

/// One card. Once `meetup.windowEnd` has passed, it becomes an invitation to
/// review the meetup instead of a countdown to it.
///
/// # WHAT THIS REPLACED
///
/// It used to swap itself for a bare [RatingPrompt] the instant the window
/// passed. Two things were wrong with that. The prompt appeared and then
/// vanished on the very next refresh, because the server's active-meetups
/// filter dropped anything already over — so the card people were supposed
/// to act on had a lifetime of one poll. And a naked star picker with no
/// context is not an invitation; it does not say which meetup it is about or
/// what pressing it commits you to.
///
/// Now the card keeps the meetup's own identity and adds one clear ask, and
/// the server keeps it in the list until it is reviewed (or the review
/// window lapses).
class _PersistentMeetupCard extends StatelessWidget {
  const _PersistentMeetupCard({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    // A meetup whose window has passed is sorted into the review deck by
    // the section's own partition, so this card is only ever live. It
    // still defers to the review card if it is somehow asked to draw one
    // (a tick between the partition and the paint).
    if (_effectiveStatus(meetup) == MeetupStatus.completed) {
      return _ReviewInvitationCard(meetup: meetup);
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
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Who is running it and where the viewer stands: the
                      // title above is the host's name, so the chip only
                      // says HOST, plus YOU'RE HOSTING / YOU'RE IN.
                      MeetupRoleChips(meetup: meetup, showHostName: false),
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
/// One row in ACTIVE MEETUPS.
///
/// # THE STATUS IS AN EDGE, NOT A CHIP
///
/// This used to end in an OPEN / COMPLETED pill. It read as a label rather
/// than as state, it competed with the row's own content for the eye, and
/// "COMPLETED" in muted grey was the least useful thing on a row whose whole
/// point was that it needed reviewing.
///
/// The state is now the bar down the left edge: [AppPalette.verified] while
/// the meetup is live, [AppPalette.gold] once it is over and owed a review.
/// Gold is deliberately the same gold as the review invitation card above it,
/// so the two read as one thread rather than two unrelated highlights.
///
/// # LAYOUT
///
/// Leading intent icon, title and supporting line, then the time as a block on
/// the right. The time used to sit under the title as a second grey line,
/// where it was easy to miss; giving it its own column makes "when" scannable
/// down a list without reading any of the rows.
class _ActiveMeetupRow extends StatelessWidget {
  const _ActiveMeetupRow({required this.meetup});

  final Meetup meetup;

  static const List<String> _weekdays = <String>[
    'MON',
    'TUE',
    'WED',
    'THU',
    'FRI',
    'SAT',
    'SUN',
  ];

  @override
  Widget build(BuildContext context) {
    // Only live meetups reach this row now; the section's partition sends
    // finished and cancelled ones to their own decks. The edge colour still
    // follows _effectiveStatus so a row is never painted live after its
    // window has passed, in the tick before the partition catches up.
    final status = _effectiveStatus(meetup);
    final awaitingReview = status == MeetupStatus.completed;
    final cancelled = status == MeetupStatus.cancelled;
    final edge = cancelled
        ? AppPalette.cancelled
        : awaitingReview
        ? AppPalette.gold
        : AppPalette.verified;
    final start = meetup.windowStart;

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MeetupDetailPage(meetupId: meetup.id),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlatCard(
          radius: 12,
          padding: EdgeInsets.zero,
          child: IntrinsicHeight(
            child: Row(
              children: [
                // The state bar. IntrinsicHeight above is what lets it run the
                // full height of the row whatever the text wraps to, rather
                // than being a fixed guess that leaves a gap on tall rows.
                Container(width: 4, color: edge),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: edge.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            meetup.intent.icon,
                            size: 18,
                            color: edge,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                meetup.hostFullName!,
                                style: TextStyle(
                                  color: AppPalette.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Intent as its own highlighted line, in the
                              // row's state colour so it reads with the edge
                              // bar and the date block; the address on the
                              // line below with a pin, never run into it.
                              Text(
                                cancelled
                                    ? 'CANCELLED \u00B7 ${meetup.intentLabel}'
                                    : meetup.intentLabel,
                                style: TextStyle(
                                  color: edge,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.3,
                                ),
                              ),
                              const SizedBox(height: 5),
                              MeetupRoleChips(
                                meetup: meetup,
                                compact: true,
                                showHostName: false,
                                concluded: awaitingReview || cancelled,
                              ),
                              if (meetup.locationLabel != null) ...[
                                const SizedBox(height: 4),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 1),
                                      child: Icon(
                                        Icons.place_outlined,
                                        size: 13,
                                        color: AppPalette.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        meetup.locationLabel!,
                                        style: TextStyle(
                                          color: AppPalette.textSecondary,
                                          fontSize: 11.5,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (start != null) ...[
                          const SizedBox(width: 10),
                          _TimeBlock(start: start, tint: edge),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The right hand "when" block: day, weekday, time, stacked.
class _TimeBlock extends StatelessWidget {
  const _TimeBlock({required this.start, required this.tint});

  final DateTime start;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final hour = start.hour % 12 == 0 ? 12 : start.hour % 12;
    final minute = start.minute.toString().padLeft(2, '0');
    final suffix = start.hour < 12 ? 'AM' : 'PM';

    return Container(
      width: 58,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${start.day}',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            _ActiveMeetupRow._weekdays[start.weekday - 1],
            style: TextStyle(
              color: tint,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '$hour:$minute $suffix',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

/// The finished-meetup card: the meetup, and one thing to do about it.
///
/// Deliberately warmer than the live card — a soft gold wash and a pulsing
/// icon — because this is the one card on Home that is asking for something
/// rather than reporting something. It is also a task the user can ignore,
/// so it has to earn the tap rather than assume it.
class _ReviewInvitationCard extends ConsumerStatefulWidget {
  const _ReviewInvitationCard({required this.meetup});

  final Meetup meetup;

  @override
  ConsumerState<_ReviewInvitationCard> createState() =>
      _ReviewInvitationCardState();
}

class _ReviewInvitationCardState extends ConsumerState<_ReviewInvitationCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Started here rather than in initState because whether it should run at
    // all depends on MediaQuery. Someone who asked the system for less
    // motion gets a still icon, not a slower one — and the suite freezes it
    // outright, since a forever-repeating controller never lets
    // pumpAndSettle finish (see debugDisableAmbientAnimations).
    final wanted =
        !debugDisableAmbientAnimations &&
        !MediaQuery.of(context).disableAnimations;
    if (wanted && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!wanted && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _openReview() async {
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MeetupReviewPage(
          meetupId: widget.meetup.id,
          hostUserId: widget.meetup.hostUserId,
          cancellationReason: widget.meetup.status == MeetupStatus.cancelled
              ? (widget.meetup.cancellationReason ?? '')
              : null,
        ),
      ),
    );
    // The review page invalidates the lists itself on success; this only
    // covers the case where it was dismissed without submitting, so the
    // card stays exactly as it was.
    if (submitted == true && mounted) {
      ref.invalidate(activeMeetupsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meetup = widget.meetup;
    // The same card serves a finished meetup and a cancelled one: same
    // skeleton, same ask, a different colour and a different first word —
    // plus, for a cancellation, the host's reason, since that is what the
    // participant is being asked to weigh.
    final cancelled = meetup.status == MeetupStatus.cancelled;
    final tone = cancelled ? AppPalette.cancelled : AppPalette.gold;
    return GestureDetector(
      onTap: _openReview,
      child: FlatCard(
        radius: 14,
        elevated: true,
        border: AppPalette.hairline,
        tint: tone.withValues(alpha: 0.05),
        padding: EdgeInsets.zero,
        // Same skeleton as the live card next to it in the carousel — accent
        // bar, chip row, then the meetup's own details — because it IS the
        // same meetup, one state later. A card that dropped that structure
        // would read as an unrelated notification that happened to be in the
        // deck.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(14),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Where the live card says NOW. Same shape, so the
                          // two are comparable at a glance.
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: tone,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              cancelled ? 'CANCELLED' : 'REVIEW',
                              style: TextStyle(
                                fontSize: 9,
                                letterSpacing: 1.0,
                                fontWeight: FontWeight.w800,
                                color: AppPalette.card,
                              ),
                            ),
                          ),
                          const Spacer(),
                          // What kind of meetup it was, as the glyph the
                          // rest of the app uses for the intent, with the
                          // name in small type under it: a card in a deck
                          // is scanned, not read.
                          _IntentMark(meetup: meetup, tone: tone),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // WHICH meetup. Without these three lines the card
                      // asked someone to rate an unnamed event: a user with
                      // two finished meetups in the deck had no way to tell
                      // the cards apart, and no way to know what they were
                      // about to review.
                      Text(
                        meetup.hostFullName!,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Past tense on purpose: this card only ever shows a
                      // meetup that is over or was called off.
                      MeetupRoleChips(
                        meetup: meetup,
                        showHostName: false,
                        concluded: true,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        meetup.formattedWindow,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.place_outlined,
                            size: 12,
                            color: AppPalette.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              meetup.locationLabel!,
                              style: TextStyle(
                                color: AppPalette.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (cancelled) ...[
                        const SizedBox(height: 10),
                        _HostReason(reason: meetup.cancellationReason ?? ''),
                      ],
                      const Spacer(),
                      Divider(height: 1, color: AppPalette.hairline),
                      const SizedBox(height: 10),
                      // The ask, now clearly ABOUT the meetup named above it
                      // rather than instead of it.
                      Row(
                        children: [
                          // The one moving thing on the card. A scale and an
                          // opacity on a 22px icon — nothing under it
                          // repaints, and it stops the moment the card is
                          // disposed.
                          FadeTransition(
                            opacity: Tween<double>(begin: 0.55, end: 1.0)
                                .animate(
                                  CurvedAnimation(
                                    parent: _pulse,
                                    curve: Curves.easeInOut,
                                  ),
                                ),
                            child: ScaleTransition(
                              scale: Tween<double>(begin: 0.9, end: 1.1)
                                  .animate(
                                    CurvedAnimation(
                                      parent: _pulse,
                                      curve: Curves.easeInOut,
                                    ),
                                  ),
                              child: Icon(
                                cancelled
                                    ? Icons.event_busy_rounded
                                    : Icons.auto_awesome_rounded,
                                size: 16,
                                color: tone,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              cancelled
                                  ? 'Share your thoughts on this cancellation'
                                  : 'Share your thoughts about this meetup',
                              style: TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: AppPalette.textSecondary,
                            size: 20,
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

/// The host's cancellation reason on the CANCELLED card — their words, as
/// a quotation, or an honest "no reason given".
class _HostReason extends StatelessWidget {
  const _HostReason({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final text = reason.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.format_quote_rounded, size: 14, color: AppPalette.cancelled),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text.isEmpty ? 'The host gave no reason.' : '\u201C$text\u201D',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 12.5,
              fontStyle: text.isEmpty ? FontStyle.normal : FontStyle.italic,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// The intent's glyph in a tinted square with the intent's name in small
/// type beneath, for the top-right corner of a card that is otherwise all
/// text. Tinted with the card's own state colour so it belongs to the card
/// rather than shouting over it.
class _IntentMark extends StatelessWidget {
  const _IntentMark({required this.meetup, required this.tone});

  final Meetup meetup;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tone.withValues(alpha: 0.35)),
          ),
          child: Icon(meetup.intent.icon, size: 18, color: tone),
        ),
        const SizedBox(height: 4),
        Text(
          meetup.intentLabel,
          textAlign: TextAlign.right,
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
          ),
        ),
      ],
    );
  }
}
