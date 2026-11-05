import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/legal_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/legal/legal_document_page.dart';

/// Shown in place of the app until the signed-in person agrees to the current
/// terms and privacy policy. They can read both first, or sign out.
class LegalAcceptancePage extends ConsumerStatefulWidget {
  const LegalAcceptancePage({super.key});

  @override
  ConsumerState<LegalAcceptancePage> createState() =>
      _LegalAcceptancePageState();
}

class _LegalAcceptancePageState extends ConsumerState<LegalAcceptancePage> {
  bool _agreed = false;
  bool _saving = false;

  Future<void> _accept() async {
    setState(() => _saving = true);
    try {
      final docs = await ref.read(legalDocumentsProvider.future);
      await ref.read(legalServiceProvider).accept(docs.version);
      ref.invalidate(legalAcceptancePendingProvider);
    } on LegalException catch (error) {
      ref.invalidate(legalDocumentsProvider);
      if (mounted) showSnack(context, error.message, type: ToastType.error);
    } catch (_) {
      if (mounted) {
        showSnack(
          context,
          'We couldn’t save that. Please try again.',
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: AppBackground(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Text(
                    'Our terms',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Please read and agree to these to keep using TieHere.',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final document in LegalDocument.values)
                    _DocumentLink(document: document),
                  const SizedBox(height: 12),
                  GestureDetector(
                    key: const Key('legal-agree'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _saving
                        ? null
                        : () => setState(() => _agreed = !_agreed),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _agreed,
                          onChanged: _saving
                              ? null
                              : (value) =>
                                    setState(() => _agreed = value ?? false),
                          activeColor: AppPalette.candyBlue,
                          checkColor: AppPalette.onyx,
                          side: BorderSide(
                            color: AppPalette.textSecondary.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'I have read and agree to the Terms and Conditions '
                            'and the Privacy Policy.',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(flex: 2),
                  PrimaryButton(
                    label: 'Agree and continue',
                    isLoading: _saving,
                    onPressed: _agreed && !_saving ? _accept : null,
                  ),
                  const SizedBox(height: 10),
                  // The same red as Sign out on Profile.
                  SecondaryButton(
                    label: 'Sign out',
                    icon: AppIcons.signOut,
                    color: AppPalette.danger,
                    fillColor: AppPalette.danger.withValues(alpha: 0.08),
                    borderColor: AppPalette.danger.withValues(alpha: 0.3),
                    onPressed: _saving
                        ? null
                        : () =>
                              ref.read(authSessionProvider.notifier).signOut(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DocumentLink extends StatelessWidget {
  const _DocumentLink({required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => openLegalDocument(context, document),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                document.title,
                style: TextStyle(
                  color: AppPalette.candyBlue,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            AppIcon(
              AppIcons.forward,
              size: 18,
              color: AppPalette.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
