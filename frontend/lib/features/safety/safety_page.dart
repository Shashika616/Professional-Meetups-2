import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

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
/// The trust level trusted contacts and SOS require (ADR-003) — the same
/// floor as joining a meetup. Mirrors the backend's safetyFeatureTrustFloor;
/// the server is what enforces it, this is here so the UI can explain the
/// lock instead of letting the call fail.
const safetyFeatureTrustLevel = 2;

class _SafetyPageState extends ConsumerState<SafetyPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required by the mixin — see [_HomePageState] for the full reasoning.
    super.build(context);

    // Watched, not read at tap time: authSessionProvider is an AsyncNotifier,
    // and a tap-time read on a provider nothing is watching yet returns
    // AsyncLoading — which would read as Level 0 and lock out a verified
    // user. Same shape meetup_detail_page.dart uses.
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    final checklist = [
      'Meet in a public place',
      'Tell a trusted contact where you are going',
      'Keep first meetings short',
      'Never share OTP codes',
      'Never send money',
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      // extendBodyBehindAppBar so AppBackground paints the app-bar strip
      // too — without it the (transparent) bar shows through to nothing and
      // sits as a flat band above the image. Same shape as
      // verification_checklist_page.dart's Scaffold.
      //
      // Safe to add even though this is also an AppShell tab, where the
      // shell already paints one: AppBackground detects an enclosing
      // instance and returns its child untouched, so the nested case costs
      // nothing. It only actually paints on the pushed route from Profile,
      // which is where the background was missing.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('SAFETY CENTER')),
      body: AppBackground(
        // SafeArea is not optional alongside extendBodyBehindAppBar: the
        // flag makes the body start at y=0, under the bar and the status
        // bar. The bar's height is folded into MediaQuery's top padding, so
        // this is what puts the content back below it — without it the
        // checklist drew over the clock and the title.
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('PRE MEETUP CHECKLIST'),
                const SizedBox(height: 12),
                // One scrolling column rather than a ListView of checklist
                // items alone: the trusted-contacts section below has to share
                // this space, and pinning SOS at the bottom means everything
                // above it needs somewhere to go on a short screen.
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final item in checklist)
                        Padding(
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
                                    item,
                                    style: TextStyle(
                                      color: AppPalette.textPrimary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                      const SectionLabel('TRUSTED CONTACTS'),
                      const SizedBox(height: 12),
                      _TrustedContactsSection(trustLevel: trustLevel),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => _onSosTapped(context, ref, trustLevel),
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
        ),
      ),
    );
  }

  /// Real SOS entry point (ADR-026, replacing the old canned-toast
  /// confirm). Checks trusted contacts first — zero contacts routes to the
  /// manage-contacts screen instead of ever showing the confirm dialog, so
  /// CONFIRM can never silently "succeed" with nobody to notify.
  Future<void> _onSosTapped(
    BuildContext context,
    WidgetRef ref,
    int trustLevel,
  ) async {
    // ADR-003. This one check covers both safety actions: the SOS trigger
    // below, and the add-a-contact screen this method routes to when the
    // caller has none. UX only — the server gate is what is enforced.
    if (trustLevel < safetyFeatureTrustLevel) {
      _routeToSafetyUnlock(context);
      return;
    }

    final List<TrustedContact> contacts;
    try {
      contacts = await ref.read(authServiceProvider).listTrustedContacts();
    } on ForbiddenActionException {
      // The client check above passed but the server refused — a cached
      // profile that is behind the real trust level. Same destination
      // rather than a raw error toast, so a stale read is indistinguishable
      // from a fresh one to the user.
      if (context.mounted) _routeToSafetyUnlock(context);
      return;
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

  /// The locked-tap treatment, identical in shape to meetup_card.dart's
  /// `_handleLockedTap` — a toast saying what is locked and why, then the
  /// checklist that unlocks it. Never a dead button or a raw error.
  static void _routeToSafetyUnlock(BuildContext context) {
    showSnack(
      context,
      'Trusted contacts and SOS require Level $safetyFeatureTrustLevel '
      'trust. Verify your phone, personal email, and details to unlock them.',
      type: ToastType.locked,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VerificationChecklistPage(
          title: 'UNLOCK SAFETY FEATURES',
          description:
              'Complete these to reach Level 2 trust and unlock trusted '
              'contacts and SOS.',
        ),
      ),
    );
  }
}

/// Who would be alerted, and the way to add more of them.
///
/// # WHY THIS EXISTS
///
/// Adding a trusted contact was reachable from exactly one place: the SOS
/// button, and only when the caller had ZERO contacts. The moment someone
/// added their first, the manage screen became unreachable — so the cap of
/// three was real but only the first slot was usable. This makes the list
/// visible and the remaining slots reachable, and says what the cap is
/// rather than leaving it to be discovered by hitting it.
///
/// Below Level 2 (ADR-003) it shows the locked treatment instead and never
/// fetches: the contacts belong to a feature the caller cannot use yet, and
/// asking the server for a list it would refuse to add to is a round trip
/// for nothing.
class _TrustedContactsSection extends ConsumerWidget {
  const _TrustedContactsSection({required this.trustLevel});

  final int trustLevel;

  Future<void> _openManage(BuildContext context, WidgetRef ref) async {
    if (trustLevel < safetyFeatureTrustLevel) {
      _SafetyPageState._routeToSafetyUnlock(context);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => const ManageTrustedContactsPage(),
      ),
    );
    // The manage screen adds and removes; this list has to reflect that on
    // the way back.
    ref.invalidate(trustedContactsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (trustLevel < safetyFeatureTrustLevel) {
      return _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: [
          _ContactsHint(
            icon: Icons.lock_outline_rounded,
            text:
                'Verify your account to add the people we should alert in an '
                'emergency.',
          ),
        ],
      );
    }

    final contactsAsync = ref.watch(trustedContactsProvider);
    return contactsAsync.when(
      // Neither a skeleton nor an error state here: this is supporting
      // detail under a checklist, and the section collapsing to a spinner
      // or a red message would be louder than the thing it supports.
      loading: () => _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: [
          _ContactsHint(
            icon: Icons.people_outline_rounded,
            text: 'Loading your trusted contacts…',
          ),
        ],
      ),
      error: (_, _) => _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: [
          _ContactsHint(
            icon: Icons.people_outline_rounded,
            text: 'Tap to manage your trusted contacts.',
          ),
        ],
      ),
      data: (contacts) {
        final remaining = maxTrustedContacts - contacts.length;
        return _ContactsCard(
          onTap: () => _openManage(context, ref),
          children: [
            if (contacts.isEmpty)
              _ContactsHint(
                icon: Icons.person_add_alt_1_rounded,
                text:
                    'No one yet. Add someone we should alert if you trigger '
                    'SOS.',
              )
            else
              for (final contact in contacts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_outline_rounded,
                        size: 17,
                        color: AppPalette.candyBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              contact.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_contactDetail(contact).isNotEmpty)
                              Text(
                                _contactDetail(contact),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppPalette.textSecondary,
                                  fontSize: 11.5,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            Divider(height: 18, color: AppPalette.hairline),
            Row(
              children: [
                Icon(
                  remaining > 0
                      ? Icons.add_circle_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 18,
                  color: remaining > 0
                      ? AppPalette.candyBlue
                      : AppPalette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // States the cap either way, so it is known before it is
                    // hit rather than discovered by being refused.
                    remaining > 0
                        ? 'Add a contact · ${contacts.length} of '
                              '$maxTrustedContacts added'
                        : 'All $maxTrustedContacts contacts added · tap to '
                              'manage',
                    style: TextStyle(
                      color: remaining > 0
                          ? AppPalette.textPrimary
                          : AppPalette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppPalette.textSecondary,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Phone or email, whichever the contact actually has — at least one is
/// guaranteed server-side, both is allowed.
String _contactDetail(TrustedContact contact) {
  if (contact.phoneNumber.isNotEmpty) return contact.phoneNumber;
  return contact.email;
}

class _ContactsCard extends StatelessWidget {
  const _ContactsCard({required this.onTap, required this.children});

  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // opaque so the whole card is the target, not just the painted rows.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _ContactsHint extends StatelessWidget {
  const _ContactsHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: AppPalette.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
          ),
        ),
      ],
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
    } on SessionExpiredException {
      // SessionExpiredException is an AuthException, so without this clause
      // first it fell into the one below and showed "failed" with a message
      // the user could only retry — on a session that is already gone.
      if (mounted) {
        widget.ref.read(authSessionProvider.notifier).forceSignOut();
      }
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
