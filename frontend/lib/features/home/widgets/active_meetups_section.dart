import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/meetup_role_chips.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
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
            const SectionHeading('Cancelled'),
            const SizedBox(height: 16),
            for (final m in cancelled) ...[
              _ReviewInvitationCard(meetup: m),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
          ],
          if (happeningNow.isNotEmpty) ...[
            const SectionHeading('Happening now'),
            const SizedBox(height: 16),
            _PersistentMeetupCardSet(meetups: happeningNow),
            const SizedBox(height: 24),
          ],
          if (waitingReview.isNotEmpty) ...[
            const SectionHeading('Waiting for your review'),
            const SizedBox(height: 16),
            _PersistentMeetupCardSet(meetups: waitingReview),
            const SizedBox(height: 24),
          ],
          // Only what is genuinely still active. A finished or cancelled
          // meetup has its card above; repeating it here as a greyed row
          // made the list read as a history it is not.
          if (live.isNotEmpty) ...[
            const SectionHeading('Active meetups'),
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
                // A PageView clips its pages to its own rectangle, which cut
                // the card's soft cast shadow into a hard-edged grey block
                // under the card. Letting it paint outside its bounds keeps
                // the shadow the same as every other card's.
                clipBehavior: Clip.none,
                onPageChanged: (index) => setState(() => _page = index),
                itemCount: widget.meetups.length,
                itemBuilder: (context, index) => Padding(
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

    return Pressable(
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
        radius: 22,
        elevated: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    // Solid, not a wash — a live indicator that is
                    // itself washed out defeats the purpose.
                    color: AppPalette.candyBlue,
                    borderRadius: BorderRadius.circular(999),
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
                        'Now',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.2,
                          fontWeight: FontWeight.w700,
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
                const Spacer(),
                // Same corner mark as the review and cancelled
                // cards, so every card in the deck says what kind
                // of meetup it is in the same place.
                _IntentMark(meetup: meetup, tone: AppPalette.candyBlue),
              ],
            ),
            const SizedBox(height: 4),
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
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: AppIcon(
                    AppIcons.pin,
                    size: 13,
                    color: AppPalette.textTertiary,
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

    return Pressable(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MeetupDetailPage(meetupId: meetup.id),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: FlatCard(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          // The 4px state bar down the left edge is gone. A coloured rule
          // that thick is the cheapest way to say "this row is special" and
          // it was saying it on every row at once, so it said nothing. The
          // state now lives where the eye already goes: the tinted intent
          // tile, the intent line, and the date block all take `edge`.
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppPalette.tintedSurface(edge.withValues(alpha: 0.14)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: AppIcon(meetup.intent.iconPath, size: 19, color: edge),
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
                          ? 'Cancelled \u00B7 ${meetup.intentLabel}'
                          : meetup.intentLabel,
                      style: TextStyle(
                        color: edge,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
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
                            child: AppIcon(
                              AppIcons.pin,
                              size: 13,
                              color: AppPalette.textTertiary,
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
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: AppPalette.raised,
        borderRadius: BorderRadius.circular(14),
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

class _ReviewInvitationCardState extends ConsumerState<_ReviewInvitationCard> {
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
    return Pressable(
      onTap: _openReview,
      child: FlatCard(
        radius: 22,
        elevated: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        // Same skeleton as the live card next to it in the carousel — chip
        // row, then the meetup's own details — because it IS the same
        // meetup, one state later. A card that dropped that structure would
        // read as an unrelated notification that happened to be in the deck.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Where the live card says NOW. Same shape, so the
                // two are comparable at a glance.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: tone,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    cancelled ? 'Cancelled' : 'Review',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.2,
                      fontWeight: FontWeight.w700,
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
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                AppIcon(AppIcons.pin, size: 13, color: AppPalette.textTertiary),
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
            const SizedBox(height: 12),
            Divider(height: 1, color: AppPalette.hairline),
            const SizedBox(height: 12),
            // The ask, now clearly ABOUT the meetup named above it
            // rather than instead of it.
            Row(
              children: [
                // It used to pulse. A forever-looping scale on a
                // card the user may never act on is a battery
                // cost and a distraction, and it is the kind of
                // scattered motion the rest of this redesign
                // removed. The chevron and the tone carry the
                // affordance on their own.
                AppIcon(
                  cancelled ? AppIcons.close : AppIcons.star,
                  size: 16,
                  color: tone,
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
                AppIcon(
                  AppIcons.forward,
                  color: AppPalette.textTertiary,
                  size: 16,
                ),
              ],
            ),
          ],
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
    // A 1px rule, not a quotation glyph. The glyph was decoration standing
    // in for an icon; the rule says "these are someone else's words" with
    // less ink and no borrowed symbol.
    // IntrinsicHeight because `stretch` needs a bounded height and this
    // sits in an unbounded Column; it is one shallow subtree of two
    // children, so the extra layout pass is cheap.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 1, color: AppPalette.cancelled),
          const SizedBox(width: 10),
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
      ),
    );
  }
}

/// The intent's glyph and name, as one compact mark for the top-right
/// corner of a card that is otherwise all text. Tinted with the card's own
/// state colour so it belongs to the card rather than shouting over it.
///
/// # IT USED TO BE A STACK, AND IT LEFT A HOLE
///
/// The tile sat above the name in a Column, which made this mark about 55
/// logical pixels tall while the state chip across from it was 24. The row
/// took the taller of the two, so every card in the deck had a band of
/// empty space between its chip and its title — visible on device, and
/// invisible to every test, because nothing about the widget tree was
/// wrong. Laid out as a row it is chip height, and the title sits where it
/// belongs: directly under the chip.
class _IntentMark extends StatelessWidget {
  const _IntentMark({required this.meetup, required this.tone});

  final Meetup meetup;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
      decoration: BoxDecoration(
        color: AppPalette.tintedSurface(tone.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(meetup.intent.iconPath, size: 14, color: tone),
          const SizedBox(width: 6),
          Text(
            meetup.intentLabel,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
