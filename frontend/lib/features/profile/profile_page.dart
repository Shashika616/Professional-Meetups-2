import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
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
    final profile = ref.watch(authSessionProvider).value?.profile;
    final themeMode = ref.watch(themeModeProvider);
    final isLight = themeMode == AppThemeMode.light;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 28),
            _avatarBlock(context, ref, profile),
            const SizedBox(height: 22),
            _statsRow(profile),
            // Level 0 (ADR-014) — visible only for an account that hasn't
            // connected LinkedIn yet (Apple/Google/email signup, or a
            // LinkedIn link that hasn't happened). LinkedIn is the ONLY
            // path to Level 1+, so this is the one place a Level 0 account
            // can unlock matching/messaging/meetups.
            if (profile != null && !profile.linkedInConnected) ...[
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: ConnectLinkedInBanner(),
              ),
            ],
            const SizedBox(height: 28),
            _section(
              'VERIFICATION',
              children: [
                _verificationRow(
                  context,
                  icon: Icons.phone_android,
                  title: 'Phone',
                  done: profile?.phoneVerified ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) =>
                      PhoneVerificationPage(currentValue: profile?.phoneNumber),
                ),
                const _Divider(),
                _Row(
                  icon: Icons.work_outline,
                  title: 'LinkedIn',
                  // Genuinely conditional on profile.linkedInConnected
                  // (trustLevel >= 1) — LinkedIn is the sole path to Level
                  // 1+ (ADR-014 §1), not merely "a profile resolved," since
                  // Level 0 (Apple/Google/email, no LinkedIn) is now a real,
                  // common account state. No "VERIFY" action to offer
                  // either way — the banner above is the actual entry
                  // point for connecting it.
                  subtitle: (profile?.linkedInConnected ?? false)
                      ? 'LinkedIn Verified'
                      : 'Not connected',
                  trailing: (profile?.linkedInConnected ?? false)
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: AppPalette.verified,
                        )
                      : const SizedBox.shrink(),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: Icons.alternate_email_rounded,
                  title: 'Personal Email',
                  done: profile?.personalEmailVerified ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) => PersonalEmailVerificationPage(
                    currentValue: profile?.personalEmail,
                  ),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: Icons.badge_outlined,
                  title: 'Personal Details',
                  done: profile?.personalDetailsComplete ?? false,
                  locked: !(profile?.linkedInConnected ?? false),
                  buildScreen: (context) =>
                      PersonalDetailsPage(profile: profile),
                ),
                const _Divider(),
                _verificationRow(
                  context,
                  icon: Icons.email_outlined,
                  title: 'Work Email',
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
              'PREFERENCES',
              children: [
                _premiumRow(context, ref),
                const _Divider(),
                _Row(
                  icon: Icons.lock_outline,
                  title: 'Privacy Controls',
                  subtitle: 'Visibility and location',
                  trailing: Icon(
                    Icons.chevron_right_rounded,
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
                  icon: Icons.notifications_none_rounded,
                  title: 'Notifications',
                  subtitle: 'Last 7 days',
                  trailing: Icon(
                    Icons.chevron_right_rounded,
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
                  icon: Icons.shield_outlined,
                  title: 'Safety Center',
                  subtitle: 'Trusted contacts and SOS',
                  trailing: Icon(
                    Icons.chevron_right_rounded,
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
                  icon: Icons.dark_mode_outlined,
                  title: 'Appearance',
                  subtitle: isLight ? 'Light' : 'Dark',
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmSignOut(context, ref),
                child: FlatCard(
                  radius: 12,
                  tint: AppPalette.danger.withValues(alpha: 0.08),
                  border: AppPalette.danger.withValues(alpha: 0.3),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: Text(
                      'SIGN OUT',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.danger,
                      ),
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

  /// Gates [_signOut] behind an explicit confirm tap — a mis-tap on SIGN
  /// OUT used to end the session immediately with no way back. Mirrors
  /// `safety_page.dart`'s SOS confirmation dialog styling (the one existing
  /// confirm-dialog pattern in this codebase), not a new dialog style.
  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'SIGN OUT',
          style: TextStyle(
            color: AppPalette.danger,
            letterSpacing: 1.6,
            fontSize: 15,
          ),
        ),
        content: Text(
          'Sign out of Professional Connections?',
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
              'SIGN OUT',
              style: TextStyle(
                color: AppPalette.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await _signOut(context, ref);
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // Clears the local session regardless of whether the logout network
    // call succeeds — see AuthSessionNotifier.signOut.
    await ref.read(authSessionProvider.notifier).signOut();
    if (!context.mounted) return;
    // Clears the nav stack so the back button can't return to AppShell.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LandingPage()),
      (route) => false,
    );
  }

  Widget _avatarBlock(
    BuildContext context,
    WidgetRef ref,
    UserProfile? profile,
  ) {
    final fullName = profile?.fullName;
    final displayName = (fullName == null || fullName.isEmpty)
        ? 'Member'
        : fullName;

    return Center(
      child: Column(
        children: [
          ProfessionalAvatar(
            size: 92,
            name: fullName,
            imageUrl: (profile?.profilePhotoUrl.isNotEmpty ?? false)
                ? profile!.profilePhotoUrl
                : null,
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                displayName,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              // Full name has no dedicated row in the VERIFICATION section
              // below (ADR-023 §5) — a lightweight inline pencil here
              // instead of a full-screen page, since editing it is just a
              // single field with no OTP involved.
              if (profile != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _editFullName(context, ref, profile),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          VerificationBadges(
            trustLevel: profile?.trustLevel ?? 0,
            // Self-view only (ADR-023 §2) — decouples the Official chip
            // from the full Level 3 bundle so onboarding's work-email-only
            // verification is reflected immediately, not only once phone +
            // personal email + legal name are also done.
            workEmailVerifiedOverride: profile?.workEmailVerified,
          ),
          // headline (e.g. "SWE • Colombo") has no backend source in this
          // slice — LinkedIn's OIDC userinfo call doesn't return one, and
          // there's nowhere else to get it from yet (UserProfile.headline
          // doc comment). Nothing shown here rather than inventing data.
        ],
      ),
    );
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
    final newName = await showDialog<String>(
      context: context,
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

  Widget _statsRow(UserProfile? profile) {
    final trustLevel = profile?.trustLevel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
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
            child: _StatChip(
              value: '${profile?.meetupsCompleted ?? 0}',
              label: 'MEETUPS',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatChip(
              value: (profile?.ratingCount ?? 0) == 0
                  ? '—'
                  : profile!.ratingAverage.toStringAsFixed(1),
              label: 'RATING',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatChip(
              value: trustLevel == null ? '—' : 'L$trustLevel',
              label: 'TRUST',
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
    final subtitle = statusAsync.when(
      data: (status) => entitled ? 'Premium active' : 'Upgrade for more',
      loading: () => '',
      error: (_, _) => 'Upgrade for more',
    );
    return _Row(
      icon: Icons.workspace_premium_rounded,
      title: 'Premium',
      subtitle: subtitle,
      subtitleOverride: loading
          ? const SkeletonLoader(child: SkeletonBox(width: 90, height: 9))
          : null,
      trailing: entitled
          ? Icon(Icons.check_circle_rounded, size: 18, color: AppPalette.gold)
          : Icon(
              Icons.chevron_right_rounded,
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
          SectionLabel(title),
          const SizedBox(height: 12),
          FlatCard(
            radius: 12,
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
    required IconData icon,
    required String title,
    required bool done,
    required bool locked,
    required WidgetBuilder buildScreen,
  }) {
    final trailing = done
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: AppPalette.verified,
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.edit_outlined,
                size: 15,
                color: AppPalette.textSecondary,
              ),
            ],
          )
        : locked
        ? Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: AppPalette.textSecondary,
          )
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
        'VERIFY',
        style: TextStyle(
          fontSize: 8,
          letterSpacing: 1.4,
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
/// authenticated one). On success, runs the same pending-verification
/// sequence a fresh-onboarding LinkedIn signup would have shown, so
/// connecting from Profile doesn't skip the Level 2 steps.
class ConnectLinkedInBanner extends ConsumerStatefulWidget {
  const ConnectLinkedInBanner({super.key});

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
      await ref.read(authSessionProvider.notifier).linkLinkedIn();
      if (!mounted) return;
      final profile = ref.read(authSessionProvider).value?.profile;
      await runVerificationSequence(context, pendingVerificationSteps(profile));
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
    return FlatCard(
      radius: 12,
      tint: AppPalette.candyBlue.withValues(alpha: 0.08),
      border: AppPalette.candyBlue.withValues(alpha: 0.3),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.work_outline, size: 18, color: AppPalette.candyBlue),
              const SizedBox(width: 8),
              Text(
                'Connect LinkedIn',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Your account is restricted to view only until you connect LinkedIn...'
            'unlock matching, messaging, and meetups.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'CONNECT LINKEDIN',
            height: 44,
            isLoading: _busy,
            onPressed: _connect,
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: AppPalette.candyBlue,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 7,
              letterSpacing: 1.4,
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
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

  final IconData icon;
  final String title;
  final String subtitle;
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
            child: Icon(icon, size: 18, color: AppPalette.candyBlue),
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
                const SizedBox(height: 2),
                subtitleOverride ??
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
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'Edit Name',
        style: TextStyle(color: AppPalette.textPrimary, fontSize: 15),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        // A display name with no practical bound could otherwise overflow
        // this row's single-line Text elsewhere in the app — 100
        // characters, generous for any real human name, matches the same
        // defensive-length-limit spirit as other free-text fields in this
        // codebase (e.g. ProfileSetupScreen's full-name field).
        maxLength: 100,
        style: TextStyle(color: AppPalette.textPrimary),
        decoration: const InputDecoration(hintText: 'Full name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'CANCEL',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(
            'SAVE',
            style: TextStyle(
              color: AppPalette.candyBlue,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
