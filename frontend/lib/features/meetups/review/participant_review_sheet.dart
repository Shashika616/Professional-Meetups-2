import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/meetups/review/review_inputs.dart';

/// Rating ONE person, in a sheet of their own.
///
/// # WHY ONE AT A TIME
///
/// Every person used to be a card on one long page, each carrying a score
/// row and, once scored, a whole trait vocabulary under two tabs. Three
/// people meant three of those stacked up, and the page became a wall in
/// which the question being asked of you was never in one place. Worse,
/// the thing you were being asked to judge — a face and a name — was
/// scrolled away from the chips you were answering with.
///
/// One sheet per person puts the face, the score and the words in the same
/// frame at full width, and leaves the page behind it free to be a short
/// list showing who is still to do. It is also the shape this app already
/// uses whenever it asks for a decision (see `AppSheet`).
///
/// # NOTHING IS LOST BY DISMISSING
///
/// Changes are reported through [onScore] and [onToggleTrait] as they
/// happen, so the page is always current and a swipe-down loses nothing.
/// The sheet keeps its own copy purely to draw itself, which is why it
/// takes the initial values rather than reading page state across a route
/// boundary.
Future<void> showParticipantReviewSheet(
  BuildContext context, {
  required RatableParticipant participant,
  required bool isHost,
  required List<RatingTrait> traits,
  required int? initialScore,
  required Set<String> initialTraits,
  required ValueChanged<int> onScore,
  required ValueChanged<String> onToggleTrait,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) => _ParticipantReviewSheet(
      participant: participant,
      isHost: isHost,
      traits: traits,
      initialScore: initialScore,
      initialTraits: initialTraits,
      onScore: onScore,
      onToggleTrait: onToggleTrait,
    ),
  );
}

class _ParticipantReviewSheet extends StatefulWidget {
  const _ParticipantReviewSheet({
    required this.participant,
    required this.isHost,
    required this.traits,
    required this.initialScore,
    required this.initialTraits,
    required this.onScore,
    required this.onToggleTrait,
  });

  final RatableParticipant participant;
  final bool isHost;
  final List<RatingTrait> traits;
  final int? initialScore;
  final Set<String> initialTraits;
  final ValueChanged<int> onScore;
  final ValueChanged<String> onToggleTrait;

  @override
  State<_ParticipantReviewSheet> createState() =>
      _ParticipantReviewSheetState();
}

class _ParticipantReviewSheetState extends State<_ParticipantReviewSheet> {
  late int? _score = widget.initialScore;
  // A copy, not the page's own set: mutating that directly would edit
  // state the page owns without it knowing, and the callbacks below are
  // what keep the two in step.
  late final Set<String> _selected = {...widget.initialTraits};

  void _setScore(int score) {
    setState(() => _score = score);
    widget.onScore(score);
  }

  void _toggle(String key) {
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else if (_selected.length < kMaxTraitsPerParticipant) {
        _selected.add(key);
      } else {
        // At the cap: the page would ignore this too, so reporting it
        // would put the two copies out of step.
        return;
      }
    });
    widget.onToggleTrait(key);
  }

  @override
  Widget build(BuildContext context) {
    final scored = _score != null;
    return AppSheet(
      title: widget.isHost ? 'RATE THE HOST' : 'RATE THIS PERSON',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfessionalAvatar(
                name: widget.participant.fullName,
                imageUrl: widget.participant.profilePhotoUrl.isEmpty
                    ? null
                    : widget.participant.profilePhotoUrl,
                size: 48,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.participant.fullName,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                    if (widget.isHost) ...[
                      const SizedBox(height: 5),
                      const HostTag(),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'How did it go with them?',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          // Bigger than on a list row: in here the score is the question,
          // not a summary of an answer.
          StarRow(score: _score, onScore: _setScore, size: 36),
          // The vocabulary appears once a score exists, for the same reason
          // it did on the old card: opening straight onto a wall of chips
          // buries the thing actually being asked for. An empty
          // vocabulary (an older server) shows nothing rather than a
          // header over blank space.
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: (!scored || widget.traits.isEmpty)
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 22),
                    child: TraitPicker(
                      traits: widget.traits,
                      selected: _selected,
                      onToggle: _toggle,
                    ),
                  ),
          ),
          const SizedBox(height: 22),
          PrimaryButton(
            label: 'DONE',
            // Nothing to confirm until there is a score: traits are
            // optional, a score is not.
            onPressed: scored ? () => Navigator.pop(context) : null,
          ),
        ],
      ),
    );
  }
}
