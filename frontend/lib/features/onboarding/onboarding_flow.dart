import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/onboarding/age_confirmation_step.dart';
import 'package:professional_connections_platform/features/onboarding/email_signup_step.dart';
import 'package:professional_connections_platform/features/onboarding/profile_setup_screen.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/phone_verification_page.dart';

/// The phone → personal email → personal details → corporate email
/// sequence, each step individually skippable (`frontend/PLAN.md`'s
/// Level 2/3 addendum, Step 5). No longer run as part of initial onboarding
/// (that flow now only shows the mandatory profile-setup screen,
/// `ProfileSetupScreen`) — this pair is kept for `ProfilePage`'s own
/// "Connect LinkedIn" banner, the one remaining place a user is walked
/// through these steps directly, rather than reaching each one
/// independently from Profile's verification rows.
///
/// Only ever run after a LinkedIn-connecting path — every step in this
/// sequence requires LinkedIn server-side (`requireLinkedIn`, ADR-014 §4),
/// so running it for an Apple/Google/email-only Level 0 account would just
/// walk the user through screens that 403 immediately.
///
/// Filtered against [profile]'s already-verified flags — a user must not
/// be walked back through steps the backend already has recorded as done.
/// `profile` is null only if the fetch right after sign-in itself failed,
/// in which case the safe fallback is the full sequence, same as a
/// brand-new user — not silently skipping steps we have no actual
/// confirmation are done.
List<WidgetBuilder> pendingVerificationSteps(UserProfile? profile) {
  return [
    if (profile?.phoneVerified != true)
      (context) => PhoneVerificationPage(currentValue: profile?.phoneNumber),
    if (profile?.personalEmailVerified != true)
      (context) =>
          PersonalEmailVerificationPage(currentValue: profile?.personalEmail),
    if (profile?.personalDetailsComplete != true)
      (context) => PersonalDetailsPage(profile: profile),
    if (profile?.workEmailVerified != true)
      (context) => CorporateEmailVerificationPage(
        currentDomainHint: profile?.companyDomain,
      ),
  ];
}

/// Pushes each still-pending verification screen in turn, awaiting the pop
/// before pushing the next one — every screen pops itself (Skip or a
/// successful verify). Used by `ProfilePage`'s "Connect LinkedIn" banner
/// (ADR-014 Step 7) — the one caller left now that initial onboarding no
/// longer runs this sequence.
Future<void> runVerificationSequence(
  BuildContext context,
  List<WidgetBuilder> steps,
) async {
  for (final buildScreen in steps) {
    if (!context.mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: buildScreen));
  }
}

class OnboardingFlow extends ConsumerStatefulWidget {
  const OnboardingFlow({super.key});

  @override
  ConsumerState<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _OnboardingStep { ageConfirmation, chooseMethod }

class _OnboardingFlowState extends ConsumerState<OnboardingFlow> {
  _OnboardingStep _step = _OnboardingStep.ageConfirmation;
  bool _busy;

  _OnboardingFlowState() : _busy = false;

  void _onAgeConfirmed() {
    setState(() => _step = _OnboardingStep.chooseMethod);
  }

  Future<void> _continueWithLinkedIn() async {
    if (_busy) return; // guards against a slow tap double-firing the flow
    setState(() => _busy = true);
    try {
      await ref
          .read(authSessionProvider.notifier)
          .signInWithLinkedIn(ageConfirmedOver18: true);
      if (!mounted) return;
      // The Level 2/3 phone/personal-email/personal-details/corporate-email
      // sequence no longer runs during initial onboarding — straight to the
      // mandatory profile-setup screen instead, same as every other path.
      // Those steps are still reachable later from ProfilePage (which
      // reuses the exact same pendingVerificationSteps/runVerificationSequence
      // pair via its own "Connect LinkedIn" banner).
      await _goToAppShell();
    } catch (error, stackTrace) {
      _handleSignInError('signInWithLinkedIn', error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithApple() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authSessionProvider.notifier)
          .signInWithApple(ageConfirmedOver18: true);
      if (!mounted) return;
      // Level 0 (Apple alone never grants trust, ADR-014 §1) — straight to
      // AppShell, no verification sequence attempted (every step in it
      // requires LinkedIn server-side and would just 403).
      await _goToAppShell();
    } catch (error, stackTrace) {
      _handleSignInError('signInWithApple', error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithGoogle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authSessionProvider.notifier)
          .signInWithGoogle(ageConfirmedOver18: true);
      if (!mounted) return;
      await _goToAppShell();
    } catch (error, stackTrace) {
      _handleSignInError('signInWithGoogle', error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEmailSignup() async {
    final success = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => const EmailSignupStep(ageConfirmedOver18: true),
      ),
    );
    if (success == true && mounted) await _goToAppShell();
  }

  void _handleSignInError(String source, Object error, StackTrace stackTrace) {
    // Logged so the underlying cause is visible in the console — the
    // toast itself only ever shows a user-safe message, never raw
    // exception detail.
    debugPrint('$source failed: $error\n$stackTrace');
    if (!mounted) return;
    // A cancellation (backed out of the provider's picker, or closed the
    // browser without finishing LinkedIn) isn't really an "error" — a
    // softer, non-alarming toast, not the red error styling a genuine
    // network/server failure gets. Either way the button must always end
    // up clickable again (the `finally` in each _continueWithX already
    // does that) and the user must always see *something*, never be left
    // staring at a stalled spinner with no feedback at all.
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

  // The single insertion point every one of the four sign-up/login paths
  // routes through, right after auth succeeds — ADR-019 §2's new mandatory
  // profile-setup screen goes here, once, so it can't be accidentally
  // skipped by adding a fifth path later. Waits for that screen to pop
  // (its own CONTINUE, once full name is saved) before proceeding to
  // AppShell.
  //
  // "Once" means once per account, not once per `OnboardingFlow` instance
  // — LinkedIn/Apple/Google are resolve-or-create (a returning user who
  // signs out and back in hits this same path again), and email is a real
  // login on a return visit, not just first-time signup. Unconditionally
  // pushing this screen every time re-asked a returning user — who may
  // have already registered and verified a company — to fill it out
  // again. `workEmailVerified` is the one already-reliable signal for
  // "already been through this": it's only ever true after a real,
  // completed company-email verification, which itself requires having
  // already gone through (or reached the same data via) this screen or
  // its ProfilePage equivalent. A user who hasn't verified a company yet
  // — whether they never entered one, or started but never finished the
  // OTP — still sees the screen, same as `pendingVerificationSteps`'
  // existing "no confirmation it's done, so don't skip it" rule; `profile`
  // being null (the fetch right after sign-in failed) falls back the same
  // way, for the same reason.
  Future<void> _goToAppShell() async {
    final state = ref.read(authSessionProvider).value;
    if (state?.profile?.workEmailVerified != true) {
      final fullName = state?.session?.fullName ?? '';
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ProfileSetupScreen(initialFullName: fullName),
        ),
      );
      if (!mounted) return;
    }
    _navigateToAppShell();
  }

  // pushAndRemoveUntil, not pushReplacement: OnboardingFlow itself was
  // pushed on top of LandingPage (LandingPage.push, not replace), so a
  // plain pushReplacement here would leave LandingPage sitting under
  // AppShell in the stack — any tab page with its own AppBar (Matches/
  // Safety/Chats) would then show a back arrow that pops AppShell and
  // strands the user on LandingPage instead of switching tabs. Clearing
  // the whole stack matches the same pattern already used for sign-out
  // (ProfilePage) and forced session expiry (AppShell's own listener).
  void _navigateToAppShell() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const AppShell()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        imageOpacity: 0.35,
        child: switch (_step) {
          _OnboardingStep.ageConfirmation => AgeConfirmationStep(
            onContinue: _onAgeConfirmed,
          ),
          _OnboardingStep.chooseMethod => _chooseMethodStep(),
        },
      ),
    );
  }

  Widget _chooseMethodStep() {
    // iOS shows Apple+LinkedIn; Android shows Google+LinkedIn (scope note,
    // frontend/level0-federated-identity-PLAN.md: Apple has no native
    // Android SDK, and Google Sign-In has no first-class iOS placement
    // requirement the way Apple does on iOS). defaultTargetPlatform, not
    // dart:io Platform, so this stays testable in `flutter test`.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _welcomeStep()),
            const SizedBox(height: 16),
            _trustMicrocopy(),
            const SizedBox(height: 20),
            // Co-equal buttons — same PrimaryButton widget/height for both,
            // differing only in icon/label/handler, so Apple's button is
            // genuinely equal in size and visual weight to LinkedIn's (Apple
            // Guideline 4.8's real placement requirement, not a style
            // choice) by construction rather than by eyeballing two
            // different button styles.
            if (isIOS) ...[
              PrimaryButton(
                label: 'CONTINUE WITH APPLE',
                icon: Icons.apple,
                isLoading: _busy,
                onPressed: _continueWithApple,
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                key: const Key('continueWithLinkedIn'),
                label: 'CONTINUE WITH LINKEDIN',
                isLoading: _busy,
                onPressed: _continueWithLinkedIn,
              ),
            ] else ...[
              PrimaryButton(
                label: 'CONTINUE WITH GOOGLE',
                icon: Icons.g_mobiledata_rounded,
                isLoading: _busy,
                onPressed: _continueWithGoogle,
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                key: const Key('continueWithLinkedIn'),
                label: 'CONTINUE WITH LINKEDIN',
                isLoading: _busy,
                onPressed: _continueWithLinkedIn,
              ),
            ],
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: _busy ? null : _openEmailSignup,
                child: Text(
                  'Sign up with email',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textSecondary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _welcomeStep() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppPalette.candyBlue.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.handshake_outlined,
              size: 64,
              color: AppPalette.candyBlue,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Connect Beyond\nThe Office.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
              height: 1.2,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Meet verified professionals in real life.\nYour next coffee, mentor, or co-founder is nearby.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppPalette.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  /// ADR-014's microcopy — replaces the old LinkedIn-only trust copy, since
  /// LinkedIn is now optional-at-signup rather than mandatory. States
  /// plainly that skipping LinkedIn keeps the account read-only, and that
  /// it can be connected later from Profile (`ProfilePage`'s "Connect
  /// LinkedIn" banner, Step 7) — not a dead end.
  Widget _trustMicrocopy() {
    return SizedBox(
      width: double.infinity,
      child: Text(
        'Signing in without LinkedIn keeps your account more restricted. We do this to ensure a private and secure experience. Connect '
        'LinkedIn anytime during setup or later from your profile to '
        'unlock matching, messaging, and meetups.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          color: AppPalette.textSecondary,
          height: 1.4,
        ),
      ),
    );
  }
}
