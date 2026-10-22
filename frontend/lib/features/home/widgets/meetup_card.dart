import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// One open-meetup card, plus the pieces it is built from.
///
/// EXTRACTED VERBATIM from the deleted `matches_page.dart`, where these were
/// private to that file. Nothing about the rendering changed in the move —
/// deliberately, because [LockedCardHeader]'s behaviour is a security
/// property (ADR-002 § 6: what a guest may see), not styling, and a "while
/// I'm here" tidy-up of a redaction path is how such a property quietly
/// stops holding. The only edits are the ones the move itself forced:
/// private names that are now public, and a `super.key`.
///
/// Used by Home's "Happening Soon" list. It was previously used only by the
/// browse page, which no longer exists as a separate destination.

class MeetupCard extends StatelessWidget {
  const MeetupCard({super.key, required this.meetup, required this.onTap});

  final Meetup meetup;
  final VoidCallback onTap;

  /// ADR-028 § 2 — a locked meetup's card tap redirects here instead of
  /// reaching [onTap]: a toast
  /// (same wording pattern as the locked-intent toast Home shows for a
  /// locked chip on `IntentFilterBar`), then the focused checklist. The tap
  /// never reaches RequestToJoin while locked, same as the disabled-button
  /// pattern this replaces — only the destination changes, from a dead end
  /// to somewhere that actually helps.
  void _handleLockedTap(BuildContext context) {
    showSnack(context, meetup.intent.joinLockedMessage, type: ToastType.locked);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fullness and the viewer's join eligibility used to be computed here
    // to decide the card's button. The card has no button now, and the
    // meetup page works both out for itself from the same Meetup.
    final locked = meetup.lockedForViewer;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Pressable(
        onTap: locked ? () => _handleLockedTap(context) : onTap,
        child: FlatCard(
          radius: 22,
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Thumb(intent: meetup.intent),
                  const SizedBox(width: 11),
                  Expanded(child: _body(context, locked: locked)),
                ],
              ),
              // NO ACTIONS ON THE CARD
              //
              // This used to carry a full-width green "I'm interested"
              // button and a "View location" link. Both work, and on one
              // card they look helpful. Home shows a LIST of these, and a
              // column of identical green buttons down the page is the
              // loudest thing on the screen while saying nothing about
              // which meetup is which — the brand's one action colour,
              // repeated until it stops reading as an action. They also
              // roughly doubled each card's height, so a screen that could
              // show four meetups showed two.
              //
              // Nothing is lost: tapping the card opens the meetup, where
              // both actions live with the room to explain themselves. The
              // card's job is to let someone scan the list and pick one.
            ],
          ),
        ),
      ),
    );
  }

  /// The right-hand column of the list row: tags, when, where, who.
  ///
  /// # THE ORDER IS THE SCAN ORDER
  ///
  /// Kind, then WHEN, then WHERE, then who. The time leads because it is
  /// the fact that decides whether you can come at all; the place decides
  /// whether you want to; the host decides whether you trust it. The card
  /// used to open with a 48px avatar and the host's name, which put the
  /// least decisive fact in the most prominent slot.
  Widget _body(BuildContext context, {required bool locked}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppTag(meetup.intentLabel, compact: true),
            // Fullness used to be the join button's label ("Full" instead
            // of "I'm interested"). The button is gone, so without this a
            // full meetup looked exactly like a joinable one and the only
            // way to find out was to open it. Server-marked full and
            // count-full can disagree, and the server decides, so either
            // is enough.
            if (!locked &&
                (meetup.status == MeetupStatus.full ||
                    meetup.acceptedCount >= meetup.capacity))
              const AppTag(
                'Full',
                tone: AppTone.neutral,
                icon: AppIcons.lock,
                compact: true,
              ),
            if (!locked && meetup.isHostedByMe)
              const AppTag(
                "You're hosting",
                tone: AppTone.success,
                icon: AppIcons.star,
                compact: true,
              )
            else if (!locked && meetup.myRequestStatus != null)
              AppTag(
                switch (meetup.myRequestStatus!) {
                  MeetupRequestStatus.pending => 'Request pending',
                  MeetupRequestStatus.accepted => "You're in",
                  MeetupRequestStatus.rejected => 'Not this time',
                  MeetupRequestStatus.withdrawn => 'Withdrawn',
                },
                icon: switch (meetup.myRequestStatus!) {
                  MeetupRequestStatus.pending => AppIcons.clock,
                  MeetupRequestStatus.accepted => AppIcons.check,
                  MeetupRequestStatus.rejected => AppIcons.info,
                  MeetupRequestStatus.withdrawn => AppIcons.back,
                },
                // `rejected` stays DELIBERATELY NEUTRAL rather than danger:
                // the requester was not picked for a small group, and the
                // card must not look like something went wrong.
                tone: switch (meetup.myRequestStatus!) {
                  MeetupRequestStatus.pending => AppTone.warning,
                  MeetupRequestStatus.accepted => AppTone.success,
                  MeetupRequestStatus.rejected => AppTone.neutral,
                  MeetupRequestStatus.withdrawn => AppTone.neutral,
                },
                compact: true,
              ),
          ],
        ),
        const SizedBox(height: 6),
        // A locked meetup's WINDOW is redacted (ADR-028), so there is
        // nothing to print — a shimmer says "a real value lives here and
        // you cannot see it yet", where a dash would read as "no time set".
        if (locked)
          const SkeletonBox(width: 130, height: 13, opacity: 0.08)
        else
          Text(
            meetup.formattedWindow,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14.5,
              height: 1.25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        const SizedBox(height: 2),
        // The location is shown even when locked: the guest tier keeps it
        // (ADR-002 § 5).
        Text(
          meetup.locationLabel ?? 'Location unavailable',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: locked
                  ? Text(
                      "Sign up to see who's hosting",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textTertiary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : _HostLine(meetup: meetup),
            ),
            const SizedBox(width: 8),
            Text(
              '${meetup.acceptedCount}/${meetup.capacity} JOINED',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The meetup's intent scene as a 62px thumbnail — the same asset
/// [IntentType.imageAsset] already picks, which is also the image the screen set
/// uses for this row.
///
/// It replaced `IntentBackdrop`, a faded full-bleed version of the same
/// photo behind the card's text. The backdrop had to be veiled to ~14%
/// opacity to keep the text legible over it, at which point it read as a
/// smudge rather than a picture. At thumbnail size the photo can be shown
/// at full strength, because nothing is sitting on top of it.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.intent});

  final IntentType intent;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.asset(
        intent.imageAsset,
        width: 62,
        height: 62,
        fit: BoxFit.cover,
        // Decoded at the size actually drawn. There are only as many
        // distinct images as there are intents, so the cache holds at
        // most that many regardless of list length.
        cacheWidth: 186,
        errorBuilder: (context, error, stack) => Container(
          width: 62,
          height: 62,
          color: AppPalette.raised,
          alignment: Alignment.center,
          child: AppIcon(
            intent.iconPath,
            size: 24,
            color: AppPalette.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// `Nimali P. · L3 · ★ 4.8` — the host in one line.
///
/// The card used to give the host a 48px avatar, a wrapping full name, a
/// trust badge, a star rating and a row of verification badges: five
/// elements and about 90px of height for the least decisive fact on the
/// card. The full profile is one tap away on the detail page, which is
/// where someone goes when the host is what they are actually deciding on.
class _HostLine extends StatelessWidget {
  const _HostLine({required this.meetup});

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
          size: 20,
        ),
        const SizedBox(width: 6),
        // The name may shrink but must never be ellipsized away entirely,
        // so it gets the flexible slot and the badges that follow do not.
        Flexible(
          child: Text(
            meetup.hostFullName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'L${meetup.hostTrustLevel}',
          style: TextStyle(
            color: AppPalette.verifiedText,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (meetup.hostRatingCount > 0) ...[
          const SizedBox(width: 6),
          AppIcon(AppIcons.star, size: 11, color: AppPalette.gold),
          const SizedBox(width: 2),
          Text(
            meetup.hostRatingAverage.toStringAsFixed(1),
            style: TextStyle(
              color: AppPalette.gold,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

class LockedCardHeader extends StatelessWidget {
  const LockedCardHeader({super.key, this.locationLabel});

  /// The meetup's location label, which a guest still receives. Null only if
  /// the meetup genuinely has none.
  final String? locationLabel;

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
          child: AppIcon(
            AppIcons.lock,
            size: 20,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The host's name — genuinely absent, so genuinely a shimmer.
              const SkeletonBox(width: 120, height: 13, opacity: 0.08),
              const SizedBox(height: 6),
              // The location — present for a guest (ADR-002 § 5), so shown.
              Text(
                locationLabel ?? 'Location unavailable',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 6),
              Text(
                'Sign up to see who\'s hosting',
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

class MeetupsSkeleton extends StatelessWidget {
  const MeetupsSkeleton({super.key, this.shrinkWrap = false, this.cardCount});

  /// Set when this renders inside another scrollable (Home), where it must
  /// not scroll independently and shows fewer placeholder cards — three
  /// full-height skeletons inside a page that already has content above
  /// them reads as a broken layout rather than a loading state.
  final bool shrinkWrap;

  /// How many placeholder cards to draw. Defaults to the sensible figure for
  /// the mode ([shrinkWrap] or not).
  ///
  /// Callers override it to MATCH THE HEIGHT OF WHAT THEY ARE REPLACING.
  /// Happening Soon swaps a stale list for this one when a filter change is
  /// slow, and a skeleton of a different length would resize the page and
  /// move the scroll position — the exact jump that holding the stale list
  /// exists to prevent.
  final int? cardCount;

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: shrinkWrap
          ? const EdgeInsets.fromLTRB(20, 4, 20, 0)
          : const EdgeInsets.fromLTRB(20, 4, 20, 100),
      itemCount: cardCount ?? (shrinkWrap ? 2 : 3),
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        // The placeholder traces THIS card, not a generic one.
        //
        // It used to be a 48px circle and two bars: the wrong radius, the
        // wrong surface radius, the wrong number of lines, and a round
        // avatar where the card has a 62px rounded-square photo. The whole
        // point of a skeleton is that the real content lands where the
        // grey was; one that does not match is just a flash of noise in a
        // different shape, and the eye has to re-find everything.
        child: FlatCard(
          radius: 22,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The thumbnail: 62 square, radius 16, same as _Thumb.
                  const SkeletonBox(width: 62, height: 62, radius: 16),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title.
                        const SkeletonBox(
                          width: 150,
                          height: 13,
                          opacity: 0.08,
                        ),
                        const SizedBox(height: 8),
                        // The host line: 20px avatar, name, trust, rating.
                        Row(
                          children: const [
                            SkeletonBox(width: 20, height: 20, radius: 10),
                            SizedBox(width: 7),
                            SkeletonBox(width: 96, height: 10),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // When and where.
                        const SkeletonBox(width: 124, height: 10),
                      ],
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
