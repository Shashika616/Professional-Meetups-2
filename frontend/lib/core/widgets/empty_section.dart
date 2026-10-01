import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// "There is nothing here yet", said properly.
///
/// # WHY THIS EXISTS
///
/// A section with nothing in it used to render as a line of grey text in a
/// shrink-wrapped card — a small box hugging the left edge of an otherwise
/// full-width column, which reads as something that failed to load rather
/// than as a section that is legitimately empty. Emptiness is a state the
/// design has to account for, not a gap left where content would have been.
///
/// So: full width, so it belongs to the column it sits in; a quiet icon so
/// the eye has somewhere to land; a title that says what is missing; and an
/// optional line saying what would put something there. That last part is
/// what turns a dead end into an explanation.
///
/// This is the INLINE form, for a section inside a page that has other
/// content. [EmptyStateDeck] is the whole-page form, with an illustration
/// and an action — use that when the empty section IS the page.
class EmptySection extends StatelessWidget {
  const EmptySection({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.compact = false,
  });

  final IconData icon;

  /// What is missing, as a statement: "No meetups yet".
  final String title;

  /// Optionally, what would fill it. Skipped where nothing the viewer can
  /// do would change it (another member's history, say).
  final String? message;

  /// Tighter padding for a section that sits among several others.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: message == null ? title : '$title. $message',
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          vertical: compact ? 22 : 30,
          horizontal: 20,
        ),
        decoration: BoxDecoration(
          color: AppPalette.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppPalette.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                // Composited onto the card, so it reads in both themes —
                // a hardcoded white wash is invisible in light mode.
                color: AppPalette.tintedSurface(
                  AppPalette.textPrimary.withValues(alpha: 0.05),
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 21, color: AppPalette.textSecondary),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message case final message?) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
