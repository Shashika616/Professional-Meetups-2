part of 'meetup_detail_page.dart';

/// Shown while [MeetupService.getMeetup] resolves — mirrors the summary
/// card + action button shape `_buildContent` renders once data actually
/// arrives, instead of a bare spinner.
class _MeetupDetailSkeleton extends StatelessWidget {
  const _MeetupDetailSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(width: 70, height: 11, opacity: 0.08),
              const SizedBox(height: 10),
              const SkeletonBox(width: 140, height: 20, opacity: 0.08),
              const SizedBox(height: 8),
              const SkeletonBox(width: 180, height: 13),
              const SizedBox(height: 14),
              const SkeletonBox(width: 160, height: 12),
              const SizedBox(height: 4),
              const SkeletonBox(width: 100, height: 12),
            ],
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) =>
              SkeletonBox(width: constraints.maxWidth, height: 48, radius: 14),
        ),
      ],
    );
  }
}

/// Where the viewer's request stands. A STATE, not a control: it is
/// left-aligned with an icon and a sentence, carries no press affordance,
/// and is coloured by outcome (amber while waiting, green when in, blue
/// when not this time, grey when withdrawn), so it cannot be mistaken for the
/// LOCATION button above it or the cancel/withdraw button below it.
class _RequestStatusBanner extends StatelessWidget {
  const _RequestStatusBanner({required this.status});

  final MeetupRequestStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, detail, icon, color) = switch (status) {
      MeetupRequestStatus.pending => (
        'Request pending',
        'Waiting for the host to respond. We will notify you.',
        AppIcons.hourglass,
        AppPalette.gold,
      ),
      MeetupRequestStatus.accepted => (
        'You\'re in',
        'The host accepted your request. See you there.',
        AppIcons.checkCircle,
        AppPalette.verified,
      ),
      // Not red and not "declined": hosts keep groups small, so a no is
      // about fit, and the section under this banner points at what is
      // next.
      MeetupRequestStatus.rejected => (
        'Not this time',
        'Hosts keep their groups small, so not every request can fit. '
            'There are more meetups near you.',
        AppIcons.explore,
        AppPalette.candyBlue,
      ),
      MeetupRequestStatus.withdrawn => (
        'Withdrawn',
        'You left this meetup.',
        AppIcons.undo,
        AppPalette.textSecondary,
      ),
    };
    return Semantics(
      // Read as a status line, never announced as a button.
      liveRegion: true,
      label: '$label. $detail',
      child: FlatCard(
        radius: 18,
        padding: EdgeInsets.zero,
        tint: color.withValues(alpha: 0.08),
        border: color.withValues(alpha: 0.30),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The stripe went with the rest of them. This banner is
                // already tinted AND bordered in the state colour and
                // leads with a state icon in it; a fourth copy of the
                // same signal down the edge added nothing.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 0, 12),
                  child: AppIcon(icon, size: 22, color: color),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          detail,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
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

/// The Safety Gate sub-flow: the checklist, then telling a trusted contact.
///
/// It used to run checklist -> live-location -> check-in -> post-meetup
/// feedback. The last two are gone: they asked the user to confirm things the
/// app cannot verify, and between them the page asked about one meeting three
/// times. What remains is the half that does something FOR the user rather
/// than asking something OF them.
///
/// Backing out is not lost with them: WITHDRAW REQUEST above handles it, and
/// handles it properly, since a withdrawal actually leaves the meetup and
/// tells the host. DECLINE only ever wrote a safety flag.
class _SafetyGateSection extends StatelessWidget {
  const _SafetyGateSection({
    required this.safetyState,
    required this.onAcknowledgeChecklist,
    required this.onShareWithContacts,
  });

  final SafetyState? safetyState;

  final VoidCallback onAcknowledgeChecklist;
  final VoidCallback onShareWithContacts;

  @override
  Widget build(BuildContext context) {
    final acknowledged = safetyState?.checklistAcknowledged ?? false;
    final sharedCount = safetyState?.sharedWithContactIds.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Safety gate',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 12),
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before you go',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              const _ChecklistItem('Meet in a public place'),
              const _ChecklistItem(
                'Tell a trusted contact where you\'re going',
              ),
              const _ChecklistItem('Keep first meetings short'),
              const _ChecklistItem('Never share OTP codes or send money'),
              const SizedBox(height: 12),
              if (!acknowledged)
                PrimaryButton(
                  label: 'I understand',
                  height: 44,
                  onPressed: onAcknowledgeChecklist,
                )
              else
                const _DoneRow('Checklist acknowledged'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // WAS a "Share live location" switch bound to a boolean nothing
        // read — the app said it was sharing the user's location and shared
        // it with nobody. Now a real action, and the copy says exactly what
        // the recipient gets rather than implying tracking.
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tell a trusted contact',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Send someone you trust the time and place of this meetup.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              // Confirmation of what was actually done. The whole reason the
              // share is persisted server-side is so this can be shown on a
              // later visit.
              if (sharedCount > 0) ...[
                _DoneRow(
                  sharedCount == 1
                      ? 'Told 1 trusted contact'
                      : 'Told $sharedCount trusted contacts',
                ),
                const SizedBox(height: 10),
              ],
              // Accent on the label and the border so it reads as the
              // action it is, not as a caption under the card's copy.
              SecondaryButton(
                label: sharedCount > 0 ? 'Tell someone else' : 'Tell someone',
                icon: AppIcons.share,
                height: 44,
                color: AppPalette.candyBlue,
                borderColor: AppPalette.candyBlue.withValues(alpha: 0.6),
                onPressed: onShareWithContacts,
              ),
            ],
          ),
        ),
        // The CHECK IN card and the "How did it go?" prompt used to sit here.
        //
        // Both removed on request. Check-in asked the user to confirm they had
        // arrived somewhere the app cannot verify, and the happened/didn't
        // happen prompt asked the same question a second time from the other
        // end. Neither gated anything a user could not do anyway, and together
        // they made the page ask three times about one meeting.
        //
        // What is NOT removed: the checklist above and the trusted-contact
        // card. Those do something for the user rather than asking something
        // of them.
      ],
    );
  }
}

/// A square-ish tappable tile: icon above a short label.
///
/// Deliberately not [SecondaryButton]. That widget is a wide, quiet bar built
/// for one full-width action at the bottom of a form; used twice in a row for
/// two peer actions it reads as a list of disabled rows. This has a filled
/// surface, a real border and an icon, so it looks like something you press.
/// The cancellation, on the meetup's own page: the state and the host's
/// words. Same soft red as the card edge; the reason quoted because it is
/// the host's, not the app's.
/// The meetup's photo and its headline, as a cover card: the picture on
/// top, the intent tag, the time and the place on the card surface under
/// it.
///
/// # THE TEXT CAME OUT FROM ON TOP OF THE PICTURE
///
/// The screen set lays the title over the photo with a scrim. That works
/// against the art it was drawn with; against these assets it does not.
/// They are bright, busy illustrations with faces and whiteboards in the
/// lower third, and no scrim that still lets the picture read is dark
/// enough to carry 17px white text over all of them. Deepening the scrim
/// until the text was safe turned the photo into a grey band, which is
/// the thing the hero existed to stop being.
///
/// So the text sits under the picture instead. It is always legible, in
/// both themes, whatever the image happens to contain — and the tag can
/// use the accent colours the rest of the app's tags use, rather than the
/// white-on-dark exception a photo overlay forced.
class _DetailHero extends StatelessWidget {
  const _DetailHero({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    final locked = meetup.lockedForViewer;
    final width = MediaQuery.sizeOf(context).width;

    return FlatCard(
      radius: 22,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // 124, not the screen set's 112. That number was drawn for a
            // band with the title ON it, where the photo is backing
            // texture. Here the label sits under the picture, so the
            // picture needs enough height to still lead.
            height: 124,
            width: double.infinity,
            child: Image.asset(
              meetup.intent.imageAsset,
              fit: BoxFit.cover,
              // Decoded at the band's real width, not the source's.
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .round(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTag(
                  meetup.intentLabel,
                  icon: meetup.intent.iconPath,
                  compact: true,
                ),
                const SizedBox(height: 10),
                Text(
                  locked ? 'Location hidden' : meetup.formattedWindow,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!locked && meetup.locationLabel != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: AppIcon(
                          AppIcons.pin,
                          size: 14,
                          color: AppPalette.textTertiary,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          meetup.locationLabel!,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CancelledBanner extends StatelessWidget {
  const _CancelledBanner({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final tone = AppPalette.cancelled;
    final text = reason.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIcons.calendarX, size: 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Cancelled by the host',
                  style: TextStyle(
                    color: tone,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.isEmpty ? 'No reason was given.' : '\u201C$text\u201D',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13.5,
              fontStyle: text.isEmpty ? FontStyle.normal : FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// A full-width row button: icon in an accent disc, small-caps label with
/// a one-line detail, and a chevron. The chevron and the accent border are
/// what say "this goes somewhere"; the earlier centred icon-over-label tile
/// read as a badge rather than a control.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final String icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.candyBlue;
    return Material(
      color: AppPalette.card,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // A visible press state. The old bordered bars gave none, which is
        // half of why they did not read as buttons.
        splashColor: accent.withValues(alpha: 0.12),
        highlightColor: accent.withValues(alpha: 0.06),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(icon, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppIcon(AppIcons.forward, size: 22, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          AppIcon(
            AppIcons.checkCircle,
            size: 14,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
