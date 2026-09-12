import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/meetups/participants_page.dart';

/// Who's coming, on the meetup card itself: a row of overlapping faces and a
/// way through to the full list.
///
/// # THE REDACTED CASE IS NOT A BLUR OVER REAL DATA
///
/// Below trust level 2 the server sends no ids, names or photos at all — see
/// the backend's ListMeetupParticipants. So the placeholder faces here are
/// not a censored render of something the client received; there is nothing
/// to censor. What survives redaction is the COUNT and the shape of the
/// list, which is the point: a guest should see that real people are really
/// coming — that is the reason to sign up — without learning who they are.
class ParticipantsStrip extends ConsumerWidget {
  const ParticipantsStrip({
    super.key,
    required this.meetupId,
    this.meetup,
    this.finished = false,
  });

  final String meetupId;

  /// Passed through to the participants page so it opens with the
  /// meetup's own card at the top — the strip is the page's only entry
  /// now that the separate PARTICIPANTS tile is gone.
  final Meetup? meetup;

  /// The meetup is over (window ended, cancelled, or closed). The count
  /// reads "joined" rather than "going": nobody is going anywhere any more,
  /// and this same strip sits on the page for a historical meetup.
  final bool finished;

  /// How many faces fit on a card before the row starts to crowd the text
  /// beside it; the rest become a "+N".
  static const _maxFaces = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewerTrustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;
    final verb = finished ? 'joined' : 'going';
    // Was a ConsumerStatefulWidget fetching in initState, which made this and
    // ParticipantsPage two independent uncached reads of the same rows about a
    // second apart. Both now watch one family; the second one to mount gets
    // the first one's result. See meetupParticipantsProvider.
    final async = ref.watch(meetupParticipantsProvider(meetupId));

    // A 401 means the session itself is gone, so every later call fails too.
    // Showing an error the user can only retry forever helps nobody; signing
    // out is the only thing that recovers. Mirrors profile_page.dart's idiom.
    // Deferred to after this frame because build must not mutate providers.
    if (async.hasError && async.error is MeetupSessionExpiredException) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      });
      return const SizedBox.shrink();
    }

    // Supporting detail on a card that is already useful without it - while
    // loading, or after a failed read, this shows nothing rather than an error
    // where faces go. Same posture the initState version had.
    final data = async.value;
    if (data == null || data.totalCount == 0) {
      return const SizedBox.shrink();
    }

    final shown = data.participants.take(_maxFaces).toList();
    final overflow = data.totalCount - shown.length;

    return GestureDetector(
      onTap: () =>
          ParticipantsPage.open(context, meetupId: meetupId, meetup: meetup),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SizedBox(
            height: 30,
            width: (shown.length + (overflow > 0 ? 1 : 0)) * 21.0 + 9,
            child: Stack(
              children: [
                for (var i = 0; i < shown.length; i++)
                  Positioned(
                    left: i * 21.0,
                    child: _Face(
                      participant: shown[i],
                      redacted: data.redacted && shown[i].fullName.isEmpty,
                    ),
                  ),
                if (overflow > 0)
                  Positioned(
                    left: shown.length * 21.0,
                    child: _OverflowBubble(count: overflow),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              data.redacted
                  // Says the number, withholds the names, and says why in
                  // the one place someone would ask — the reason depends on
                  // whether the viewer is unverified or just not on it.
                  ? (viewerTrustLevel < 2
                        ? '${data.totalCount} $verb · verify to see who'
                        : '${data.totalCount} $verb · join to see who')
                  : '${data.totalCount} $verb',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppPalette.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// One face in the strip, ringed so overlapping avatars stay separable.
class _Face extends StatelessWidget {
  const _Face({required this.participant, required this.redacted});

  final MeetupParticipant participant;
  final bool redacted;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppPalette.card, width: 2),
      ),
      child: redacted
          ? const RedactedFace(size: 26)
          : ProfessionalAvatar(
              name: participant.fullName,
              imageUrl: participant.profilePhotoUrl.isEmpty
                  ? null
                  : participant.profilePhotoUrl,
              size: 26,
            ),
    );
  }
}

/// The stand-in for a person whose identity was never sent.
///
/// A soft silhouette rather than a literal blur filter: an ImageFilter blur
/// costs a saveLayer per face and, worse, implies there is something
/// underneath it to sharpen. There isn't.
class RedactedFace extends StatelessWidget {
  const RedactedFace({super.key, this.size = 26});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppPalette.textSecondary.withValues(alpha: 0.30),
            AppPalette.textSecondary.withValues(alpha: 0.16),
          ],
        ),
      ),
      child: Icon(
        Icons.person_rounded,
        size: size * 0.62,
        color: AppPalette.card,
      ),
    );
  }
}

class _OverflowBubble extends StatelessWidget {
  const _OverflowBubble({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.candyBlue.withValues(alpha: 0.20),
        shape: BoxShape.circle,
        border: Border.all(color: AppPalette.card, width: 2),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
