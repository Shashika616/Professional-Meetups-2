import 'package:flutter/material.dart';

import 'package:professional_connections_platform/features/legal/legal_document_page.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The 18+ self-attestation control: a checkbox and its exact sentence.
///
/// One widget, two homes. Sign-up shows it on its own full-screen
/// [AgeConfirmationStep] before any method is offered; sign-in shows it
/// inline above the provider buttons, because a provider tap there is
/// resolve-or-create and can create a brand-new account (Plan 18, Fix 2).
/// Both paths record the same attestation server-side, so both must show
/// the same words and the same control, not two drifting copies.
///
/// No date of birth is collected or stored anywhere: a checkbox only.
class AgeConfirmationCheckbox extends StatelessWidget {
  const AgeConfirmationCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// The one sentence the user is agreeing to. Public so tests assert on
  /// the same string both screens render.
  static const String statement = 'I confirm I am 18 years of age or older.';

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [_checkbox(), const SizedBox(height: 6), const _LegalLinks()],
    );
  }

  Widget _checkbox() {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            onChanged: (checked) => onChanged(checked ?? false),
            activeColor: AppPalette.candyBlue,
            checkColor: AppPalette.onyx,
            side: BorderSide(
              color: AppPalette.textSecondary.withValues(alpha: 0.6),
            ),
          ),
          Flexible(
            child: Text(
              statement,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Readable before signing up, as the stores expect.
class _LegalLinks extends StatelessWidget {
  const _LegalLinks();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: AppPalette.candyBlue,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      children: [
        for (final document in LegalDocument.values)
          GestureDetector(
            onTap: () => openLegalDocument(context, document),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(document.title, style: style),
            ),
          ),
      ],
    );
  }
}
