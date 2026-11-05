import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
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
import 'package:professional_connections_platform/features/credits/credits_format.dart';
import 'package:professional_connections_platform/features/credits/credits_page.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/legal/legal_document_page.dart';
import 'package:professional_connections_platform/features/onboarding/onboarding_flow.dart';
import 'package:professional_connections_platform/features/profile/profile_photo_sheet.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';
import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/phone_verification_page.dart';

part 'profile_page_sections.dart';
part 'profile_page_linkedin.dart';
part 'profile_page_rows.dart';
part 'profile_page_dialogs.dart';
part 'profile_page_hero.dart';

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
              onChangePhoto: profile == null ? null : _changePhoto,
              photoBusy: _photoBusy,
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
                  screen: ScreenNames.phoneVerification,
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
                  screen: ScreenNames.personalEmailVerification,
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
                  screen: ScreenNames.personalDetails,
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
                  screen: ScreenNames.corporateEmailVerification,
                  buildScreen: (context) => CorporateEmailVerificationPage(
                    currentDomainHint: profile?.companyDomain,
                    currentCompanyName: profile?.companyName,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _section(
              'Preferences',
              children: [
                _creditsRow(context, ref),
                const _Divider(),
                if (_showPremiumRow(ref)) ...[
                  _premiumRow(context, ref),
                  const _Divider(),
                ],
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
                      settings: const RouteSettings(
                        name: ScreenNames.privacyControls,
                      ),
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
                      settings: const RouteSettings(
                        name: ScreenNames.notifications,
                      ),
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
                      settings: const RouteSettings(name: ScreenNames.safety),
                      builder: (context) => const SafetyPage(),
                    ),
                  ),
                ),
                const _Divider(),
                _Row(
                  icon: AppIcons.document,
                  title: LegalDocument.terms.title,
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  onTap: () => openLegalDocument(context, LegalDocument.terms),
                ),
                const _Divider(),
                _Row(
                  icon: AppIcons.document,
                  title: LegalDocument.privacy.title,
                  trailing: AppIcon(
                    AppIcons.forward,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                  onTap: () =>
                      openLegalDocument(context, LegalDocument.privacy),
                ),
                const _Divider(),
                _Row(
                  icon: AppIcons.appearance,
                  title: 'Appearance',
                  trailing: Switch(
                    value: !isLight,
                    onChanged: (_) {
                      track(Cta.switchTheme);
                      ref.read(themeModeProvider.notifier).toggle();
                    },
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
    track(Cta.signOut);
    final signedOut = await showAppDialog<bool>(
      context,
      builder: (_) => const _SignOutDialog(),
    );
    if (signedOut != true || !context.mounted) return;
    // Clears the nav stack so the back button can't return to AppShell.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        settings: const RouteSettings(name: ScreenNames.landing),
        builder: (context) => const LandingPage(),
      ),
      (route) => false,
    );
  }

  /// Account deletion (App Store 5.1.1(v), Google Play's account deletion
  /// policy). The sheet does the deleting itself, like [_SignOutDialog],
  /// so it can show the work and any refusal in place; this only leaves
  /// the signed-in app once it reports the account gone.
  Future<void> _confirmDeleteAccount(BuildContext context) async {
    track(Cta.deleteAccount);
    final outcome = await showAppSheet<_DeleteOutcome>(
      context,
      builder: (_) => const _DeleteAccountSheet(),
    );
    if (!context.mounted) return;
    switch (outcome) {
      case _DeleteOutcome.deleted:
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            settings: const RouteSettings(name: ScreenNames.landing),
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

  bool _photoBusy = false;

  /// Tapping the avatar: take, choose or remove a photo (plan 2.1).
  Future<void> _changePhoto() async {
    final hasPhoto =
        ref
            .read(authSessionProvider)
            .value
            ?.profile
            ?.profilePhotoUrl
            .isNotEmpty ??
        false;
    final action = await showProfilePhotoSheet(context, hasPhoto: hasPhoto);
    if (action == null || !mounted) return;
    final auth = ref.read(authServiceProvider);
    final session = ref.read(authSessionProvider.notifier);
    final source = action.source;
    try {
      if (source == null) {
        setState(() => _photoBusy = true);
        await auth.deleteProfilePhoto();
        await session.setProfilePhoto('');
        if (mounted) {
          showSnack(context, 'Photo removed.', type: ToastType.success);
        }
        return;
      }
      final jpeg = await ref.read(photoPickerProvider).pick(source);
      // Backing out of the picker or the cropper changes nothing.
      if (jpeg == null || !mounted) return;
      setState(() => _photoBusy = true);
      await session.setProfilePhoto(await auth.uploadProfilePhoto(jpeg));
      if (mounted) {
        showSnack(context, 'Photo updated.', type: ToastType.success);
      }
    } on AuthException catch (error) {
      if (mounted) showSnack(context, error.message, type: ToastType.error);
    } catch (_) {
      // A picker refusing (camera permission denied) lands here.
      if (mounted) {
        showSnack(
          context,
          'We couldn’t change your photo. Please try again.',
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }
}
