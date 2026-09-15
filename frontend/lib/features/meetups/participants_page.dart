import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/intent_backdrop.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/widgets/participants_strip.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// The full attendee list.
///
/// Below trust level 2 this shows the right NUMBER of people with no
/// identities, because that is exactly what the server sent — see
/// [ParticipantsStrip] and the backend's ListMeetupParticipants for why the
/// redaction happens there and not here.
class ParticipantsPage extends ConsumerStatefulWidget {
  const ParticipantsPage({super.key, required this.meetupId, this.meetup});

  final String meetupId;

  /// The meetup itself, when the caller has it: puts what/when/where at the
  /// top of the list and lets the page show open spots against capacity.
  /// Optional so the strip, which only knows the id, can still open it.
  final Meetup? meetup;

  static Future<void> open(
    BuildContext context, {
    required String meetupId,
    Meetup? meetup,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ParticipantsPage(meetupId: meetupId, meetup: meetup),
      ),
    );
  }

  @override
  ConsumerState<ParticipantsPage> createState() => _ParticipantsPageState();
}

class _ParticipantsPageState extends ConsumerState<ParticipantsPage> {
  // Reads meetupParticipantsProvider rather than calling the service from
  // initState, which is what made this page and ParticipantsStrip fetch the
  // same rows twice within a second of each other. Kept as a ConsumerState
  // (not a ConsumerWidget) because the AppBackground/Scaffold scaffolding
  // below is unchanged and rewriting it would be churn for no gain.

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: AppPalette.textPrimary),
          title: Text(
            'WHO\'S COMING',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    final viewerTrustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;
    final async = ref.watch(meetupParticipantsProvider(widget.meetupId));

    // A 401 means the session itself is gone, so every later call fails too.
    // Showing a retry the user can press forever helps nobody; signing out is
    // the only thing that recovers. Mirrors profile_page.dart's idiom, and is
    // deferred past this frame because build must not mutate a provider.
    if (async.hasError && async.error is MeetupSessionExpiredException) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      });
      return const SizedBox.shrink();
    }

    if (async.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: SkeletonLoader(child: _ParticipantsSkeleton()),
      );
    }
    final data = async.value;
    if (async.hasError || data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                "Couldn't load who's coming.",
                style: TextStyle(color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'TRY AGAIN',
                height: 44,
                // Invalidate rather than re-calling the service: it clears
                // the cached failure so the strip on the page behind this one
                // recovers too, instead of each surface retrying separately.
                onPressed: () =>
                    ref.invalidate(meetupParticipantsProvider(widget.meetupId)),
              ),
            ],
          ),
        ),
      );
    }

    final meetup = widget.meetup;
    final viewerId = ref.watch(authSessionProvider).value?.profile?.id;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        if (meetup != null) ...[
          _MeetupContextCard(meetup: meetup),
          const SizedBox(height: 18),
        ],
        // A redacted list means one of two things, and the notice must say
        // the right one: below Level 2 the viewer is not verified enough to
        // see anyone (the original ADR-028 rule); at Level 2+ they simply
        // are not on this meetup — identities are for the host and the
        // people the host accepted. The host row itself arrives NAMED in a
        // redacted list for any verified viewer (a joiner must be able to
        // judge who they are asking), so redaction is decided per row from
        // whether the server sent an identity, never from the list flag
        // alone.
        if (data.redacted) ...[
          if (viewerTrustLevel < 2)
            const _VerifyToSeeNotice()
          else
            const _JoinToSeeNotice(),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 10),
          child: Row(
            children: [
              Text(
                'PEOPLE',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),
              const Spacer(),
              Text(
                meetup == null
                    ? (data.totalCount == 1
                          ? '1 person'
                          : '${data.totalCount} people')
                    : '${data.totalCount} of ${meetup.capacity} confirmed',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        // One grouped card, rows divided by hairlines — a list of people,
        // not a stack of identical boxes.
        FlatCard(
          radius: 14,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < data.participants.length; i++) ...[
                if (i > 0) _divider(),
                _ParticipantRow(
                  participant: data.participants[i],
                  redacted:
                      data.redacted && data.participants[i].fullName.isEmpty,
                  isViewer:
                      viewerId != null &&
                      data.participants[i].userId == viewerId,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _divider() => Padding(
    padding: const EdgeInsets.only(left: 72),
    child: Container(height: 1, color: AppPalette.hairline),
  );
}

/// What the list is FOR, at the top: the meetup's intent, time and place,
/// with the intent's scene faint behind it — the same card the meetup page
/// opens with, so the two screens read as one thing.
class _MeetupContextCard extends StatelessWidget {
  const _MeetupContextCard({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: FlatCard(
        radius: 14,
        padding: EdgeInsets.zero,
        child: Stack(
          children: [
            IntentBackdrop(intent: meetup.intent),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppPalette.candyBlue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      meetup.intent.icon,
                      size: 20,
                      color: AppPalette.candyBlue,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          meetup.intent.label,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          meetup.formattedWindow,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if ((meetup.locationLabel ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            meetup.locationLabel!,
                            style: TextStyle(
                              color: AppPalette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown to a verified viewer who is not on the meetup. No call to action:
/// the way to see the guest list is to be accepted onto it, and REQUEST TO
/// JOIN lives on the meetup page they came from.
class _JoinToSeeNotice extends StatelessWidget {
  const _JoinToSeeNotice();

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 17,
            color: AppPalette.candyBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Join to see who\'s coming',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Names and photos are shared between the host and the '
                  'people they\'ve accepted. You can see the host now; '
                  'the rest appear once you\'re in.',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VerifyToSeeNotice extends StatelessWidget {
  const _VerifyToSeeNotice();

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      tint: AppPalette.candyBlue.withValues(alpha: 0.07),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 17,
                color: AppPalette.candyBlue,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Verify to see who’s coming',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Names and photos are only shared with verified members. It is the '
            'same protection everyone here gets.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'GET VERIFIED',
            height: 44,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const VerificationChecklistPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.participant,
    required this.redacted,
    required this.isViewer,
  });

  final MeetupParticipant participant;
  final bool redacted;

  /// This row is the signed-in user — gets a YOU tag so they can find
  /// themselves in the list.
  final bool isViewer;

  /// Wide enough for the longest pill (JOINED) with its icon.
  static const double _roleColumnWidth = 88;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: redacted
          ? null
          : () => PublicProfilePage.open(
              context,
              userId: participant.userId,
              initialName: participant.fullName,
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // IntrinsicHeight so the vertical rule spans whatever height the
        // wrapped name and badges make the left side.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (redacted)
                const RedactedFace(size: 44)
              else
                ProfessionalAvatar(
                  name: participant.fullName,
                  imageUrl: participant.profilePhotoUrl.isEmpty
                      ? null
                      : participant.profilePhotoUrl,
                  size: 44,
                ),
              const SizedBox(width: 12),
              // Left: who they are. Never truncated — the name wraps.
              Expanded(
                child: redacted
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _bar(128, 12),
                          const SizedBox(height: 8),
                          _bar(72, 9),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            participant.fullName,
                            softWrap: true,
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              TrustLevelBadge(
                                trustLevel: participant.trustLevel,
                              ),
                              VerificationBadges(
                                trustLevel: participant.trustLevel,
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
              // Right: their role on this meetup, divided from the identity
              // by a rule, then the chevron at the very edge. The column has
              // a FIXED width and every pill fills it, so the rule and the
              // pills sit at the same x on every row — a column that sized
              // to its content put the rule wherever the widest pill ended.
              // Every named row has at least one pill (HOST or JOINED), so
              // the column is never empty. A redacted HOST row keeps its
              // pill too — which chair is the host's is part of the shape
              // of the list that survives redaction (ADR-028).
              if (!redacted || participant.isHost) ...[
                const SizedBox(width: 10),
                Container(width: 1, color: AppPalette.hairline),
                const SizedBox(width: 10),
                SizedBox(
                  width: _roleColumnWidth,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (participant.isHost)
                        const _RolePill(
                          icon: Icons.star_rounded,
                          label: 'HOST',
                          tone: _RoleTone.host,
                        )
                      else if (!redacted)
                        const _RolePill(
                          icon: Icons.check_rounded,
                          label: 'JOINED',
                          tone: _RoleTone.joined,
                        ),
                      if (isViewer) ...[
                        const SizedBox(height: 6),
                        const _RolePill(
                          icon: Icons.person_rounded,
                          label: 'YOU',
                          tone: _RoleTone.you,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (!redacted) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppPalette.textSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _bar(double width, double height) => Container(
    height: height,
    width: width,
    decoration: BoxDecoration(
      color: AppPalette.textSecondary.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(6),
    ),
  );
}

enum _RoleTone { host, joined, you }

class _RolePill extends StatelessWidget {
  const _RolePill({
    required this.icon,
    required this.label,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final _RoleTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _RoleTone.host => AppPalette.brandGreen,
      _RoleTone.joined => AppPalette.textSecondary,
      _RoleTone.you => AppPalette.candyBlue,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      // Centred in the fixed column; scales down rather than overflowing
      // if a font renders wider than the column allows for.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantsSkeleton extends StatelessWidget {
  const _ParticipantsSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget box(double h, {double? w}) => Container(
      height: h,
      width: w,
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(12),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        box(22, w: 110),
        const SizedBox(height: 18),
        for (var i = 0; i < 4; i++) ...[box(66), const SizedBox(height: 10)],
      ],
    );
  }
}
