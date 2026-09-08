import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';

/// Picks which of the user's trusted contacts to tell about a meetup.
///
/// # WHY CONTACTS AND NOT THE HOST
///
/// The screen this replaces offered "Share live location" with a switch that
/// wrote a boolean nothing read — it shared with nobody. Rebuilding it, the
/// recipient became the user's own emergency contacts rather than the person
/// they are meeting: telling the other party where you are is not a safety
/// feature, and telling someone outside the meetup is.
///
/// # WHAT IS ACTUALLY SENT
///
/// A text (and/or email) naming the meetup's window and place, with a map
/// pin at its coordinates. Not tracking — the copy here says so plainly,
/// because a safety promise the product cannot keep is worse than no promise.
///
/// Returns the selected contact ids, or null if dismissed.
Future<List<String>?> showShareWithContactsSheet(
  BuildContext context, {
  required Set<String> alreadyShared,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppPalette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _ShareWithContactsSheet(alreadyShared: alreadyShared),
  );
}

class _ShareWithContactsSheet extends ConsumerStatefulWidget {
  const _ShareWithContactsSheet({required this.alreadyShared});

  /// Contacts who already know. Shown as such and pre-excluded from the
  /// selection, so pressing share again does not re-text them.
  final Set<String> alreadyShared;

  @override
  ConsumerState<_ShareWithContactsSheet> createState() =>
      _ShareWithContactsSheetState();
}

class _ShareWithContactsSheetState
    extends ConsumerState<_ShareWithContactsSheet> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final contactsAsync = ref.watch(trustedContactsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppPalette.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tell a trusted contact',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              // Deliberately precise. The old switch implied live tracking
              // and delivered nothing; this says exactly what arrives.
              'They will get a message with the time and place of this '
              'meetup, and a map link. Your location is not tracked.',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            contactsAsync.when(
              loading: () => const SkeletonLoader(
                child: Column(
                  children: [
                    SkeletonBox(width: double.infinity, height: 56, radius: 12),
                    SizedBox(height: 8),
                    SkeletonBox(width: double.infinity, height: 56, radius: 12),
                  ],
                ),
              ),
              error: (error, stack) => _ErrorRow(
                onRetry: () => ref.invalidate(trustedContactsProvider),
              ),
              data: (contacts) => contacts.isEmpty
                  ? const _NoContactsYet()
                  : _ContactList(
                      contacts: contacts,
                      selected: _selected,
                      alreadyShared: widget.alreadyShared,
                      onToggle: (id) => setState(() {
                        _selected.contains(id)
                            ? _selected.remove(id)
                            : _selected.add(id);
                      }),
                      onSelectAll: (ids) => setState(() {
                        // "All" means all the ones who do not already know —
                        // re-texting someone is the thing to avoid here.
                        _selected
                          ..clear()
                          ..addAll(ids);
                      }),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactList extends StatelessWidget {
  const _ContactList({
    required this.contacts,
    required this.selected,
    required this.alreadyShared,
    required this.onToggle,
    required this.onSelectAll,
  });

  final List<TrustedContact> contacts;
  final Set<String> selected;
  final Set<String> alreadyShared;
  final void Function(String id) onToggle;
  final void Function(Set<String> ids) onSelectAll;

  @override
  Widget build(BuildContext context) {
    final selectable = contacts
        .where((c) => !alreadyShared.contains(c.id))
        .map((c) => c.id)
        .toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selectable.length > 1)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => onSelectAll(selectable),
              child: Text(
                'SELECT ALL',
                style: TextStyle(
                  color: AppPalette.candyBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
        for (final contact in contacts)
          _ContactRow(
            contact: contact,
            alreadyShared: alreadyShared.contains(contact.id),
            selected: selected.contains(contact.id),
            onToggle: () => onToggle(contact.id),
          ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'SHARE THIS MEETUP',
          // Disabled AND greyed — a live-looking button that does nothing
          // reads as broken rather than as "pick someone first".
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(selected.toList()),
        ),
      ],
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.alreadyShared,
    required this.selected,
    required this.onToggle,
  });

  final TrustedContact contact;
  final bool alreadyShared;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // Someone who already knows is shown, not hidden: the user needs to see
    // who was told, and hiding them would make the list change shape between
    // visits for no visible reason.
    final subtitle = alreadyShared
        ? 'Already told'
        : (contact.phoneNumber.isNotEmpty
              ? contact.phoneNumber
              : contact.email);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: alreadyShared ? null : onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Icon(
                alreadyShared
                    ? Icons.check_circle_rounded
                    : (selected
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded),
                size: 22,
                color: alreadyShared
                    ? AppPalette.verified
                    : (selected
                          ? AppPalette.candyBlue
                          : AppPalette.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.name,
                      style: TextStyle(
                        color: alreadyShared
                            ? AppPalette.textSecondary
                            : AppPalette.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No contacts yet — a dead end otherwise, so this routes to the page that
/// fixes it rather than telling the user to go and find it.
class _NoContactsYet extends StatelessWidget {
  const _NoContactsYet();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.contact_emergency_outlined,
              color: AppPalette.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'You have not added anyone yet. Add a trusted contact and '
                'you can tell them where you are in one tap.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'ADD A TRUSTED CONTACT',
          onPressed: () {
            // Pops the sheet first so returning from the page lands back on
            // the meetup rather than under a stale sheet.
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ManageTrustedContactsPage(),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Could not load your trusted contacts.',
          style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
        ),
        const SizedBox(height: 12),
        SecondaryButton(label: 'RETRY', height: 42, onPressed: onRetry),
      ],
    );
  }
}
