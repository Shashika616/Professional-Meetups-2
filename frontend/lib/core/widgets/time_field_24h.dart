import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/features/meetups/meetup_window_input.dart';

/// A typed, strict 24-hour `HH:MM` entry: a small-caps label over a large
/// underlined numeric field. Draws no card of its own — the Schedule flow
/// places FROM and TO side by side inside one card. Replaces the dial
/// picker there — see `meetup_window_input.dart` for why.
///
/// The user types digits only; the formatter inserts the colon after the
/// hour and refuses digits that could never form a valid time (a first
/// hour digit of 3+, a second hour digit above 3 when the first is 2, a
/// first minute digit of 6+). So the field can be incomplete but never
/// out of domain, and [onChanged] fires with a [TimeOfDay] exactly when
/// four valid digits are present and with null the moment they are not.
///
/// The TextField carries `ValueKey('time24h-<label>')` so a widget test
/// can address FROM and TO individually without depending on child order.
class TimeField24h extends StatefulWidget {
  const TimeField24h({
    super.key,
    required this.label,
    required this.onChanged,
    this.initialValue,
  });

  /// Small-caps label above the value, e.g. `FROM` / `TO`.
  final String label;

  final TimeOfDay? initialValue;

  /// A parsed time once the entry is complete, null while it is not.
  final ValueChanged<TimeOfDay?> onChanged;

  @override
  State<TimeField24h> createState() => _TimeField24hState();
}

class _TimeField24hState extends State<TimeField24h> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue == null
        ? ''
        : formatTime24h(widget.initialValue!),
  );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() => widget.onChanged(parseTime24h(_controller.text));

  @override
  Widget build(BuildContext context) {
    // Bare label + input: the Schedule flow composes FROM and TO into one
    // card of its own, so this draws no surface, icon or border itself.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
        TextField(
          key: ValueKey('time24h-${widget.label}'),
          controller: _controller,
          keyboardType: TextInputType.number,
          inputFormatters: const [_HhMmInputFormatter()],
          autocorrect: false,
          enableSuggestions: false,
          cursorColor: AppPalette.brandGreen,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            height: 1.15,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.only(top: 2, bottom: 6),
            // The shape of the value, so an empty field already says what
            // it wants; the card beneath names the 24-hour clock outright.
            hintText: 'HH:MM',
            hintStyle: TextStyle(
              color: AppPalette.textSecondary.withValues(alpha: 0.45),
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppPalette.hairline),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppPalette.brandGreen, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// Keeps the field's text to at most four digits rendered as `HH:MM`, and
/// refuses any digit that could not be part of a valid 24-hour time. The
/// caret is always placed at the end: with a fixed-shape value this is
/// the least surprising behaviour, and it keeps the formatter free of
/// selection arithmetic across the inserted colon.
class _HhMmInputFormatter extends TextInputFormatter {
  const _HhMmInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final kept = StringBuffer();
    for (final ch in digits.split('')) {
      if (kept.length == 4) break;
      final d = int.parse(ch);
      final ok = switch (kept.length) {
        0 => d <= 2,
        1 => kept.toString() == '2' ? d <= 3 : true,
        2 => d <= 5,
        _ => true,
      };
      if (!ok) break;
      kept.write(ch);
    }
    final s = kept.toString();
    final text = s.length > 2 ? '${s.substring(0, 2)}:${s.substring(2)}' : s;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
