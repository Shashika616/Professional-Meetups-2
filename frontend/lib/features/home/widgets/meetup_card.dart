import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/intent_backdrop.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
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
  const MeetupCard({
    super.key,
    required this.meetup,
    required this.viewerTrustLevel,
    required this.onRequestToJoin,
    required this.onTap,
  });

  final Meetup meetup;
  final int viewerTrustLevel;
  final VoidCallback onRequestToJoin;
  final VoidCallback onTap;

  /// ADR-028 § 2 — a locked meetup's card tap and join-button tap both
  /// redirect here instead of reaching [onTap]/[onRequestToJoin]: a toast
  /// (same wording pattern as the locked-intent toast Home shows for a
  /// locked chip on `IntentFilterBar`), then the focused checklist. The tap
  /// never reaches RequestToJoin while locked, same as the disabled-button
  /// pattern this replaces — only the destination changes, from a dead end
  /// to somewhere that actually helps.
  void _handleLockedTap(BuildContext context) {
    showSnack(
      context,
      '${meetup.intent.label} requires Level ${meetup.intent.requiredTrustLevelToJoin} trust. Verify your phone, personal email, and details to unlock it.',
      type: ToastType.locked,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Full by EITHER measure: the counts, or the server having already
    // flipped the meetup to `full`. Those two can disagree — the server marks
    // a meetup full on its own rules, and a redacted or stale count is not a
    // reliable second opinion — and the card used to trust only the counts.
    //
    // That was survivable while a status chip sat on the card announcing
    // "FULL" independently. With the chip replaced by the state edge, which
    // encodes live/over/cancelled and not fullness, the counts became the
    // ONLY signal, and a server-full meetup with a stale count would have
    // offered REQUEST TO JOIN for a meetup nobody can join.
    final full =
        meetup.acceptedCount >= meetup.capacity ||
        meetup.status == MeetupStatus.full;
    final locked = meetup.lockedForViewer;
    // Green while the meetup is still ahead, gold once its window has passed,
    // muted if cancelled. Same three states, same two colours, same left edge
    // as the ACTIVE MEETUPS rows on Home and the cards on Events, so one
    // meetup does not change vocabulary between the three screens that show
    // it. The OPEN chip that used to sit on the right is gone with it.
    final end = meetup.windowEnd;
    final over = end != null && DateTime.now().isAfter(end);
    final edge = switch (meetup.status) {
      MeetupStatus.cancelled => AppPalette.textSecondary,
      _ when over => AppPalette.gold,
      _ => AppPalette.verified,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: locked ? () => _handleLockedTap(context) : onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: FlatCard(
            radius: 14,
            padding: EdgeInsets.zero,
            child: Stack(
              children: [
                // The intent's scene, faint, down the right side — see
                // IntentBackdrop for why it is drawn without a saveLayer.
                IntentBackdrop(intent: meetup.intent),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(width: 4, color: edge),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (locked)
                                LockedCardHeader(
                                  locationLabel: meetup.locationLabel,
                                )
                              else
                                _CardHeader(meetup: meetup),
                              const SizedBox(height: 14),
                              // WHEN and WHERE, as their own labelled lines.
                              //
                              // The time used to sit in a grey pill between the intent and
                              // the joined count, and the place was a caption under the
                              // host's name — so the two facts that decide whether someone
                              // can actually come were the least legible things on the card.
                              // They now lead, with the time in the primary text colour
                              // because it is the one a user scans for.
                              // Both rows are skipped entirely on a locked card, and for
                              // different reasons: the time is redacted by ADR-028 so there
                              // is nothing to show, and the location is already rendered by
                              // LockedCardHeader — the guest tier deliberately keeps it
                              // (ADR-002 §5), so repeating it here would print the same
                              // address twice.
                              if (!locked) ...[
                                _DetailRow(
                                  icon: Icons.event_outlined,
                                  text: meetup.formattedWindow,
                                  emphasised: true,
                                ),
                                const SizedBox(height: 6),
                                _DetailRow(
                                  icon: Icons.place_outlined,
                                  text:
                                      meetup.locationLabel ??
                                      'Location unavailable',
                                ),
                                const SizedBox(height: 14),
                              ],
                              // The status chip used to close this row. It is the left edge
                              // now, so what remains is the two facts a chip cannot carry:
                              // what kind of meetup it is, and how full it is.
                              // The viewer's own relationship to the meetup
                              // (hosting it, or where their request stands) is a
                              // fact about the card, so it sits with the other
                              // facts as a chip — not below them in a box that
                              // reads as a button nothing happens on tapping.
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _tag(meetup.intent.label),
                                  _tag(
                                    '${meetup.acceptedCount}/${meetup.capacity} JOINED',
                                  ),
                                  if (!locked && meetup.isHostedByMe)
                                    const _StatusChip(
                                      icon: Icons.star_rounded,
                                      label: 'YOU\'RE HOSTING',
                                      tone: _StatusTone.host,
                                    )
                                  else if (!locked &&
                                      meetup.myRequestStatus != null)
                                    _StatusChip(
                                      icon: switch (meetup.myRequestStatus!) {
                                        MeetupRequestStatus.pending =>
                                          Icons.hourglass_top_rounded,
                                        MeetupRequestStatus.accepted =>
                                          Icons.check_circle_rounded,
                                        MeetupRequestStatus.rejected =>
                                          Icons.cancel_rounded,
                                        MeetupRequestStatus.withdrawn =>
                                          Icons.undo_rounded,
                                      },
                                      label: switch (meetup.myRequestStatus!) {
                                        MeetupRequestStatus.pending =>
                                          'REQUEST PENDING',
                                        MeetupRequestStatus.accepted =>
                                          'YOU\'RE IN',
                                        MeetupRequestStatus.rejected =>
                                          'REQUEST DECLINED',
                                        MeetupRequestStatus.withdrawn =>
                                          'WITHDRAWN',
                                      },
                                      tone: switch (meetup.myRequestStatus!) {
                                        MeetupRequestStatus.pending =>
                                          _StatusTone.pending,
                                        MeetupRequestStatus.accepted =>
                                          _StatusTone.accepted,
                                        MeetupRequestStatus.rejected =>
                                          _StatusTone.declined,
                                        MeetupRequestStatus.withdrawn =>
                                          _StatusTone.muted,
                                      },
                                    ),
                                ],
                              ),
                              // Only a real action gets a button. A viewer who is
                              // hosting, or has already asked, has nothing to press
                              // here, so the row ends and VIEW LOCATION follows.
                              if (locked) ...[
                                const SizedBox(height: 14),
                                PrimaryButton(
                                  label: 'REQUEST TO JOIN',
                                  height: 42,
                                  onPressed: () => _handleLockedTap(context),
                                ),
                              ] else if (!meetup.isHostedByMe &&
                                  meetup.myRequestStatus == null) ...[
                                const SizedBox(height: 14),
                                PrimaryButton(
                                  label: full ? 'FULL' : 'REQUEST TO JOIN',
                                  height: 42,
                                  onPressed: full ? null : onRequestToJoin,
                                ),
                              ] else
                                const SizedBox(height: 6),
                              const SizedBox(height: 4),
                              // A quiet text action under the primary one, as in the
                              // reference: two equally-weighted outlined buttons stacked read
                              // as a choice between equals, and this is not one. Joining is
                              // the point of the card; looking at the map is a detail.
                              //
                              // ADR-029 (round-8 hardening) — same lockedForViewer gate as
                              // every other action here (LocationViewPage.open handles the
                              // toast+redirect itself), shown regardless of hosting/request
                              // state.
                              // An outlined, full-width secondary action with
                              // a pin — bare grey caps text read as a caption,
                              // not as something to press. Still quieter than
                              // the filled primary above it.
                              OutlinedButton.icon(
                                onPressed: () => LocationViewPage.open(
                                  context,
                                  meetup,
                                  viewerTrustLevel: viewerTrustLevel,
                                ),
                                icon: Icon(
                                  Icons.location_on_outlined,
                                  size: 16,
                                  color: AppPalette.candyBlue,
                                ),
                                label: Text(
                                  'VIEW LOCATION',
                                  style: TextStyle(
                                    color: AppPalette.candyBlue,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(40),
                                  side: BorderSide(
                                    color: AppPalette.candyBlue.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
              // Three stacked lines, none of which may truncate: the name
              // wraps onto a second line if it must; the trust badge and
              // rating sit under it; the verification badges under those.
              // The old single row put the name, badge and stars side by
              // side and cut the name off with an ellipsis whenever the
              // three did not fit — a person's name is the one thing on
              // the card that must never be abbreviated.
              Text(
                // hostFullName is only ever null for a locked meetup
                // (ADR-028) — _MeetupCard never mounts this widget in
                // that case, so this is always real data here.
                meetup.hostFullName!,
                softWrap: true,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TrustLevelBadge(trustLevel: meetup.hostTrustLevel),
                  StarRating(
                    average: meetup.hostRatingAverage,
                    count: meetup.hostRatingCount,
                  ),
                ],
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

/// One "when"/"where" line: an icon, then the fact.
///
/// [emphasised] puts the text in the primary colour at a heavier weight —
/// used for the date and time, which is what a person scans a listing for
/// first. The place is important but secondary: you check the time to see if
/// you *can* go, then the place to see if you *want* to.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.text,
    this.emphasised = false,
  });

  final IconData icon;
  final String text;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // Optical alignment with the first line of a two-line address,
          // rather than centring against the whole block.
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            icon,
            size: 14,
            color: emphasised ? AppPalette.candyBlue : AppPalette.textSecondary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: emphasised
                  ? AppPalette.textPrimary
                  : AppPalette.textSecondary,
              fontSize: emphasised ? 13 : 12,
              fontWeight: emphasised ? FontWeight.w700 : FontWeight.w400,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// ADR-028 § 2 — stands in for [_CardHeader] on a `lockedForViewer` meetup:
/// a frosted lock icon in place of the avatar, a blurred placeholder bar
/// (reusing [SkeletonBox], this app's existing placeholder-shimmer language)
/// in place of the real host name, and a short caption explaining why. Never
/// renders real host data — there isn't any to render, the server already
/// redacted it.
///
/// ADR-002 § 5 NARROWED WHAT IS HIDDEN HERE. `lockedForViewer` now means
/// exactly one thing — the viewer is a guest — and the guest tier keeps the
/// location deliberately, so the second placeholder bar (which stood in for
/// location text) is replaced by the real [locationLabel]. Showing a shimmer
/// over data the server actually sent would be inventing a restriction the
/// backend does not have, which is the mirror image of the client-side-only
/// gate ADR-028 rejected.
///
/// The caption changed with it: a guest is not "unverified", they have not
/// signed up, and telling them to verify points at a checklist they cannot
/// start (every row on it needs LinkedIn, which needs an account).
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

enum _StatusTone { host, pending, accepted, declined, muted }

/// The viewer's relationship to the meetup as a chip in the tag row — same
/// shape as the intent/joined tags so it reads as one more fact, with an
/// icon and a tone so it still reads at a glance.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _StatusTone.host => AppPalette.brandGreen,
      _StatusTone.pending => AppPalette.gold,
      _StatusTone.accepted => AppPalette.verified,
      _StatusTone.declined => AppPalette.danger,
      _StatusTone.muted => AppPalette.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
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
