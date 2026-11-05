part of 'profile_page.dart';

/// Part of _ProfilePageState: rows, sections and actions, kept apart so the state class
/// reads as the page.
extension _ProfileSections on _ProfilePageState {
  /// LinkedIn knows this person by a different name than their profile does
  /// (Plan 22). The link itself deliberately left the name alone, so this
  /// asks rather than informs: connecting an account is not a request to be
  /// renamed. A yes goes through the same self-edit update [_editFullName]
  /// uses (ADR-023 §5), not a new write path; a no, or a dismiss, does
  /// nothing at all, and nothing asks again — the suggestion belongs to the
  /// one link event that produced it.
  Future<void> _offerSuggestedName(
    BuildContext context,
    WidgetRef ref,
    String suggestedName,
  ) async {
    final accepted = await showAppDialog<bool>(
      context,
      builder: (_) => _SuggestedNameDialog(suggestedName: suggestedName),
    );
    if (accepted != true || !context.mounted) return;
    try {
      await ref
          .read(authSessionProvider.notifier)
          .completeProfileSetup(fullName: suggestedName);
      if (!context.mounted) return;
      showSnack(context, 'Name updated.', type: ToastType.success);
    } catch (error) {
      if (!context.mounted) return;
      // The link itself already succeeded — only the optional rename
      // failed, so this must not read like the connection went wrong.
      showSnack(
        context,
        error is AuthException
            ? error.message
            : 'Could not update your name. You can change it from Profile.',
        type: ToastType.error,
      );
    }
  }

  /// ADR-023 §5's full-name inline edit — a plain dialog, not a pushed
  /// screen: this is a single self-reported field with no OTP round-trip,
  /// unlike every other row in the VERIFICATION section. Calls
  /// `completeProfileSetup` with `companyName`/`companyEmail` both omitted
  /// (they default to null) so a pure name edit never re-triggers a
  /// work-email verification-start as a side effect — `CompleteProfileSetup`
  /// server-side only kicks that off when `company_email` is actually set.
  ///
  /// The dialog itself is [_EditNameDialog], a dedicated [StatefulWidget]
  /// owning its own [TextEditingController] — a controller created here and
  /// disposed immediately after `showDialog` resolves races the dialog's
  /// exit transition and crashes with "A TextEditingController was used
  /// after being disposed" (the same bug `meetup_detail_page.dart`'s
  /// `_WithdrawNoteDialog` and `host_meetup_controls.dart`'s
  /// `_CancelReasonDialog` already exist to avoid — this fix mirrors them).
  Future<void> _editFullName(
    BuildContext context,
    WidgetRef ref,
    UserProfile profile,
  ) async {
    track(Cta.editName);
    final newName = await showAppDialog<String>(
      context,
      builder: (context) => _EditNameDialog(initialName: profile.fullName),
    );
    if (newName == null || newName.isEmpty || newName == profile.fullName) {
      return;
    }
    try {
      await ref
          .read(authSessionProvider.notifier)
          .completeProfileSetup(fullName: newName);
      if (!context.mounted) return;
      showSnack(context, 'Name updated.', type: ToastType.success);
    } on SessionExpiredException {
      if (context.mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (error) {
      if (!context.mounted) return;
      showSnack(
        context,
        error is AuthException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }

  /// The three-up strip under the profile header.
  ///
  /// The cells were a private `_StatChip` in this file, duplicating what
  /// the public profile and the member sheet each also hand-rolled. They
  /// are [StatTile] now — same API, one implementation, and a 10.5px
  /// caption instead of the 7px letter-spaced one this had, which was
  /// below the size at which tracking helps rather than hurts.
  Widget _statsRow(UserProfile? profile) {
    final trustLevel = profile?.trustLevel;
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Expanded(
            // WAS A HARDCODED '12'. Every account saw a dozen completed
            // meetups, including one created seconds earlier, which is what
            // made the whole stats row untrustworthy rather than just this
            // chip. Now server-sourced (auth.users.meetups_completed, kept
            // current by the meetup module — auth/0005).
            //
            // Shown as a real 0 rather than the '—' the RATING chip uses:
            // "you have completed no meetups yet" is a true, meaningful
            // statement about a new account, whereas an average of zero
            // ratings is not a rating of 0.
            child: StatTile(
              value: '${profile?.meetupsCompleted ?? 0}',
              label: 'Meetups',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: StatTile(
              value: (profile?.ratingCount ?? 0) == 0
                  ? '-'
                  : profile!.ratingAverage.toStringAsFixed(1),
              label: 'Rating',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            // UI review #26. The value was "L$trustLevel", which renders as
            // "L0" — and at 18px in this typeface a capital L next to a
            // zero reads as the word "LO". It also never said what it was
            // a level OF.
            //
            // The digit alone cannot be misread, and the label now carries
            // the meaning. The label is FittedBox'd below so the longer
            // string cannot overflow a third-of-the-screen chip on a narrow
            // device.
            child: StatTile(
              value: trustLevel == null ? '-' : '$trustLevel',
              label: 'Trust level',
            ),
          ),
        ],
      ),
    );
  }

  /// Plan 29C: the balance, opening the Credits page. The figure is the
  /// server's; a placeholder bar while it loads, nothing on a failure
  /// (the page itself says what went wrong).
  Widget _creditsRow(BuildContext context, WidgetRef ref) {
    final walletAsync = ref.watch(walletProvider);
    final loading = walletAsync.isLoading && !walletAsync.hasValue;
    final wallet = walletAsync.value;
    return _Row(
      key: const Key('profileCreditsRow'),
      icon: AppIcons.credits,
      title: 'Credits',
      subtitle: wallet == null ? null : formatCredits(wallet.available),
      subtitleOverride: loading
          ? const SkeletonLoader(child: SkeletonBox(width: 70, height: 9))
          : null,
      trailing: AppIcon(
        AppIcons.forward,
        size: 18,
        color: AppPalette.textSecondary,
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: ScreenNames.credits),
          builder: (context) => const CreditsPage(),
        ),
      ),
    );
  }

  /// Premium is offered only once the server shows plans to this account
  /// (`billing.plans.visible`). Someone who already holds a subscription
  /// still gets the row, to see it.
  bool _showPremiumRow(WidgetRef ref) {
    final plansVisible =
        ref.watch(appConfigProvider).value?.plansVisible ?? false;
    final entitled =
        ref.watch(subscriptionStatusProvider).value?.isEntitled ?? false;
    return plansVisible || entitled;
  }

  /// Entry point into the Premium purchase flow (ADR-031, Slice B) — the
  /// natural existing PREFERENCES-section slot, not a new nav destination.
  /// Subtitle reads the real backend-confirmed status via
  /// [subscriptionStatusProvider], never a local/optimistic guess.
  Widget _premiumRow(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(subscriptionStatusProvider);
    final entitled = statusAsync.value?.isEntitled ?? false;
    // CHANGED: this used to resolve to the literal string 'Loading…', the
    // only place in the app using a third loading convention alongside
    // skeletons and spinners. A short placeholder bar says the same thing
    // without pretending to be the value, and it inherits the same
    // delay-then-shimmer every other placeholder now has — so a status that
    // resolves quickly shows no placeholder at all.
    final loading = statusAsync.isLoading && !statusAsync.hasValue;
    // Only when there is a state to report. "Upgrade for more" is a pitch,
    // not a status, and this row is a settings row next to four others that
    // carry no second line; the gold tick and the row's own page do the
    // selling. "Premium active" stays, because that one is a fact the user
    // opened this screen to check.
    final subtitle = entitled ? 'Premium active' : null;
    return _Row(
      icon: AppIcons.premium,
      title: 'Premium',
      subtitle: subtitle,
      subtitleOverride: loading
          ? const SkeletonLoader(child: SkeletonBox(width: 90, height: 9))
          : null,
      trailing: entitled
          ? AppIcon(AppIcons.checkCircle, size: 18, color: AppPalette.gold)
          : AppIcon(
              AppIcons.forward,
              size: 18,
              color: AppPalette.textSecondary,
            ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: ScreenNames.premium),
          builder: (context) => const PremiumPage(),
        ),
      ),
    );
  }

  Widget _section(String title, {required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title),
          const SizedBox(height: 12),
          FlatCard(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  /// Builds a Phone/Personal-Email/Personal-Details/Work-Email row. Pushes
  /// [buildScreen] — the exact same screen class the post-LinkedIn
  /// onboarding sequence uses (`onboarding_flow.dart`'s
  /// `pendingVerificationSteps`), so there's no second implementation of
  /// any of these flows for the "reached from Profile" case
  /// (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6). Reactive: popping
  /// back here after a successful verify re-renders from the freshly
  /// updated `authSessionProvider` state (no manual refresh needed).
  ///
  /// ADR-023 §5: the row is tappable regardless of [done] now — a verified
  /// row opens the same screen pre-filled with its real current value
  /// (threaded in by the caller via `buildScreen`) for editing. A verified
  /// row shows a pencil icon next to its checkmark (not just the checkmark
  /// alone) so that editability is actually discoverable — a plain check
  /// icon gives no visual hint that tapping does anything. [locked] still
  /// wins over tappability either way: every one of these four steps
  /// requires LinkedIn server-side (`requireLinkedIn`, ADR-014's Level 0
  /// read-only audit, Step 6) — tapping at Level 0 would just 403, so the
  /// row shows a locked hint pointing at the LinkedIn banner above instead,
  /// with no pencil.
  Widget _verificationRow(
    BuildContext context, {
    required String icon,
    required String title,
    required bool done,
    required bool locked,
    required String screen,
    required WidgetBuilder buildScreen,
  }) {
    // Pencil first, tick LAST: the tick is the row's status and every
    // status tick in this section (LinkedIn's, Premium's) sits flush at the
    // right edge, so the pencil goes inboard of it. The other order pushed
    // a verified row's tick 23px left of its neighbours' and the column
    // read as ragged.
    final trailing = done
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(AppIcons.edit, size: 15, color: AppPalette.textSecondary),
              const SizedBox(width: 8),
              AppIcon(
                AppIcons.checkCircle,
                size: 18,
                color: AppPalette.verified,
              ),
            ],
          )
        : locked
        ? AppIcon(AppIcons.lock, size: 16, color: AppPalette.textSecondary)
        : _verifyChip();
    final row = _Row(
      icon: icon,
      title: title,
      subtitle: done
          ? 'Verified'
          : locked
          ? 'Connect LinkedIn first'
          : 'Not verified',
      trailing: trailing,
    );
    if (locked) return row;
    // Same reasoning as _PrefRow's: the whole row is the target, not just
    // the glyphs painted on it.
    return Semantics(
      container: true,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          track(Cta.startVerification);
          Navigator.push(context, screenRoute(screen, buildScreen));
        },
        child: row,
      ),
    );
  }

  // No longer its own tap target (ADR-023 §5 made the whole row tappable) —
  // kept as a plain visual chip, not a GestureDetector, so there's exactly
  // one tap handler per row rather than two overlapping ones.
  Widget _verifyChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.candyBlue.withValues(alpha: 0.5)),
      ),
      child: Text(
        'Verify',
        style: TextStyle(
          fontSize: 8,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w800,
          color: AppPalette.candyBlue,
        ),
      ),
    );
  }
}
