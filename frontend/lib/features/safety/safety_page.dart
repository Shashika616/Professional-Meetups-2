import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';

/// Emergency phone number dialed by "Call emergency services" — Sri Lanka's
/// general emergency line (the launch market, see `docs/00-project/
/// vision.md`; no country picker anywhere else in this app either, same
/// reasoning as `PhoneVerificationPage`'s fixed `+94` prefix).
const String _emergencyServicesNumber = '119';

class SafetyPage extends ConsumerStatefulWidget {
  const SafetyPage({super.key});

  @override
  ConsumerState<SafetyPage> createState() => _SafetyPageState();
}

/// # WHY THIS STATE IS KEPT ALIVE
///
/// Same reason as the other three tabs: AppShell's `PageView` disposes the
/// tab you swipe away from, and remounting re-runs everything the page reads.
/// This page has no network fetch of its own, so it never showed the grey
/// skeleton — but it does hold scroll position and the trusted-contacts
/// sheet's state, and a tab that silently jumps back to the top when you
/// return is the same class of bug with a quieter symptom.
///
/// Kept consistent with its three siblings deliberately: one tab behaving
/// differently from the rest is worse than the small cost of holding a
/// stateless-ish page alive.
class _SafetyPageState extends ConsumerState<SafetyPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required by the mixin — see [_HomePageState] for the full reasoning.
    super.build(context);

    final checklist = [
      'Meet in a public place',
      'Tell a trusted contact where you are going',
      'Keep first meetings short',
      'Never share OTP codes',
      'Never send money',
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('SAFETY CENTER')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('PRE MEETUP CHECKLIST'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: checklist.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FlatCard(
                      radius: 12,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 18,
                            color: AppPalette.verified,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              checklist[index],
                              style: TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _onSosTapped(context, ref),
              child: FlatCard(
                radius: 12,
                tint: AppPalette.danger.withValues(alpha: 0.12),
                border: AppPalette.danger.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.emergency_share,
                      color: AppPalette.danger,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'TRIGGER SOS',
                      style: TextStyle(
                        color: AppPalette.danger,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.4,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Was `80 + MediaQuery.padding.bottom` to clear AppShell's old
            // floating bar, which the body drew underneath via
            // extendBody: true. Both are gone (ADR-032 round 2) — the
            // Scaffold now lays this body out above a flush, pinned
            // AppBottomBar, so any clearance here would just be dead space
            // at the end of the scroll. Kept as ordinary bottom breathing
            // room only.
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Real SOS entry point (ADR-026, replacing the old canned-toast
  /// confirm). Checks trusted contacts first — zero contacts routes to the
  /// manage-contacts screen instead of ever showing the confirm dialog, so
  /// CONFIRM can never silently "succeed" with nobody to notify.
  Future<void> _onSosTapped(BuildContext context, WidgetRef ref) async {
    final List<TrustedContact> contacts;
    try {
      contacts = await ref.read(authServiceProvider).listTrustedContacts();
    } on AuthException catch (error) {
      if (context.mounted) {
        showSnack(context, error.message, type: ToastType.error);
      }
      return;
    }
    if (!context.mounted) return;

    if (contacts.isEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) =>
              const ManageTrustedContactsPage(explainSosPrompt: true),
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _SosConfirmDialog(ref: ref),
    );
  }
}

/// The SOS confirm dialog — extracted as its own widget (rather than an
/// inline `AlertDialog` like the old fake version) because it now needs its
/// own mutable state: CONFIRM triggers a real, multi-step async flow
/// (fresh location read → triggerSos call) with a loading state and a real
/// result to show, not an instant `Navigator.pop`.
class _SosConfirmDialog extends StatefulWidget {
  const _SosConfirmDialog({required this.ref});

  final WidgetRef ref;

  @override
  State<_SosConfirmDialog> createState() => _SosConfirmDialogState();
}

enum _SosDialogPhase { confirming, sending, succeeded, failed }

class _SosConfirmDialogState extends State<_SosConfirmDialog> {
  _SosDialogPhase _phase = _SosDialogPhase.confirming;
  String _resultMessage = '';

  Future<void> _confirm() async {
    setState(() => _phase = _SosDialogPhase.sending);
    try {
      final position = await requestCurrentLocation();
      final contactsNotified = await widget.ref
          .read(authServiceProvider)
          .triggerSos(
            contextMessage: 'Triggered from the Safety Center.',
            latitude: position.latitude,
            longitude: position.longitude,
          );
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.succeeded;
        _resultMessage = contactsNotified == 1
            ? '1 trusted contact was alerted.'
            : '$contactsNotified trusted contacts were alerted.';
      });
    } on LocationUnavailableException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.failed;
        _resultMessage = error.message;
      });
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.failed;
        _resultMessage = error.message;
      });
    }
  }

  Future<void> _callEmergencyServices() async {
    await launchUrl(Uri(scheme: 'tel', path: _emergencyServicesNumber));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'EMERGENCY SOS',
        style: TextStyle(
          color: AppPalette.danger,
          letterSpacing: 1.6,
          fontSize: 15,
        ),
      ),
      content: _buildContent(),
      actions: _buildActions(context),
    );
  }

  Widget _buildContent() {
    switch (_phase) {
      case _SosDialogPhase.confirming:
        return Text(
          'This will share your live location with your trusted contacts.',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        );
      case _SosDialogPhase.sending:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppPalette.danger,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Getting your location and alerting your contacts…',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
            ),
          ],
        );
      case _SosDialogPhase.succeeded:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: AppPalette.verified, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _resultMessage,
                style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
              ),
            ),
          ],
        );
      case _SosDialogPhase.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: AppPalette.danger, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _resultMessage,
                style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
              ),
            ),
          ],
        );
    }
  }

  List<Widget> _buildActions(BuildContext context) {
    // "Call emergency services" is available in every phase — it works
    // independent of whether triggerSos succeeds or fails, and has no
    // backend dependency at all (ADR-026 §6).
    final callAction = TextButton(
      onPressed: _callEmergencyServices,
      child: Text(
        'CALL EMERGENCY SERVICES',
        style: TextStyle(color: AppPalette.danger, fontWeight: FontWeight.w700),
      ),
    );

    switch (_phase) {
      case _SosDialogPhase.confirming:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'CANCEL',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
          callAction,
          TextButton(
            onPressed: _confirm,
            child: Text(
              'CONFIRM',
              style: TextStyle(
                color: AppPalette.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ];
      case _SosDialogPhase.sending:
        return [callAction];
      case _SosDialogPhase.succeeded:
      case _SosDialogPhase.failed:
        return [
          callAction,
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'CLOSE',
              style: TextStyle(color: AppPalette.textPrimary),
            ),
          ),
        ];
    }
  }
}
