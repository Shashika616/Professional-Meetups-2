import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_dialog.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/app_banner.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/stat_tile.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/onboarding/onboarding_flow.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';
import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/phone_verification_page.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

/// # WHY THIS STATE IS KEPT ALIVE
///
/// Same reason as the other three tabs — AppShell's `PageView` disposes the
/// tab you swipe away from. This page reads `subscriptionStatusProvider`,
/// so a round trip re-runs that fetch and flickers the Premium row's
/// subtitle between its loading and resolved text; it also loses scroll
/// position on a page long enough for that to be noticeable.
class _ProfilePageState extends ConsumerState<ProfilePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required by the mixin — see [_HomePageState] for the full reasoning.
    super.build(context);

    // The one real verification step this slice has (LinkedIn) — fullName/
    // profilePhotoUrl/trustLevel come from the one-time linkedin/callback
    // response, cached in AuthSessionState (see backend/PLAN.md Step 3 /
    // frontend/PLAN.md Step 3). Null while the session is still loading or
    // if somehow unauthenticated; the block below falls back sensibly.
    final sessionAsync = ref.watch(authSessionProvider);
    final profile = sessionAsync.value?.profile;
    final themeMode = ref.watch(themeModeProvider);
    final isLight = themeMode == AppThemeMode.light;

    // Nothing to show yet: the page's own shape, shimmering, rather than a
    // hero that says "Member" over empty rows. A failed session restore
    // holds the skeleton a moment and then says so, with a way to retry.
    if (profile == null && sessionAsync.isLoading) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: _ProfileSkeleton(),
      );
    }
    if (profile == null && sessionAsync.hasError) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SkeletonThenFailure(
          skeleton: const _ProfileSkeleton(),
          failure: SafeArea(
            child: ListView(
              children: [
                LoadFailedState(
                  failure: LoadFailure.of(sessionAsync.error),
                  onRetry: () => ref.invalidate(authSessionProvider),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      // top: false so the hero runs under the status bar; it pads for it
      // itself.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _ProfileHero(
              profile: profile,
              onEditName: profile == null
                  ? null
                  : () => _editFullName(context, ref, profile),
              stats: _statsRow(profile),
            ),
            // Level 0 (ADR-014) — visible only for an account that hasn't
            // connected LinkedIn yet (Apple/Google/email signup, or a
            // LinkedIn link that hasn't happened). LinkedIn is the ONLY
            // path to Level 1+, so this is the one place a Level 0 account
            // can unlock matching/messaging/meetups.
            if (profile != null && !profile.linkedInConnected) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                // The follow-up work runs HERE, on the page, not inside the
                // banner: a successful link flips profile.linkedInConnected,
                // which removes the banner from this very build. Anything
                // the banner awaited afterwards would be running on a
                // defunct State, and its `mounted` guards would silently
                // swallow it. The page stays.
                child: ConnectLinkedInBanner(
                  onLinked: (suggestedName) =>
                      _afterLinkedInConnected(context, ref, suggestedName),
                ),
              ),
            ],
            const SizedBox(height: 28),
            _section(
              'Verification',
              children: [
                _verificationRow(
                  context,
                  icon: AppIcons.phone,
                  title: 'Phone',
                  done: profile?.phoneVerified ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) =>
                      PhoneVerificationPage(currentValue: profile?.phoneNumber),
                ),
                const _Divider(),
                _Row(
                  icon: AppIcons.work,
                  title: 'LinkedIn',
                  // Genuinely conditional on profile.linkedInConnected
                  // (trustLevel >= 1) — LinkedIn is the sole path to Level
                  // 1+ (ADR-014 §1), not merely "a profile resolved," since
                  // Level 0 (Apple/Google/email, no LinkedIn) is now a real,
                  // common account state. No "VERIFY" action to offer
                  // either way — the banner above is the actual entry
                  // point for connecting it.
                  subtitle: (profile?.linkedInConnected ?? false)
                      ? 'LinkedIn verified'
                      : 'Not connected',
                  trailing: (profile?.linkedInConnected ?? false)
                      ? AppIcon(
                          AppIcons.checkCircle,
                          size: 18,
                          color: AppPalette.verified,
                        )
                      : const SizedBox.shrink(),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: AppIcons.atSign,
                  title: 'Personal email',
                  done: profile?.personalEmailVerified ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) => PersonalEmailVerificationPage(
                    currentValue: profile?.personalEmail,
                  ),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: AppIcons.idCard,
                  title: 'Personal details',
                  done: profile?.personalDetailsComplete ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) =>
                      PersonalDetailsPage(profile: profile),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: AppIcons.mail,
                  title: 'Work email',
                  done: profile?.workEmailVerified ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) => CorporateEmailVerificationPage(
                    currentDomainHint: profile?.companyDomain,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _section(
              'Preferences',
              children: [
                _premiumRow(context, ref),
                const _Divider(),
                _Row(
                  // An eye, not a padlock. The four verification rows
                  // further down use a padlock to mean "you cannot do
                  // this yet"; a padlock here, on a row you CAN always
                  // open, made the two readings collide. This page is
                  // about what other members can see, which is what the
                  // subtitle says.
                  icon: AppIcons.eye,
                  title: 'Privacy controls',
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  // The chevron pointed at nothing until now.
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const PrivacyControlsPage(),
                    ),
                  ),
                ),
                _Divider(),
                // Deliberately dead (2026-08-31 review hardening) — a real
                // Notifications settings screen isn't being built as part
                // of this pass; this now honestly reads as disabled rather
                // than implying it does something it doesn't.
                _Row(
                  icon: AppIcons.bell,
                  title: 'Notifications',
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const NotificationsPage(),
                    ),
                  ),
                ),
                _Divider(),
                _Row(
                  icon: AppIcons.shield,
                  title: 'Safety center',
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (context) => const SafetyPage(),
                    ),
                  ),
                ),
                const _Divider(),
                _Row(
                  icon: AppIcons.appearance,
                  title: 'Appearance',
                  trailing: Switch(
                    value: !isLight,
                    onChanged: (_) =>
                        ref.read(themeModeProvider.notifier).toggle(),
                    activeTrackColor: AppPalette.candyBlue,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Deleting comes first, in a card of its own, and signing out
            // keeps the slab below it. The two are not the same kind of
            // action, so they do not get the same shape: this one is a row
            // that states what it does and opens a sheet that explains the
            // rest, which is what keeps a permanent action from reading as
            // casually as the reversible one under it. Both stores require
            // it be reachable from the account screen without hunting.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: FlatCard(
                radius: 18,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: _Row(
                  icon: AppIcons.personRemove,
                  iconColor: AppPalette.danger,
                  title: 'Delete account',
                  subtitle: 'Permanently remove your account and data',
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  onTap: () => _confirmDeleteAccount(context),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmSignOut(context, ref),
                // Red, by the product owner's call. The screen set draws
                // this one neutral and reserves red for Delete account; the
                // decision here is that signing out should read as the hard
                // stop on the screen. Keeping the glyph and the sentence
                // case from the redesign, in the danger tone.
                child: FlatCard(
                  radius: 18,
                  tint: AppPalette.danger.withValues(alpha: 0.08),
                  border: AppPalette.danger.withValues(alpha: 0.3),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(
                          AppIcons.signOut,
                          size: 17,
                          color: AppPalette.danger,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Sign out',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Was 96 to clear AppShell's old floating bar (body drew
            // underneath it via extendBody: true). Both gone in ADR-032
            // round 2 — the body is now laid out above a flush, pinned
            // AppBottomBar, so this is just bottom breathing room.
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Gates sign-out behind an explicit confirm tap — a mis-tap on SIGN OUT
  /// used to end the session immediately with no way back. The dialog does
  /// the signing out itself (see [_SignOutDialog]) so its button can show
  /// the work happening; this only navigates once it reports done.
  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final signedOut = await showAppDialog<bool>(
      context,
      builder: (_) => const _SignOutDialog(),
    );
    if (signedOut != true || !context.mounted) return;
    // Clears the nav stack so the back button can't return to AppShell.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LandingPage()),
      (route) => false,
    );
  }

  /// Account deletion (App Store 5.1.1(v), Google Play's account deletion
  /// policy). The sheet does the deleting itself, like [_SignOutDialog],
  /// so it can show the work and any refusal in place; this only leaves
  /// the signed-in app once it reports the account gone.
  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final outcome = await showAppSheet<_DeleteOutcome>(
      context,
      builder: (_) => const _DeleteAccountSheet(),
    );
    if (!context.mounted) return;
    switch (outcome) {
      case _DeleteOutcome.deleted:
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const LandingPage(accountDeleted: true),
          ),
          (route) => false,
        );
      case _DeleteOutcome.sessionExpired:
        // AppShell's safety net takes it from here, with its own notice.
        ref.read(authSessionProvider.notifier).forceSignOut();
      case null:
        break;
    }
  }

  /// Everything that happens after "Connect LinkedIn" succeeds, owned by the
  /// page because the banner that started it has just removed itself (see
  /// the call site). Two steps, in order: offer LinkedIn's name if the
  /// server suggested one, then walk the Level 2 verification steps this
  /// account can now actually complete.
  Future<void> _afterLinkedInConnected(
    BuildContext context,
    WidgetRef ref,
    String suggestedName,
  ) async {
    if (suggestedName.isNotEmpty) {
      await _offerSuggestedName(context, ref, suggestedName);
      if (!context.mounted) return;
    }
    final profile = ref.read(authSessionProvider).value?.profile;
    await runVerificationSequence(context, pendingVerificationSteps(profile));
  }

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
        MaterialPageRoute<void>(builder: (context) => const PremiumPage()),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: buildScreen)),
      child: row,
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

/// Profile's "Connect LinkedIn" entry point (ADR-014 Step 7) — calls
/// [AuthSessionNotifier.linkLinkedIn], not `signInWithLinkedIn` (that
/// creates/resolves an account; this links to the caller's already-
/// authenticated one).
///
/// This widget owns the button, the busy state and the failure toast, and
/// nothing else. What follows a SUCCESS — the suggested-name offer and the
/// pending-verification sequence a fresh LinkedIn signup would have shown —
/// is handed to [onLinked], because success is exactly what takes this
/// widget off the screen.
class ConnectLinkedInBanner extends ConsumerStatefulWidget {
  const ConnectLinkedInBanner({super.key, this.onLinked});

  /// Run once the link succeeds, with the server's suggested name (`''`
  /// when there is nothing to suggest). Owned by the page rather than this
  /// widget on purpose: a successful link removes this banner from the
  /// tree, so work awaited here would be abandoned half-done.
  final Future<void> Function(String suggestedName)? onLinked;

  @override
  ConsumerState<ConnectLinkedInBanner> createState() =>
      ConnectLinkedInBannerState();
}

class ConnectLinkedInBannerState extends ConsumerState<ConnectLinkedInBanner> {
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final suggestedName = await ref
          .read(authSessionProvider.notifier)
          .linkLinkedIn();
      // No `mounted` check before this call, deliberately: by now this
      // banner may already be gone (the profile it is conditioned on just
      // changed), and the callback belongs to the page, which is not.
      await widget.onLinked?.call(suggestedName);
    } catch (error) {
      if (mounted) {
        // A cancellation (closed the browser without finishing) gets a
        // softer, non-alarming toast, not the red error styling a genuine
        // network/server failure gets — same distinction
        // onboarding_flow.dart's sign-in error handling makes.
        showSnack(
          context,
          error is AuthException
              ? error.message
              : 'Something went wrong. Please try again.',
          type: error is SignInCancelledException
              ? ToastType.info
              : ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // # WHY THIS IS ONE TAPPABLE BANNER AND NOT A CARD WITH A BUTTON
    //
    // It used to be a bordered card containing a heading that read
    // "Connect LinkedIn", a paragraph, and a button that ALSO read
    // "Connect LinkedIn" — the same three words twice, 90px apart, as the
    // two loudest things in the card. (The 2026-10 copy pass is what made
    // that undeniable: before it, the heading was uppercase and the button
    // was not, which disguised the repetition as hierarchy.)
    //
    // The screen set makes this a banner: title, one line of why, and the
    // whole surface is the target. There is now exactly one "Connect
    // LinkedIn" on the screen, and it is the thing you press.
    return Semantics(
      button: true,
      enabled: !_busy,
      child: GestureDetector(
        onTap: _busy ? null : _connect,
        behavior: HitTestBehavior.opaque,
        child: AppBanner(
          icon: AppIcons.work,
          tone: AppTone.accent,
          title: 'Connect LinkedIn',
          message: 'Your account is view only until you connect it.',
          trailing: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppPalette.candyBlue,
                  ),
                )
              : AppIcon(
                  AppIcons.forward,
                  size: 20,
                  color: AppPalette.candyBlue,
                ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    // Overrides the candyBlue every other row's glyph uses. Only the
    // destructive row passes it: a row that ends an account should not
    // wear the same colour as the one that opens Privacy Controls.
    this.iconColor,
    required this.title,
    // Optional. The screen set's preference rows are an icon, a label and
    // a chevron — no second line. Most of the subtitles here restated the
    // destination ("Trusted contacts and SOS" under "Safety center") or
    // named something the row does not actually show ("Last 7 days" under
    // "Notifications"). The verification rows still pass one, because
    // there the second line carries the state.
    this.subtitle,
    // Renders in place of [subtitle] when given. Exists for the one row
    // whose subtitle is genuinely still loading — a placeholder bar reads
    // as "a value is coming here" where the literal word "Loading…" reads
    // as the value itself.
    this.subtitleOverride,
    required this.trailing,
    // Optional (2026-08-31 review hardening) — every pre-existing caller
    // omits this and stays a purely visual row, same as before. Only rows
    // that actually go somewhere (Safety Center) pass it.
    this.onTap,
  });

  final String icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? subtitleOverride;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              // Theme-derived, and composited onto the card it sits on. Was a
              // hardcoded `Colors.white` at 5%: a faint chip in dark mode and
              // literally invisible in light mode, where it was white on a
              // white card.
              color: AppPalette.tintedSurface(
                AppPalette.textPrimary.withValues(alpha: 0.05),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(
              icon,
              size: 18,
              color: iconColor ?? AppPalette.candyBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitleOverride != null) ...[
                  const SizedBox(height: 2),
                  subtitleOverride!,
                ] else if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
    if (onTap == null) return row;
    // opaque, not the default deferToChild: a Row of an icon, text and a
    // chevron leaves most of its width as transparent padding, and
    // deferToChild only hit-tests the painted children — so the row only
    // responded on the label or the arrow, with dead space between them.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: row,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppPalette.hairline,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}

/// Offers LinkedIn's name after a Profile-initiated link when it differs
/// from the one on the account (Plan 22). Resolves to true on UPDATE, and
/// to null on KEEP MINE or a tap outside — only an explicit yes changes
/// anything, which is the whole point of asking.
///
/// Stateless and unbusy by design: the update it triggers runs on the page
/// behind it, reported by the same toast a manual name edit uses, so this
/// dialog closes the moment it is answered.
class _SuggestedNameDialog extends StatelessWidget {
  const _SuggestedNameDialog({required this.suggestedName});

  final String suggestedName;

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Update your name?',
      message:
          'LinkedIn shows your name as $suggestedName. '
          'Update your profile to match?',
      confirmLabel: 'Update',
      cancelLabel: 'Keep mine',
      onConfirm: () => Navigator.pop(context, true),
      onCancel: () => Navigator.pop(context),
    );
  }
}

/// The full-name edit dialog (ADR-023 §5), split out as its own
/// [StatefulWidget] so its [TextEditingController] is owned by — and
/// disposed by — the State's own lifecycle, the same pattern
/// `meetup_detail_page.dart`'s `_WithdrawNoteDialog` and
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` already use. Resolves
/// to null on CANCEL/dismiss, or the trimmed new name on SAVE.
class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Edit name',
      confirmLabel: 'Save',
      cancelLabel: 'Cancel',
      onConfirm: () => Navigator.pop(context, _controller.text.trim()),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Full name',
        maxLines: 1,
        // A display name with no practical bound could otherwise overflow
        // this row's single-line Text elsewhere in the app — 100
        // characters, generous for any real human name, matches the same
        // defensive-length-limit spirit as other free-text fields in this
        // codebase (e.g. ProfileSetupScreen's full-name field).
        maxLength: 100,
      ),
    );
  }
}

/// The sign-out confirmation. Mirrors `safety_page.dart`'s SOS dialog
/// styling (the one confirm-dialog pattern in this codebase). Owns the
/// sign-out call so the SIGN OUT action can turn into a spinner and lock
/// while it runs: the tap has to be seen to take, or the user taps again
/// wondering whether it did. The wait is short by design —
/// [AuthSessionNotifier.signOut] clears the local session first and does
/// the server work afterwards, in the background — but it is not zero, and
/// a button that looks idle for even a moment after a tap reads as broken.
///
/// Pops with true once signed out; the page navigates. Pops with false on
/// CANCEL, and refuses to be dismissed at all mid-sign-out.
class _SignOutDialog extends ConsumerStatefulWidget {
  const _SignOutDialog();

  @override
  ConsumerState<_SignOutDialog> createState() => _SignOutDialogState();
}

class _SignOutDialogState extends ConsumerState<_SignOutDialog> {
  bool _busy = false;

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Clears the local session regardless of whether the network call
    // succeeds — see AuthSessionNotifier.signOut.
    await ref.read(authSessionProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AppConfirmDialog(
        title: 'Sign out?',
        message: 'You can sign back in with a one-time code.',
        confirmLabel: 'Sign out',
        cancelLabel: 'Cancel',
        danger: true,
        isLoading: _busy,
        onConfirm: _busy ? null : _signOut,
        onCancel: _busy ? null : () => Navigator.pop(context, false),
      ),
    );
  }
}

enum _DeleteOutcome { deleted, sessionExpired }

enum _DeletePhase { confirming, deleting, blocked }

/// Says plainly what deleting removes and what it keeps, then deletes.
///
/// A refusal from the server (meetups or requests that have not happened
/// yet) is not an error toast: it turns the sheet into the answer, with the
/// server's own sentence about what to do first. Anything else is a toast
/// and the sheet stays, so trying again is one tap. It cannot be dismissed
/// while the request is in flight: the outcome has to be seen.
class _DeleteAccountSheet extends ConsumerStatefulWidget {
  const _DeleteAccountSheet();

  @override
  ConsumerState<_DeleteAccountSheet> createState() =>
      _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends ConsumerState<_DeleteAccountSheet> {
  _DeletePhase _phase = _DeletePhase.confirming;
  String _blockedMessage = '';

  Future<void> _delete() async {
    if (_phase == _DeletePhase.deleting) return;
    setState(() => _phase = _DeletePhase.deleting);
    try {
      await ref.read(authSessionProvider.notifier).deleteAccount();
      if (mounted) Navigator.pop(context, _DeleteOutcome.deleted);
    } on AccountDeletionBlockedException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _DeletePhase.blocked;
        _blockedMessage = error.message;
      });
    } on SessionExpiredException {
      if (mounted) Navigator.pop(context, _DeleteOutcome.sessionExpired);
    } catch (error) {
      if (!mounted) return;
      setState(() => _phase = _DeletePhase.confirming);
      showSnack(
        context,
        error is AuthException
            ? error.message
            : 'We couldn’t delete your account just now. Please try again in a moment.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _phase == _DeletePhase.blocked;
    return PopScope(
      canPop: _phase != _DeletePhase.deleting,
      child: AppSheet(
        // A question, not a restatement of the row that opened it. It
        // was 'Delete account', identical to the settings row — so with
        // the sheet open the screen said 'Delete account' twice and
        // neither one was obviously the confirmation. A confirmation
        // sheet should ask something.
        title: blocked ? 'Not just yet' : 'Delete your account?',
        titleColor: blocked ? AppPalette.textPrimary : AppPalette.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: blocked ? _blocked(context) : _confirming(context),
        ),
      ),
    );
  }

  List<Widget> _blocked(BuildContext context) {
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(AppIcons.calendarX, color: AppPalette.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _blockedMessage,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        'People are counting on you to be there. Once nothing is left '
        'waiting, you can delete your account from here.',
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 13,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: 'Got it',
        height: 50,
        onPressed: () => Navigator.pop(context),
      ),
    ];
  }

  List<Widget> _confirming(BuildContext context) {
    final deleting = _phase == _DeletePhase.deleting;
    final body = TextStyle(
      color: AppPalette.textSecondary,
      fontSize: 13,
      height: 1.4,
    );
    return [
      Text(
        'This permanently deletes your TieHere account and cannot be undone.',
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 12),
      _Point(
        icon: AppIcons.trash,
        text:
            'Your profile, verifications, trusted contacts, meetup history '
            'and notifications are deleted.',
        style: body,
      ),
      _Point(
        icon: AppIcons.star,
        text:
            'Ratings stay so other members’ records stay accurate, but '
            'nothing links them to you.',
        style: body,
      ),
      _Point(
        icon: AppIcons.shield,
        text:
            'If you ever sent an SOS, a private record of those alerts is '
            'kept for 90 days for safety reasons, then deleted.',
        style: body,
      ),
      _Point(
        icon: AppIcons.premium,
        text:
            'A Premium subscription is billed by the App Store or Google '
            'Play. Cancel it there to stop future charges.',
        style: body,
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: 'Delete my account',
        height: 50,
        fillColor: AppPalette.danger,
        foregroundColor: Colors.white,
        isLoading: deleting,
        onPressed: deleting ? null : _delete,
      ),
      const SizedBox(height: 10),
      // An outline button under the red one, the pair the screen set
      // draws on every confirmation. A bare TextButton here read as a
      // caption rather than as the way out.
      SecondaryButton(
        label: 'Cancel',
        height: 50,
        onPressed: deleting ? null : () => Navigator.pop(context),
      ),
    ];
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text, required this.style});

  final String icon;
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 16, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// The top of the profile, in the shape of the reference design: a flat
/// tinted band that runs edge to edge and under the status bar, rounded
/// only at the bottom, with the edit control as a round button in its
/// corner, the person in the middle with a ring around their picture and a
/// small status dot, their name and standing under it, and their numbers
/// in a quiet row at the bottom. The band is the palette's own deepBlue
/// tint (pale in light, deep in dark): one colour, no gradient.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.onEditName,
    required this.stats,
  });

  final UserProfile? profile;
  final VoidCallback? onEditName;
  final Widget stats;

  @override
  Widget build(BuildContext context) {
    final fullName = profile?.fullName;
    final displayName = (fullName == null || fullName.isEmpty)
        ? 'Member'
        : fullName;
    final photo = (profile?.profilePhotoUrl.isNotEmpty ?? false)
        ? profile!.profilePhotoUrl
        : null;
    final standing = switch (profile?.trustLevel) {
      null => 'Signing you in',
      0 => 'New here',
      1 => 'Getting verified',
      2 => 'Verified member',
      _ => 'Verified professional',
    };

    final statusBar = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.fromLTRB(20, statusBar + 8, 20, 22),
      decoration: BoxDecoration(
        color: AppPalette.deepBlue,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(
        children: [
          // The one control on the card, in the corner where the
          // reference keeps it. Full name has no row of its own in the
          // VERIFICATION section (ADR-023 §5): one field, no OTP.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onEditName != null)
                _RoundControl(
                  icon: AppIcons.edit,
                  onTap: onEditName!,
                  label: 'Edit your name',
                )
              else
                const SizedBox(height: 44),
            ],
          ),
          const SizedBox(height: 2),
          // The ring and the presence dot are ProfessionalAvatar's job.
          // This screen used to hand-roll both in a Stack, which is why
          // the Home header's avatar and this one stopped matching the
          // moment one of them changed: Home went to a flat blue band and
          // this kept the old blue-to-green gradient.
          ProfessionalAvatar(
            size: 104,
            name: fullName,
            imageUrl: photo,
            ring: true,
            showPresenceDot: true,
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            standing,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 12),
          VerificationBadges(
            trustLevel: profile?.trustLevel ?? 0,
            // Self-view only (ADR-023 §2): the Official chip follows the
            // work-email step on its own, ahead of the full Level 3.
            workEmailVerifiedOverride: profile?.workEmailVerified,
          ),
          const SizedBox(height: 20),
          stats,
        ],
      ),
    );
  }
}

/// A round, raised control on the hero card: the reference's corner
/// buttons.
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.onTap,
    required this.label,
  });

  final String icon;
  final VoidCallback onTap;

  /// What this control does, for a screen reader and for a long press.
  ///
  /// REQUIRED, NOT OPTIONAL (UI review #31). An unlabelled icon button is
  /// announced as "button" and nothing else, so a floating pencil over a
  /// profile is unreadable to anyone using TalkBack or VoiceOver — and
  /// ambiguous to everyone else, since a pencil on this screen could
  /// plausibly edit the name, the photo or the whole profile. Making it a
  /// required parameter means a second control cannot be added without
  /// one.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(message: label, child: _buildControl()),
    );
  }

  Widget _buildControl() {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppPalette.card,
          border: Border.all(color: AppPalette.hairline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: AppPalette.isLight ? 0.06 : 0.3,
              ),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: AppIcon(icon, size: 19, color: AppPalette.textPrimary),
      ),
    );
  }
}

/// The profile's own shape as placeholders: the band with a circle and
/// two lines, three stat boxes, then a card of four rows.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.paddingOf(context).top;
    return SkeletonLoader(
      child: ListView(
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(20, statusBar + 52, 20, 22),
            decoration: BoxDecoration(
              color: AppPalette.deepBlue,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(32),
              ),
            ),
            child: Column(
              children: [
                const SkeletonBox(width: 116, height: 116, radius: 58),
                const SizedBox(height: 18),
                const SkeletonBox(width: 180, height: 22, opacity: 0.1),
                const SizedBox(height: 10),
                const SkeletonBox(width: 120, height: 13),
                const SizedBox(height: 26),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      const Expanded(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 68,
                          radius: 16,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SkeletonBox(width: 110, height: 11),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: FlatCard(
              radius: 18,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: EdgeInsets.only(bottom: i == 3 ? 0 : 18),
                      child: const Row(
                        children: [
                          SkeletonBox(width: 40, height: 40, radius: 12),
                          SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(width: 120, height: 13),
                                SizedBox(height: 6),
                                SkeletonBox(width: 80, height: 11),
                              ],
                            ),
                          ),
                          SkeletonBox(width: 22, height: 22, radius: 11),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
