import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The inputs a review is made of: a score, and a vocabulary of traits.
///
/// These were private to `meetup_review_page.dart` while the whole review
/// happened on that one page. Rating one person now happens in its own
/// bottom sheet, so the same inputs are needed in two places and they live
/// here rather than being copied — a second copy of the trait cap or the
/// tab partitioning is a second place for them to disagree with the
/// server.

/// How many traits, across both tabs together, one rater may attach to one
/// person. Mirrors the server's own cap; the server still enforces it.
const int kMaxTraitsPerParticipant = 4;

/// Five stars, tappable, with a small pop as each fills.
class StarRow extends StatelessWidget {
  const StarRow({
    super.key,
    required this.score,
    required this.onScore,
    this.size = 30,
  });

  final int? score;
  final ValueChanged<int> onScore;

  /// Bigger inside a sheet, where the score is the main question, than in
  /// a list row where it is a summary.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            onTap: () => onScore(i),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                tween: Tween(end: (score ?? 0) >= i ? 1.0 : 0.0),
                builder: (context, t, _) => Transform.scale(
                  // Filled stars pop very slightly, so tapping a score
                  // registers as an action rather than a repaint.
                  scale: 1 + (t * 0.12),
                  child: Icon(
                    t > 0.5 ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: size,
                    color: Color.lerp(
                      AppPalette.textSecondary.withValues(alpha: 0.55),
                      AppPalette.gold,
                      t,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The badge marking which of the people being rated hosted the meetup.
class HostTag extends StatelessWidget {
  const HostTag({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.candyBlue.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'HOST',
        style: TextStyle(
          color: AppPalette.candyBlue,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// The vocabulary under two tabs, Positive and Negative, with one shared
/// cap. Two tabs rather than one long wrap so a rater who only wants to say
/// something kind never has to read past a list of criticisms to do it,
/// and so the criticisms, when wanted, are a deliberate switch away rather
/// than mixed in. The tab remembers itself while the picker lives.
class TraitPicker extends StatefulWidget {
  const TraitPicker({
    super.key,
    required this.traits,
    required this.selected,
    required this.onToggle,
  });

  final List<RatingTrait> traits;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  State<TraitPicker> createState() => _TraitPickerState();
}

class _TraitPickerState extends State<TraitPicker> {
  bool _showNegative = false;

  @override
  Widget build(BuildContext context) {
    // Partitioned once per build from the server's order, which is already
    // grouped; each tab keeps that order.
    final positive = <RatingTrait>[];
    final negative = <RatingTrait>[];
    for (final t in widget.traits) {
      (t.negative ? negative : positive).add(t);
    }
    // A vocabulary with no negative half (an older server) needs no tabs.
    final tabbed = negative.isNotEmpty && positive.isNotEmpty;
    final showing = _showNegative && tabbed ? negative : positive;
    final tone = _showNegative && tabbed
        ? AppPalette.danger
        : AppPalette.candyBlue;
    final atCap = widget.selected.length >= kMaxTraitsPerParticipant;

    int countIn(List<RatingTrait> list) =>
        list.where((t) => widget.selected.contains(t.key)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What were they like? (up to $kMaxTraitsPerParticipant)',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
        ),
        if (tabbed) ...[
          const SizedBox(height: 10),
          _TraitTabs(
            showNegative: _showNegative,
            positiveCount: countIn(positive),
            negativeCount: countIn(negative),
            onChanged: (negative) => setState(() => _showNegative = negative),
          ),
          const SizedBox(height: 4),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final trait in showing)
              _TraitChip(
                trait: trait,
                tone: tone,
                selected: widget.selected.contains(trait.key),
                // At the cap, the unselected chips go quiet rather than
                // vanishing — the vocabulary stays legible.
                dimmed: atCap && !widget.selected.contains(trait.key),
                onTap: () => widget.onToggle(trait.key),
              ),
          ],
        ),
      ],
    );
  }
}

/// The picker's switch between its two halves: two equal, full-width
/// segments, read as a different KIND of thing from the chips beneath
/// them by size and treatment, not by colour fill. The active segment is
/// drawn at full size with its border and type in the tab's colour; the
/// inactive one sits slightly smaller and in grey. No solid fill: a filled
/// block in either brand colour swallowed the label, and the chips already
/// use tint for "selected", so the tabs must not. Each side carries a
/// count once anything there is chosen, so a rater on one tab can see
/// they have picked something on the other without switching back.
class _TraitTabs extends StatelessWidget {
  const _TraitTabs({
    required this.showNegative,
    required this.positiveCount,
    required this.negativeCount,
    required this.onChanged,
  });

  final bool showNegative;
  final int positiveCount;
  final int negativeCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TraitSegment(
          key: const Key('traitTabPositive'),
          label: 'POSITIVE',
          icon: Icons.thumb_up_alt_rounded,
          count: positiveCount,
          active: !showNegative,
          tone: AppPalette.candyBlue,
          onTap: () => onChanged(false),
        ),
        const SizedBox(width: 10),
        _TraitSegment(
          key: const Key('traitTabNegative'),
          label: 'NEGATIVE',
          icon: Icons.thumb_down_alt_rounded,
          count: negativeCount,
          active: showNegative,
          tone: AppPalette.danger,
          onTap: () => onChanged(true),
        ),
      ],
    );
  }
}

class _TraitSegment extends StatelessWidget {
  const _TraitSegment({
    super.key,
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final int count;
  final bool active;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = active ? tone : AppPalette.textSecondary;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: count == 0 ? label : '$label, $count chosen',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            // The inactive tab steps back rather than the active one
            // stepping forward, so the active one is always at true size
            // and never clipped by the card.
            scale: active ? 1.0 : 0.94,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              height: 42,
              decoration: BoxDecoration(
                color: AppPalette.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active ? tone : AppPalette.hairline,
                  width: active ? 1.8 : 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 15, color: foreground),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: active ? 0.22 : 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          color: tone,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TraitChip extends StatelessWidget {
  const _TraitChip({
    required this.trait,
    required this.tone,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final RatingTrait trait;

  /// The selected colour: the tab's own, so a chosen criticism reads red
  /// and a chosen compliment reads blue wherever the chip is seen.
  final Color tone;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: dimmed ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: dimmed ? 0.4 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? tone.withValues(alpha: 0.2) : AppPalette.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? tone : AppPalette.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(trait.emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                trait.label,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The free-text box on the review, as a proper input rather than a
/// borderless field on a card.
///
/// The old one had `border: InputBorder.none` inside a FlatCard, which
/// meant focus was completely invisible — nothing on screen changed when
/// the caret arrived, and on a phone keyboard that is the only cue that
/// typing will land somewhere. It also hid the 500-character cap until the
/// field silently stopped accepting input.
///
/// So: a real edge that takes the accent when focused, and a counter that
/// appears only as the cap comes into view, rather than a number sitting
/// there being ignored from the first keystroke.
class ReviewNotesField extends StatefulWidget {
  const ReviewNotesField({
    super.key,
    required this.controller,
    this.maxLength = 500,
    this.hint = 'Describe in detail (optional)',
    this.label = 'ANYTHING TO ADD?',
  });

  final TextEditingController controller;
  final int maxLength;
  final String hint;
  final String label;

  /// How close to the cap the counter starts showing.
  static const _counterVisibleWithin = 100;

  @override
  State<ReviewNotesField> createState() => _ReviewNotesFieldState();
}

class _ReviewNotesFieldState extends State<ReviewNotesField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onTextChanged() {
    // Only the counter depends on the text, and only near the cap, so
    // this rebuild is cheap and bounded.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onTextChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final used = widget.controller.text.characters.length;
    final remaining = widget.maxLength - used;
    final nearCap = remaining <= ReviewNotesField._counterVisibleWithin;
    final focused = _focus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),
            ),
            if (nearCap)
              Text(
                '$remaining',
                style: TextStyle(
                  color: remaining <= 0
                      ? AppPalette.danger
                      : AppPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: AppPalette.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? AppPalette.candyBlue : AppPalette.hairline,
              width: focused ? 1.6 : 1,
            ),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            maxLines: 4,
            minLines: 3,
            maxLength: widget.maxLength,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              height: 1.4,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              // The field draws its own counter above, where it can be
              // conditional; Material's would always be there.
              counterText: '',
              hintText: widget.hint,
              hintStyle: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
