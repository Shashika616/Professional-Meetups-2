import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The app's one modal presentation: a sheet that rises from the bottom
/// edge, with a grab handle and a rounded top.
///
/// # WHY EVERYTHING MODAL COMES FROM THE BOTTOM NOW
///
/// The join flow already worked this way — I'M INTERESTED raises a sheet
/// showing who is hosting before anything is sent — while the safety
/// actions (ADD CONTACT, the SOS confirmation) faded in as centred
/// `AlertDialog`s. Two different arrival animations for the same kind of
/// moment, which is one too many: a modal that slides up from the edge you
/// touched reads as an extension of the thing you tapped, and a dialog that
/// fades in over the middle reads as an interruption. The app asks for a
/// decision in both cases, so it should ask the same way.
///
/// It also puts the decision where the thumb already is, which matters most
/// for exactly the case that is hardest: confirming an emergency SOS.
///
/// The options here are the ones `showJoinConfirmationSheet` already chose
/// (card background, 22pt top radius, scroll-controlled, safe-area aware) —
/// this is that presentation extracted, not a new one invented alongside it.
/// # ONE TAP, ONE SHEET
///
/// A second tap landing before the first sheet has finished rising used to
/// push a second copy of it. Two identical sheets then had to be dismissed
/// one after the other, and on anything that acts on open — the SOS
/// confirmation, a rating — the user was answering a question they had
/// already answered. Flutter does not dedupe this; nothing in the app did
/// either, at any of the twenty-odd call sites.
///
/// The guard lives here rather than at those call sites because it is the
/// same guard every time, and a rule kept in twenty places is a rule that
/// is wrong in at least one of them.
///
/// It reads the CALLER's route: pushing a sheet makes that route stop being
/// the current one, so "my route is no longer on top" means a sheet (or a
/// pushed page) is already covering this caller, and a tap that arrives now
/// is one the user cannot have meant. A sheet opened from inside another
/// sheet still works — there the caller's route IS the open sheet, which is
/// current.
///
/// Returns null when it declines, which every call site already handles:
/// null is what a dismissed sheet returns.
///
/// [minHeightFactor] opens the sheet at least that fraction of the screen
/// tall instead of sizing to its content. A sheet you are going to WORK in
/// — rate someone, pick from a long list — reads as a screen and should
/// arrive as one; the ride-hailing apps' rating sheets all do this. A
/// sheet that just asks one question still sizes to its content, which is
/// why this is opt-in rather than the default.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
  double? minHeightFactor,
}) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return Future<T?>.value(null);
  final WidgetBuilder wrapped = minHeightFactor == null
      ? builder
      : (ctx) => ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.sizeOf(ctx).height * minHeightFactor,
          ),
          child: builder(ctx),
        );
  return showModalBottomSheet<T>(
    context: context,
    // Both: the sheet sizes to its content, and it can grow past half the
    // screen when a keyboard is up or the content is long.
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    backgroundColor: AppPalette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: wrapped,
  );
}

/// The inside of a [showAppSheet]: grab handle, title, then the caller's
/// content, with the insets a bottom sheet has to handle itself.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.title,
    required this.child,
    this.titleColor,
  });

  final String title;
  final Widget child;

  /// Overrides the title ink — the SOS sheet titles itself in
  /// [AppPalette.danger], the way its dialog did.
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        // Two separate insets, both needed: viewInsets is the keyboard
        // (the add-contact form has three fields, and without this the
        // SAVE button sits under it), viewPadding is the home indicator or
        // the three-button navigation bar. useSafeArea covers the top only.
        16 +
            MediaQuery.viewInsetsOf(context).bottom +
            MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppPalette.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              color: titleColor ?? AppPalette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          Flexible(child: SingleChildScrollView(child: child)),
        ],
      ),
    );
  }
}
