part of 'profile_page.dart';

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    // Overrides the candyBlue every other row's glyph uses. Only the
    // destructive row passes it: a row that ends an account should not
    // wear the same colour as the one that opens Privacy Controls.
    this.iconColor,
    required this.title,
    // Optional. The screen set's preference rows are an icon, a label and
    // a chevron — no second line. Most of the subtitles here restated the
    // destination ("Trusted contacts and SOS" under "Safety center") or
    // named something the row does not actually show ("Last 7 days" under
    // "Notifications"). The verification rows still pass one, because
    // there the second line carries the state.
    this.subtitle,
    // Renders in place of [subtitle] when given. Exists for the one row
    // whose subtitle is genuinely still loading — a placeholder bar reads
    // as "a value is coming here" where the literal word "Loading…" reads
    // as the value itself.
    this.subtitleOverride,
    required this.trailing,
    // Optional (2026-08-31 review hardening) — every pre-existing caller
    // omits this and stays a purely visual row, same as before. Only rows
    // that actually go somewhere (Safety Center) pass it.
    this.onTap,
  });

  final String icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? subtitleOverride;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              // Theme-derived, and composited onto the card it sits on. Was a
              // hardcoded `Colors.white` at 5%: a faint chip in dark mode and
              // literally invisible in light mode, where it was white on a
              // white card.
              color: AppPalette.tintedSurface(
                AppPalette.textPrimary.withValues(alpha: 0.05),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(
              icon,
              size: 18,
              color: iconColor ?? AppPalette.candyBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitleOverride != null) ...[
                  const SizedBox(height: 2),
                  subtitleOverride!,
                ] else if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
    if (onTap == null) return row;
    // opaque, not the default deferToChild: a Row of an icon, text and a
    // chevron leaves most of its width as transparent padding, and
    // deferToChild only hit-tests the painted children — so the row only
    // responded on the label or the arrow, with dead space between them.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppPalette.hairline,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}

/// A round, raised control on the hero card: the reference's corner
/// buttons.
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.onTap,
    required this.label,
  });

  final String icon;
  final VoidCallback onTap;

  /// What this control does, for a screen reader and for a long press.
  ///
  /// REQUIRED, NOT OPTIONAL (UI review #31). An unlabelled icon button is
  /// announced as "button" and nothing else, so a floating pencil over a
  /// profile is unreadable to anyone using TalkBack or VoiceOver — and
  /// ambiguous to everyone else, since a pencil on this screen could
  /// plausibly edit the name, the photo or the whole profile. Making it a
  /// required parameter means a second control cannot be added without
  /// one.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(message: label, child: _buildControl()),
    );
  }

  // Drawn at 34 with a 15-point glyph, the size of the app's other small
  // corner tiles; at 44 and 19 it read as a primary button sitting in the
  // corner of the card. The TAP area stays 44 — the minimum comfortable
  // touch target — by centring the smaller circle in a 44 box.
  Widget _buildControl() {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(width: 44, height: 44, child: Center(child: _circle())),
    );
  }

  Widget _circle() {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.card,
        border: Border.all(color: AppPalette.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppPalette.isLight ? 0.06 : 0.3,
            ),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: AppIcon(icon, size: 15, color: AppPalette.textPrimary),
    );
  }
}
