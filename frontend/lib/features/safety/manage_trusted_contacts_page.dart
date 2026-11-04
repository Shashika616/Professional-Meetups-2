import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/widgets/secure_screen.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_dialog.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/app_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';

const int maxTrustedContacts = 2;

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
  // Kept out of screenshots, recordings and the app switcher (#94):
  // the people a user relies on in an emergency, with their numbers.
  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: _buildSecured(context));

  Widget _buildSecured(BuildContext context) {
    final contactsAsync = ref.watch(trustedContactsProvider);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Trusted contacts')),
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
                    radius: 18,
                    tint: AppPalette.danger.withValues(alpha: 0.1),
                    border: AppPalette.danger.withValues(alpha: 0.4),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        AppIcon(
                          AppIcons.info,
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
                if (contactsAsync.maybeWhen(
                  data: (contacts) => contacts.length > maxTrustedContacts,
                  orElse: () => false,
                )) ...[
                  FlatCard(
                    radius: 18,
                    tint: AppPalette.danger.withValues(alpha: 0.1),
                    border: AppPalette.danger.withValues(alpha: 0.4),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        AppIcon(
                          AppIcons.info,
                          size: 18,
                          color: AppPalette.danger,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Only two contacts are alerted. Remove one.',
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
                    error: (error, stack) => SkeletonThenFailure(
                      skeleton: const _ContactsSkeleton(),
                      failure: ListView(
                        children: [
                          LoadFailedState(
                            compact: true,
                            failure: LoadFailure.of(error),
                            onRetry: () =>
                                ref.invalidate(trustedContactsProvider),
                          ),
                        ],
                      ),
                    ),
                    data: (contacts) => _ContactsList(
                      contacts: contacts,
                      onEdit: _showEditContactSheet,
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
                  label: 'Add contact',
                  icon: AppIcons.personAdd,
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

  /// Presents [_AddContactForm] as a bottom sheet — the app's one modal
  /// presentation (`showAppSheet`), the same arrival the join flow's
  /// "who is hosting" sheet uses. It was a centred dialog; a form with
  /// fields belongs near the keyboard that is about to cover half the
  /// screen, not floating in the middle of it.
  Future<void> _showAddContactDialog() {
    track(Cta.addTrustedContact);
    return _showContactSheet();
  }

  Future<void> _showEditContactSheet(TrustedContact contact) =>
      _showContactSheet(existing: contact);

  Future<void> _showContactSheet({TrustedContact? existing}) {
    return showAppSheet<void>(
      context,
      builder: (dialogContext) => _ContactForm(
        existing: existing,
        onCancel: () => Navigator.pop(dialogContext),
        onSaved: () {
          Navigator.pop(dialogContext);
          ref.invalidate(trustedContactsProvider);
        },
      ),
    );
  }

  Future<void> _removeContact(TrustedContact contact) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove contact?',
      message: '${contact.name} will no longer be alerted if you trigger SOS.',
      confirmLabel: 'Remove contact',
      cancelLabel: 'Cancel',
      danger: true,
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
  const _ContactsList({
    required this.contacts,
    required this.onEdit,
    required this.onRemove,
  });

  final List<TrustedContact> contacts;
  final void Function(TrustedContact contact) onEdit;
  final void Function(TrustedContact contact) onRemove;

  @override
  Widget build(BuildContext context) {
    if (contacts.isEmpty) {
      // Centred in whatever space the list had, and still scrollable so a
      // short screen can reach all of it.
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: const Center(
              child: EmptyStateDeck(
                title: 'Nobody on your list yet',
                message:
                    'Add someone who should hear from us if you trigger SOS: '
                    'the people you would call anyway.',
                scenes: EmptyDeckScenes.people,
              ),
            ),
          ),
        ),
      );
    }
    // One card, one row per contact — the shape the Safety tab already
    // shows these in. A card each made the same three people look like
    // three unrelated objects on one screen and one list on the other.
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '${contacts.length} of $maxTrustedContacts added',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
        ),
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            children: [
              for (final contact in contacts) ...[
                if (contact != contacts.first)
                  Divider(height: 1, color: AppPalette.hairline),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      AppIcon(
                        AppIcons.person,
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
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit ${contact.name}',
                        icon: AppIcon(
                          AppIcons.edit,
                          color: AppPalette.textSecondary,
                          size: 20,
                        ),
                        onPressed: () => onEdit(contact),
                      ),
                      IconButton(
                        tooltip: 'Remove ${contact.name}',
                        icon: AppIcon(
                          AppIcons.trash,
                          color: AppPalette.danger,
                          size: 20,
                        ),
                        onPressed: () => onRemove(contact),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ContactForm extends ConsumerStatefulWidget {
  const _ContactForm({
    required this.onCancel,
    required this.onSaved,
    this.existing,
  });

  final VoidCallback onCancel;
  final VoidCallback onSaved;

  /// The contact being edited; null when adding one.
  final TrustedContact? existing;

  @override
  ConsumerState<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends ConsumerState<_ContactForm> {
  late final _nameController = TextEditingController(
    text: widget.existing?.name,
  );
  late final _phoneController = TextEditingController(
    text: widget.existing?.phoneNumber,
  );
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // AppTextField doesn't expose onChanged — listening on each
    // controller directly is what makes SAVE react as the user types (same
    // pattern as the verification pages' own `_onFieldChanged`).
    _nameController.addListener(_onFieldChanged);
    _phoneController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _nameController.removeListener(_onFieldChanged);
    _phoneController.removeListener(_onFieldChanged);
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  bool get _canSave {
    final name = _nameController.text.trim();
    if (name.isEmpty || name.length > 60) return false;
    return Validators.phone(_phoneController.text.trim()) == null;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      final name = _nameController.text.trim();
      final phoneNumber = _phoneController.text.trim();
      final existing = widget.existing;
      if (existing == null) {
        await auth.addTrustedContact(name: name, phoneNumber: phoneNumber);
      } else {
        await auth.updateTrustedContact(
          existing.id,
          name: name,
          phoneNumber: phoneNumber,
        );
      }
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
    // AppSheet, not an AlertDialog: the shell owns the handle, the title
    // and the keyboard/home-indicator insets, so everything below here
    // (fields, validation, save/loading, error display) is exactly what it
    // was — only where it arrives from changed.
    return AppSheet(
      title: widget.existing == null ? 'Add contact' : 'Edit contact',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            controller: _nameController,
            icon: AppIcons.idCard,
            hint: 'Name',
          ),
          const SizedBox(height: 10),
          AppTextField(
            controller: _phoneController,
            icon: AppIcons.phone,
            hint: 'Phone number',
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 6),
          Text(
            'We won\'t message them now. They get a text only if you press '
            'SOS.',
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
                  label: 'Cancel',
                  onPressed: _saving ? null : widget.onCancel,
                  height: 48,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'Save',
                  height: 48,
                  isLoading: _saving,
                  onPressed: (_canSave && !_saving) ? _save : null,
                ),
              ),
            ],
          ),
        ],
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
        2,
        (index) => const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: SkeletonBox(width: double.infinity, height: 64, radius: 16),
        ),
      ),
    );
  }
}
