import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';

/// A full-width inline notice: "You're in", "Request pending", "Cancelled
/// by the host", "Add a trusted contact before you can use SOS".
///
/// # IT IS NOT A TOAST AND NOT A DIALOG
///
/// Use this for state that is TRUE FOR AS LONG AS THE SCREEN IS OPEN. A
/// toast is for something that just happened and then stops being news; a
/// dialog is for something that must be answered before anything else can
/// continue. A banner is for a fact about the thing you are looking at, and
/// it should still be there when the user scrolls back up.
///
/// Tone comes from the same [AppTone] scale as [AppTag], so a meetup that
/// shows a green "You're in" tag in a list shows a green "You're in" banner
/// on its own page — one vocabulary, not two.
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.tone = AppTone.accent,
    this.trailing,
  });

  /// The short, bold line. Sentence case — this used to be set in tracked
  /// out uppercase and a three-word uppercase phrase inside a coloured
  /// box reads as an alarm regardless of its colour.
  final String title;

  /// The optional second line explaining the title. Keep it to one
  /// sentence; anything longer belongs on the page, not in the banner.
  final String? message;

  /// One of the `AppIcons.*` stroke paths.
  final String? icon;
  final AppTone tone;

  /// An optional action on the trailing edge (a "Verify" button, a chevron).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final (fill: fill, fg: fg) = resolveTone(tone);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Color.alphaBlend(fill, AppPalette.card),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            AppIcon(icon!, size: 19, color: fg),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: fg,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      // The body line is the same hue at 88%, not
                      // textSecondary: a grey second line under a coloured
                      // first line makes the banner look like two
                      // unrelated pieces of text that happen to share a box.
                      color: fg.withValues(alpha: 0.88),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}
