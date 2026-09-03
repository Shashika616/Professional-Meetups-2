import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';

/// The "rate who I met" step (ADR-015, docs/02-domain/domain-model.md §
/// Rating) — shown once the viewer confirms (SubmitMeetupFeedback,
/// happened=true) that a meetup happened. Fetches the viewer's other
/// participants on this meetup (host + accepted requesters, excluding
/// self) and lets them tap a 1-5 star score per person; each rating
/// submits immediately on tap, is skippable (nothing here blocks
/// navigating away), and — matching the backend's one-rating-immutable
/// rule — becomes a static "Rated" state once submitted rather than a
/// re-tappable picker.
class RatingPrompt extends ConsumerStatefulWidget {
  const RatingPrompt({super.key, required this.meetupId});

  final String meetupId;

  @override
  ConsumerState<RatingPrompt> createState() => _RatingPromptState();
}

class _RatingPromptState extends ConsumerState<RatingPrompt> {
  List<RatableParticipant>? _participants;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final participants = await ref
          .read(meetupServiceProvider)
          .listRatableParticipants(widget.meetupId);
      if (!mounted) return;
      setState(() {
        _participants = participants;
        _loading = false;
      });
    } catch (_) {
      // A failed fetch here shouldn't block the rest of the page — this
      // step is entirely optional/skippable, so it just quietly stays
      // empty rather than showing an alarming error for a non-critical
      // fetch.
      if (!mounted) return;
      setState(() {
        _participants = const [];
        _loading = false;
      });
    }
  }

  /// Confirms before submitting — ratings are immutable and one-shot
  /// (ADR-015), so this is the last chance to catch a mis-tap, unlike
  /// closing a meetup (a reversible display/organizational move) which
  /// doesn't need the same weight (ADR-016).
  Future<void> _confirmAndRate(
    RatableParticipant participant,
    int score,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'CONFIRM RATING',
          style: TextStyle(
            color: AppPalette.textPrimary,
            letterSpacing: 1.6,
            fontSize: 15,
          ),
        ),
        content: Text(
          'Rate ${participant.fullName} $score '
          '${score == 1 ? 'star' : 'stars'}? You won\'t be able to change '
          'this later.',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'CANCEL',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'CONFIRM',
              style: TextStyle(
                color: AppPalette.gold,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await _rate(participant, score);
  }

  Future<void> _rate(RatableParticipant participant, int score) async {
    try {
      await ref
          .read(meetupServiceProvider)
          .submitRating(
            widget.meetupId,
            ratedUserId: participant.userId,
            score: score,
          );
      if (!mounted) return;
      setState(() {
        _participants = _participants!
            .map(
              (p) => p.userId == participant.userId
                  ? RatableParticipant(
                      userId: p.userId,
                      fullName: p.fullName,
                      profilePhotoUrl: p.profilePhotoUrl,
                      trustLevel: p.trustLevel,
                      alreadyRated: true,
                      contextNote: p.contextNote,
                    )
                  : p,
            )
            .toList();
      });
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final participants = _participants!;
    if (participants.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('RATE WHO YOU MET'),
        const SizedBox(height: 12),
        ...participants.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FlatCard(
              radius: 12,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ProfessionalAvatar(
                        name: p.fullName,
                        imageUrl: p.profilePhotoUrl.isEmpty
                            ? null
                            : p.profilePhotoUrl,
                        size: 36,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          p.fullName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (p.alreadyRated)
                        Text(
                          'RATED',
                          style: TextStyle(
                            color: AppPalette.verified,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                            letterSpacing: 0.6,
                          ),
                        )
                      else
                        _StarPicker(
                          onRate: (score) => _confirmAndRate(p, score),
                        ),
                    ],
                  ),
                  // The withdrawal note (ADR-020 §4) — only present on a
                  // withdrawal-triggered entry, giving the host the
                  // requester's own context while deciding how to rate them.
                  if (p.contextNote != null && p.contextNote!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '"${p.contextNote}"',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StarPicker extends StatelessWidget {
  const _StarPicker({required this.onRate});

  final ValueChanged<int> onRate;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (i) => GestureDetector(
          onTap: () => onRate(i + 1),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 1),
            child: Icon(
              Icons.star_outline_rounded,
              size: 22,
              color: AppPalette.gold,
            ),
          ),
        ),
      ),
    );
  }
}
