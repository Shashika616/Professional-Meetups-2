import 'package:flutter/widgets.dart';

/// Lays [child] out to fill the screen, and scrolls it when it cannot fit.
///
/// For pages built as a Column with Spacers. At the largest text sizes the
/// content is taller than the screen, and without this the buttons at the
/// bottom would be out of reach.
class FillScrollView extends StatelessWidget {
  const FillScrollView({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
          ),
        ),
      ),
    );
  }
}
