import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';

/// The title that opens a section of a page: HAPPENING SOON, WAITING FOR
/// YOUR REVIEW, TRUSTED CONTACTS.
///
/// # IT GOT QUIETER, AND THE GREEN BAR IS GONE (2026-10 redesign)
///
/// This was 15px, `w800`, [AppPalette.textPrimary], with a 4×18 brand-green
/// bar beside it, and the old doc here said it was "meant to outrank
/// everything under it". That was the mistake. A section heading does not
/// compete with the section — it is a signpost you read once and then stop
/// seeing. On Home, HAPPENING SOON at full contrast with a green flag next
/// to it was heavier than the meetup titles underneath, so the strongest
/// thing on the page was a word the user already knew.
///
/// It is now a small tracked-out caption in [AppPalette.textSecondary],
/// which is what the screen set specifies. The cards below it became the
/// loudest thing on the page by the simple method of not shouting over
/// them. The green bar went with it: brand green now means exactly one
/// thing in this app ([AppPalette.solid] — the primary action), and
/// spending it on a decorative tick beside every heading was what made it
/// stop meaning that.
///
/// [SectionLabel] remains the even quieter caption for labels *inside*
/// content (a week name over a card, a group label in a list).
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.trailing});

  final String text;

  /// An optional control on the right edge (a count, a "see all" link).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}
