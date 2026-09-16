import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';

/// The title that opens a section of a page: HAPPENING SOON, WAITING FOR
/// YOUR REVIEW, TRUSTED CONTACTS. Bold, in the primary text colour, with a
/// short brand-green bar so the eye lands on it while scanning.
///
/// [SectionLabel] stays the small grey caption for labels *inside* content
/// (a week name over a card, the group label in a list). Do not swap one for
/// the other: the heading is meant to outrank everything under it.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.trailing});

  final String text;

  /// An optional control on the right edge (a count, a "see all" link).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppPalette.brandGreen,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              height: 1.2,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}
