import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

/// Raises the claim-an-existing-account sheet. Resolves to true once the
/// claim succeeded (the session is already stored and
/// `authSessionProvider` already reflects it, same as any other sign-in),
/// and to null if the person cancelled.
///
/// # WHAT THIS SCREEN IS FOR
///
/// They signed in with Apple, Google or LinkedIn, and the address that
/// provider verified is already on an account here. Server-side there is
/// nothing left to decide: `personal_email` is unique, so a second account
/// for that address cannot be created. The only question is whether this is
/// the same person coming back through a different door, and the only way to
/// answer it is to ask them to prove they still hold the mailbox.
///
/// # WHAT IT DELIBERATELY DOES NOT SAY
///
/// Nothing about the existing account. Not the name on it, not the photo,
/// not which provider made it, not when. They have proved to Apple, Google
/// or LinkedIn that they control this address and nothing more, and until
/// the code comes back they are, as far as this app knows, a stranger asking
/// about somebody else's account. The address shown IS theirs — it came out
/// of their own token — so saying it reveals nothing they did not supply.
Future<bool?> showAccountClaimSheet(
  BuildContext context, {
  required AccountClaimRequiredException claim,
}) {
  return showAppSheet<bool>(
    context,
    // Not dismissible by a tap outside or a drag: this sheet is a fork in
    // the signup, and the two ways out of it are both deliberate taps.
    // Backing out of it by accident mid-code would leave the person on the
    // sign-in screen with no idea what happened.
    isDismissible: false,
    builder: (_) => _AccountClaimSheet(claim: claim),
  );
}

class _AccountClaimSheet extends ConsumerStatefulWidget {
  const _AccountClaimSheet({required this.claim});

  final AccountClaimRequiredException claim;

  @override
  ConsumerState<_AccountClaimSheet> createState() => _AccountClaimSheetState();
}

class _AccountClaimSheetState extends ConsumerState<_AccountClaimSheet> {
  @override
  Widget build(BuildContext context) {
    return AppSheet(
      title: 'This email is already in use',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            // One sentence of fact, one of what to do. No speculation about
            // whose account it is, because we do not know and must not
            // imply.
            'An account here already uses ${_display(widget.claim.email)}.\n\n'
            'If it is yours, enter the code we just sent to that address and '
            'you will be signed in to it. Nothing about the account is shown '
            'until then.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          OtpEntry(
            // The code is already in their inbox: it was sent as part of the
            // same response that opened this sheet. Sending another on mount
            // would burn the cooldown and show an error for a code that
            // arrived fine.
            sendOnMount: false,
            initialCooldownSeconds: widget.claim.resendAfterSeconds,
            onSend: () => ref
                .read(authSessionProvider.notifier)
                .resendAccountClaimCode(widget.claim.ticket),
            onSubmit: _submit,
          ),
          const SizedBox(height: 10),
          // CANCEL, which the spec asks for by name and which this screen
          // needs more than most: the alternative to continuing is not
          // "nothing", it is "sign in the way you did last time", and
          // somebody who does not recognise the address should be able to
          // back out without typing anything.
          SecondaryButton(
            key: const Key('cancelAccountClaim'),
            label: 'Cancel',
            height: 48,
            color: AppPalette.textSecondary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// OtpEntry owns the error display, so this rethrows rather than catching:
  /// a wrong code has to land in the sheet's own error slot, not a toast
  /// behind it.
  Future<void> _submit(String code) async {
    await ref
        .read(authSessionProvider.notifier)
        .completeAccountClaim(ticket: widget.claim.ticket, code: code);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// The server always sends the address, but a client must not render a
  /// blank sentence if it ever stops. "that address" reads correctly in the
  /// same place.
  String _display(String email) => email.isEmpty ? 'that address' : email;
}
