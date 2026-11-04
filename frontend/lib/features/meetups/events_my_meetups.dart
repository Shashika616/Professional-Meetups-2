part of 'events_page.dart';

/// The Open/History control.
///
/// # WHY THIS IS NOT A SECOND TabBar
///
/// It was one, briefly. Two underlined tab bars stacked directly on top of
/// each other — the page's own My Meetings/Requested Meetings bar and this
/// one — read as one confusing four-item control rather than two levels,
/// because they were drawn identically and the only cue separating them was
/// a hairline. A segmented pill is visually subordinate to the tab bar above
/// it, which is what the hierarchy actually is.
///
/// What it deliberately KEEPS from the TabBar it replaces, and what the pair
/// of plain GestureDetectors that came before that never had:
///
///   * it drives a real [TabController], so the [TabBarView] beside it still
///     swipes between the two lists, animates, and stays in sync whichever
///     way the user drives it;
///   * it rebuilds from the controller rather than from local state, so a
///     swipe moves the selection here too;
///   * each half is a [Semantics] tab with a selected state, so the
///     accessibility layer still sees a two-tab control.
class _SubTabSelector extends StatefulWidget {
  const _SubTabSelector({required this.controller});

  final TabController controller;

  @override
  State<_SubTabSelector> createState() => _SubTabSelectorState();
}

class _SubTabSelectorState extends State<_SubTabSelector> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  // Fires on a tap AND partway through a swipe, which is the point: the
  // selection must follow the TabBarView rather than only leading it.
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.controller.index;

    // A TRACK holding two segments, not two free standing buttons.
    //
    // The previous version drew each half as its own bordered pill, selected
    // or not, and the only difference between the two states was a faint tint
    // and a slightly stronger border. On a dark page that read as two buttons
    // where neither looked pressed. Enclosing them in one recessed track and
    // FILLING the active half is the standard segmented control, and it is
    // unambiguous at a glance.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppPalette.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppPalette.hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: _SubTabButton(
                icon: AppIcons.calendarCheck,
                label: 'Open meetups',
                selected: index == 0,
                onTap: () => widget.controller.animateTo(0),
              ),
            ),
            Expanded(
              child: _SubTabButton(
                icon: AppIcons.history,
                label: 'History',
                selected: index == 1,
                onTap: () => widget.controller.animateTo(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of the segmented control.
///
/// Selected means FILLED, in the same colour and with the same foreground as
/// the app's primary buttons, so "this one is active" uses a signal the user
/// has already learned elsewhere in the app. Unselected is drawn as nothing at
/// all: it sits on the track and takes its contrast from the filled half
/// beside it.
class _SubTabButton extends StatelessWidget {
  const _SubTabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Matches PrimaryButton exactly: candyBlue fill, onyx on top of it. onyx
    // is near black in dark mode and near white in light, so this stays
    // legible in both without a second rule.
    final foreground = selected ? AppPalette.onyx : AppPalette.textSecondary;

    return Semantics(
      // Still a tab to the accessibility layer, exactly as the TabBar was.
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        // Without this the gaps inside the pill (and the pill itself when
        // unselected, which paints an almost-transparent fill) would not
        // register a tap at all.
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // No border on either state: the track around both halves already
            // draws the outline, and a second one inside it made the control
            // look like two boxes in a box.
            color: selected ? AppPalette.candyBlue : Colors.transparent,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(icon, size: 15, color: foreground),
              const SizedBox(width: 7),
              // Flexible, not a bare Text: "Open meetups" is the longer of
              // the two and the pills are equal width, so on a narrow
              // device it must ellipsize rather than overflow.
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    letterSpacing: 0.2,
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

/// One row on the Events list.
///
/// Was the itemBuilder body of `_MeetupListView`, which also owned the
/// ListView, the load-more spinner and the ScrollController. Those three are
/// [PaginatedMeetupList]'s job now, so what is left here is exactly the card
/// — which is all this widget was ever really about.
///
/// Distinct from `MeetupCard` (the browse card) on purpose: this one shows a
/// meetup the viewer already belongs to, so it needs no join button, no
/// locked/redacted variant (listMyMeetups never redacts) and no host
/// identity block — the host is either the viewer or someone they have
/// already been accepted by.
class _MyMeetupTile extends StatelessWidget {
  const _MyMeetupTile({
    required this.meetup,
    required this.onTap,
    this.onViewRequests,
  });

  final Meetup meetup;
  final VoidCallback onTap;

  /// Present only for a live meetup the viewer hosts: renders the VIEW
  /// REQUESTS action under the card body.
  final VoidCallback? onViewRequests;

  /// Green while the meetup is live, gold once it is over and owed a review,
  /// muted once there is nothing left to do with it. Same three states and the
  /// same two colours as the ACTIVE MEETUPS rows on Home, so a meetup does not
  /// change language between the two screens that show it.
  Color _edgeColor() {
    final end = meetup.windowEnd;
    final over = end != null && DateTime.now().isAfter(end);
    return switch (meetup.status) {
      MeetupStatus.cancelled => AppPalette.cancelled,
      _ when over => AppPalette.gold,
      _ => AppPalette.verified,
    };
  }

  /// The outcome chip on a History card: what became of this meetup, from
  /// the viewer's side. COMPLETED for one that ran its course; CANCELLED
  /// when the host called it off; WITHDRAWN when the viewer pulled their
  /// own request. Null on a live meetup — there is no outcome yet.
  ({String label, Color color})? _outcome() {
    if (!_isFinished(meetup)) return null;
    if (meetup.status == MeetupStatus.cancelled) {
      return (label: 'Cancelled', color: AppPalette.cancelled);
    }
    if (!meetup.isHostedByMe &&
        meetup.myRequestStatus == MeetupRequestStatus.withdrawn) {
      return (label: 'Withdrawn', color: AppPalette.textSecondary);
    }
    return (label: 'Completed', color: AppPalette.verified);
  }

  @override
  Widget build(BuildContext context) {
    final edge = _edgeColor();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Pressable(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: FlatCard(
            radius: 20,
            // The 4px state bar down the left edge is gone, the same move
            // the Home cards got. `edge` still colours the intent tile and
            // the status text, which is where the eye already goes; a
            // coloured rule on every card in the list said nothing because
            // every card had one.
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ONE line for identity, not three.
                //
                // This row used to carry the intent, a status chip,
                // a trust chip and a star rating, with a second row
                // of verification badges under it — five competing
                // pieces of chrome above the thing the card is
                // actually about. The status chip is now the edge,
                // and what is left is the intent and who is hosting.
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppPalette.tintedSurface(
                          edge.withValues(alpha: 0.14),
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: AppIcon(
                        meetup.intent.iconPath,
                        size: 18,
                        color: edge,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        meetup.intentLabel,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    // The star rating used to sit here too. On a
                    // 375pt screen the icon tile plus the intent
                    // label plus a trust badge plus a rating
                    // overflowed the row by 15pt, and cramming four
                    // things onto one line was the problem this
                    // redesign set out to fix anyway. The rating
                    // moved to the footer, beside the other
                    // host-credibility signals it belongs with.
                    TrustLevelBadge(trustLevel: meetup.hostTrustLevel),
                  ],
                ),
                const SizedBox(height: 12),
                // The when, as the headline. It is the single most
                // useful thing on a card about a meeting you already
                // belong to, and it used to sit below two rows of
                // badges at the same weight as everything else.
                Text(
                  meetup.formattedWindow,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      AppIcons.pin,
                      size: 13,
                      color: AppPalette.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    // locationLabel is only ever null for a locked
                    // ListOpenMeetups result (ADR-028) — this page
                    // loads via listMyMeetups, which never redacts,
                    // so `!` is safe.
                    Expanded(
                      child: Text(
                        meetup.locationLabel!,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Its own line: VerificationBadges is a Wrap, so
                // given the full width it reflows instead of
                // fighting whatever shares the row with it.
                VerificationBadges(trustLevel: meetup.hostTrustLevel),
                const SizedBox(height: 12),
                Divider(height: 1, color: AppPalette.hairline),
                const SizedBox(height: 10),
                Row(
                  children: [
                    StarRating(
                      average: meetup.hostRatingAverage,
                      count: meetup.hostRatingCount,
                    ),
                    const Spacer(),
                    Flexible(child: _statusRow(meetup)),
                  ],
                ),
                if (onViewRequests != null) ...[
                  const SizedBox(height: 12),
                  _ViewRequestsButton(onPressed: onViewRequests!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusRow(Meetup meetup) {
    // On a finished meetup the viewer's request state is history, not
    // status — "YOU'RE IN" on something that already happened says nothing
    // — so the row is left to the rating. Hosts keep their confirmed count.
    final outcome = _outcome();
    if (outcome != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: outcome.color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: outcome.color.withValues(alpha: 0.35)),
        ),
        child: Text(
          outcome.label,
          style: TextStyle(
            color: outcome.color,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
      );
    }
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
      MeetupRequestStatus.pending => ('Request pending', AppPalette.gold),
      MeetupRequestStatus.accepted => ('You\'re in', AppPalette.verified),
      // The requester's own list never says rejected or declined; both
      // outcomes read as timing, in the same muted tone.
      MeetupRequestStatus.rejected =>
        meetup.myRequestAutoRejected
            ? ('Filled up before your turn', AppPalette.textSecondary)
            : ('Not this time', AppPalette.textSecondary),
      MeetupRequestStatus.withdrawn => ('Withdrawn', AppPalette.textSecondary),
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
