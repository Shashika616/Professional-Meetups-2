import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';

const int maxTrustedContacts = 3;

/// Add/list/remove trusted contacts (ADR-026, `frontend/sos-trusted-
/// contacts-PLAN.md` Step 2) — reachable from `ProfilePage`'s Safety
/// Center row, and directly from `SafetyPage`'s SOS button when the caller
/// has zero contacts registered.
///
/// [explainSosPrompt] shows a one-line banner explaining why this screen
/// opened instead of the usual SOS confirm dialog — set only by that
/// zero-contacts redirect, not the normal Safety Center entry point.
class ManageTrustedContactsPage extends ConsumerStatefulWidget {
  const ManageTrustedContactsPage({super.key, this.explainSosPrompt = false});

  final bool explainSosPrompt;

  @override
  ConsumerState<ManageTrustedContactsPage> createState() =>
      _ManageTrustedContactsPageState();
}

class _ManageTrustedContactsPageState
    extends ConsumerState<ManageTrustedContactsPage> {
  @override
  Widget build(BuildContext context) {
    final contactsAsync = ref.watch(trustedContactsProvider);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('TRUSTED CONTACTS')),
        // SafeArea (bottom only — the AppBar already consumes the top
        // inset) so ADD CONTACT never sits under the home-indicator strip.
        // Unlike SafetyPage, this page is reached via Navigator.push and so
        // has no AppBottomBar reserving space beneath it; the old bare
        // 24px bottom padding was all that separated the button from the
        // device edge, which read as cramped rather than deliberate.
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.explainSosPrompt) ...[
                  FlatCard(
                    radius: 12,
                    tint: AppPalette.danger.withValues(alpha: 0.1),
                    border: AppPalette.danger.withValues(alpha: 0.4),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 18,
                          color: AppPalette.danger,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Add at least one trusted contact before you can '
                            'use SOS.',
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Expanded(
                  child: contactsAsync.when(
                    loading: () => const _ContactsSkeleton(),
                    error: (error, stack) => _ErrorState(
                      onRetry: () => ref.invalidate(trustedContactsProvider),
                    ),
                    data: (contacts) => _ContactsList(
                      contacts: contacts,
                      onRemove: _removeContact,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Always shown now (subject to the same maxTrustedContacts
                // disabled-state logic as before) — the form used to replace
                // this button inline, in this same Column, which read as the
                // form growing up from the bottom rather than as a modal.
                PrimaryButton(
                  label: 'ADD CONTACT',
                  icon: Icons.person_add_alt_1_rounded,
                  onPressed:
                      contactsAsync.maybeWhen(
                            data: (contacts) => contacts.length,
                            orElse: () => 0,
                          ) <
                          maxTrustedContacts
                      ? _showAddContactDialog
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Presents [_AddContactForm] as a centered modal, matching the dialog
  /// style already used by `safety_page.dart`'s `_SosConfirmDialog` and
  /// this file's own remove-contact confirmation (AppPalette.card
  /// background, 20px rounded corners) rather than inventing a new one.
  Future<void> _showAddContactDialog() {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AddContactForm(
        onCancel: () => Navigator.pop(dialogContext),
        onSaved: () {
          Navigator.pop(dialogContext);
          ref.invalidate(trustedContactsProvider);
        },
      ),
    );
  }

  Future<void> _removeContact(TrustedContact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'REMOVE CONTACT',
          style: TextStyle(color: AppPalette.textPrimary, letterSpacing: 1.2),
        ),
        content: Text(
          'Remove ${contact.name} from your trusted contacts?',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'CANCEL',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'REMOVE',
              style: TextStyle(
                color: AppPalette.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(authServiceProvider).removeTrustedContact(contact.id);
      ref.invalidate(trustedContactsProvider);
      if (mounted) {
        showSnack(context, 'Contact removed.', type: ToastType.success);
      }
    } on AuthException catch (error) {
      if (mounted) showSnack(context, error.message, type: ToastType.error);
    }
  }
}

class _ContactsList extends StatelessWidget {
  const _ContactsList({required this.contacts, required this.onRemove});

  final List<TrustedContact> contacts;
  final void Function(TrustedContact contact) onRemove;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      return Center(
        child: Text(
          'No trusted contacts yet.\nAdd someone who should be alerted if '
          'you trigger SOS.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      itemCount: contacts.length,
      itemBuilder: (context, index) {
        final contact = contacts[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FlatCard(
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.person_outline_rounded,
                  size: 18,
                  color: AppPalette.candyBlue,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contact.name,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (contact.phoneNumber.isNotEmpty)
                        Text(
                          contact.phoneNumber,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      if (contact.email.isNotEmpty)
                        Text(
                          contact.email,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: AppPalette.danger,
                    size: 20,
                  ),
                  onPressed: () => onRemove(contact),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AddContactForm extends ConsumerStatefulWidget {
  const _AddContactForm({required this.onCancel, required this.onSaved});

  final VoidCallback onCancel;
  final VoidCallback onSaved;

  @override
  ConsumerState<_AddContactForm> createState() => _AddContactFormState();
}

class _AddContactFormState extends ConsumerState<_AddContactForm> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // GlassTextField doesn't expose onChanged — listening on each
    // controller directly is what makes SAVE react as the user types (same
    // pattern as the verification pages' own `_onFieldChanged`).
    _nameController.addListener(_onFieldChanged);
    _phoneController.addListener(_onFieldChanged);
    _emailController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _nameController.removeListener(_onFieldChanged);
    _phoneController.removeListener(_onFieldChanged);
    _emailController.removeListener(_onFieldChanged);
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_nameController.text.trim().isEmpty) return false;
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    if (phone.isEmpty && email.isEmpty) return false;
    if (phone.isNotEmpty && Validators.phone(phone) != null) return false;
    if (email.isNotEmpty && Validators.email(email) != null) return false;
    return true;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .addTrustedContact(
            name: _nameController.text.trim(),
            phoneNumber: _phoneController.text.trim(),
            email: _emailController.text.trim(),
          );
      widget.onSaved();
    } on AuthException catch (error) {
      // The await above can outlive this dialog — the `finally` below has
      // always guarded for that; this branch did not.
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // AlertDialog, not the FlatCard this used to be wrapped in — a single
    // wrapper, styled to match _SosConfirmDialog and the remove-contact
    // confirmation (AppPalette.card, 20px radius). Everything below the
    // wrapper (fields, validation, save/loading, error display) is
    // unchanged. SingleChildScrollView + MainAxisSize.min keep the form
    // usable when the keyboard shrinks the available height, which the
    // old bounded inline card didn't have to worry about.
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'ADD CONTACT',
        style: TextStyle(
          color: AppPalette.textPrimary,
          letterSpacing: 1.2,
          fontSize: 15,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassTextField(
              controller: _nameController,
              icon: Icons.badge_outlined,
              hint: 'Name',
            ),
            const SizedBox(height: 10),
            GlassTextField(
              controller: _phoneController,
              icon: Icons.phone_iphone_rounded,
              hint: 'Phone number (optional)',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 10),
            GlassTextField(
              controller: _emailController,
              icon: Icons.email_outlined,
              hint: 'Email (optional)',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 6),
            Text(
              'At least one of phone or email is required.',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 11),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: AppPalette.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: 'CANCEL',
                    onPressed: _saving ? null : widget.onCancel,
                    height: 48,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'SAVE',
                    height: 48,
                    isLoading: _saving,
                    onPressed: (_canSave && !_saving) ? _save : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactsSkeleton extends StatelessWidget {
  const _ContactsSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return Column(
      children: List.generate(
        3,
        (index) => const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: SkeletonBox(width: double.infinity, height: 64, radius: 16),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_outlined,
              color: AppPalette.textSecondary,
              size: 28,
            ),
            const SizedBox(height: 10),
            Text(
              'Could not load your trusted contacts.',
              style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            SecondaryButton(label: 'RETRY', onPressed: onRetry, height: 40),
          ],
        ),
      ),
    );
  }
}
