import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The standard one-box-per-digit code entry.
///
/// # WHY ONE HIDDEN FIELD AND NOT N REAL ONES
///
/// The obvious build is one `TextField` per box with focus hopping between
/// them. It is also the one that breaks in every interesting case: backspace
/// on an empty box has to be special-cased, pasting a six-digit code fills
/// only the first box, and — the one that matters most here — the OS cannot
/// autofill an SMS code into six separate fields.
///
/// So there is exactly ONE real field. It is transparent and sits under the
/// boxes; the boxes are just painted from its text. Paste, backspace,
/// selection and `AutofillHints.oneTimeCode` all work because they are
/// working on a normal text field.
///
/// # IT DRIVES THE CALLER'S OWN CONTROLLER
///
/// [controller] is the caller's, unchanged — this widget owns no code state.
/// That is what let it replace a plain single-line field without touching
/// the submit, enable-button or clear-on-error logic around it.
class OtpBoxField extends StatefulWidget {
  const OtpBoxField({
    super.key,
    required this.controller,
    this.length = 6,
    this.autofocus = true,
  });

  final TextEditingController controller;
  final int length;
  final bool autofocus;

  @override
  State<OtpBoxField> createState() => _OtpBoxFieldState();
}

class _OtpBoxFieldState extends State<OtpBoxField> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _focusNode.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _focusNode
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  // Repaints the boxes as digits arrive and as focus moves.
  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final focused = _focusNode.hasFocus;

    return GestureDetector(
      // The boxes are decoration; tapping any of them means "type here".
      onTap: () => _focusNode.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < widget.length; i++)
                _Box(
                  digit: i < text.length ? text[i] : '',
                  // The "cursor": the box the next digit lands in, shown
                  // only while the field actually has focus, so an
                  // unfocused field does not look like it is waiting.
                  active:
                      focused && i == text.length.clamp(0, widget.length - 1),
                  filled: i < text.length,
                ),
            ],
          ),
          // The real field. Transparent rather than Offstage/zero-sized:
          // an off-screen field loses the OS autofill affordance on iOS,
          // and a zero-height one cannot take a tap.
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                keyboardType: TextInputType.number,
                // The reason the single-field design is worth it: iOS and
                // Android will drop an SMS code straight in.
                autofillHints: const [AutofillHints.oneTimeCode],
                enableInteractiveSelection: false,
                showCursor: false,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(widget.length),
                ],
                style: const TextStyle(color: Colors.transparent),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  counterText: '',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.digit, required this.active, required this.filled});

  final String digit;
  final bool active;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final borderColor = active
        ? AppPalette.candyBlue
        : (filled
              ? AppPalette.candyBlue.withValues(alpha: 0.4)
              : AppPalette.hairline);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      width: 46,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: active ? 2 : 1),
      ),
      child: Text(
        digit,
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
