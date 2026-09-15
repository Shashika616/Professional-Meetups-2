import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/cafe_scene.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/auth/social_sign_in_section.dart';
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

  /// The user's 18+ attestation, recorded when AgeConfirmationStep's
  /// CONTINUE fires (which it cannot until the box is checked). Held as a
  /// value rather than implied by the step, so the provider calls carry
  /// exactly what the user gave and nothing hardcoded.
  bool _ageConfirmed = false;

  void _onAgeConfirmed() {
    setState(() {
      _ageConfirmed = true;
      _step = _OnboardingStep.chooseMethod;
    });
  }

  // The provider buttons (Apple/Google/LinkedIn) live in
  // SocialSignInSection, shared with the sign-in page. Sign-up and sign-in
  // are the same server call (resolve-or-create), so the only thing this
  // flow adds is where to go afterwards: every path lands on
  // _goToAppShell, the single insertion point for the profile-setup screen.
  // The Level 2/3 phone/personal-email/personal-details/corporate-email
  // sequence no longer runs during initial onboarding; those steps remain
  // reachable from ProfilePage's "Connect LinkedIn" banner.
  Future<void> _onSocialSignedIn(bool isNewUser) => _goToAppShell();

  /// The guest path (ADR-002 § 6). Age confirmation has already happened —
  /// this button only exists on the chooseMethod step, which is only
  /// reachable after it.
  ///
  /// Goes STRAIGHT to AppShell, bypassing _goToAppShell's ProfileSetupScreen
  /// detour: that screen asks a user to confirm their full name and
  /// optionally register a company, and a guest has neither. Their display
  /// name is a handle the server just generated, and there is nothing to
  /// confirm about it.
  Future<void> _continueAsGuest() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authSessionProvider.notifier)
          .guestSignup(ageConfirmedOver18: _ageConfirmed);
      if (!mounted) return;
      _navigateToAppShell();
    } catch (error, stackTrace) {
      _handleSignInError('guestSignup', error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEmailSignup() async {
    final success = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            EmailSignupStep(ageConfirmedOver18: _ageConfirmed),
      ),
    );
    if (success == true && mounted) await _goToAppShell();
  }

  /// [stackTrace] is accepted and deliberately NOT logged — see below. It
  /// stays in the signature because every call site's `catch (error,
  /// stackTrace)` already has it and dropping it would only make the next
  /// person add a `print` back to recover it.
  void _handleSignInError(String source, Object error, StackTrace stackTrace) {
    // TYPE PLUS A SANITIZED MESSAGE, never the raw error object and never
    // the stack trace (which names internal file paths and, for a plugin
    // failure, the plugin's own internals).
    //
    // debugPrint is NOT stripped from release builds. The typed exceptions
    // this codebase throws (AuthException and friends) carry only
    // user-safe messages, so printing those was harmless — but this handler
    // catches every sign-in path, including guestSignup and the OAuth
    // plugins, and an untyped failure here is a raw PlatformException from
    // google_sign_in / sign_in_with_apple or an HTTP client exception. Those
    // put whatever they like in toString(): endpoint URLs, tokens in a
    // request echo, account identifiers. The type name plus our own message
    // is enough to debug from and carries none of it.
    //
    // AuthException.message is safe by construction and worth keeping —
    // it is the same string the toast below shows the user.
    final safeMessage = error is AuthException ? error.message : '';
    debugPrint('$source failed: ${error.runtimeType} $safeMessage');
    if (!mounted) return;
    // A cancellation (backed out of the provider's picker, or closed the
    // browser without finishing LinkedIn) isn't really an "error" — a
    // softer, non-alarming toast, not the red error styling a genuine
    // network/server failure gets. Either way the button must always end
    // up clickable again (the `finally` in _continueAsGuest does that) and
    // the user must always see *something*, never be left staring at a
    // stalled spinner with no feedback at all.
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _welcomeStep()),
            const SizedBox(height: 20),
            // Co-equal buttons — same PrimaryButton widget/height for both,
            // differing only in icon/label/handler, so Apple's button is
            // genuinely equal in size and visual weight to LinkedIn's (Apple
            // Guideline 4.8's real placement requirement, not a style
            // choice) by construction rather than by eyeballing two
            // different button styles.
            // NEUTRAL SURFACE, COLOURED MARK.
            //
            // These were candyBlue-filled with monochrome glyphs. Both brand
            // programmes (Apple's HIG, Google's Sign-In branding) expect the
            // provider's own logo on a plain light or dark button, and a
            // four-colour mark on a tinted fill reads as muddy regardless of
            // the rules. The card surface plus a hairline is the standard
            // treatment and works on both themes.
            //
            // They stay the visually dominant pair through fill and
            // elevation, not colour: the alternatives below are outlined
            // with no fill at all.
            SocialSignInSection(
              onSignedIn: _onSocialSignedIn,
              // Real: this step is only reachable after AgeConfirmationStep
              // was checked and continued (see _onAgeConfirmed).
              ageConfirmedOver18: _ageConfirmed,
              onBusyChanged: (busy) => setState(() => _busy = busy),
            ),
            const SizedBox(height: 18),
            // A divider, so the OAuth buttons read as one group and the two
            // other ways in read as alternatives rather than as fine print
            // trailing off the bottom of the screen.
            const OrDivider(),
            const SizedBox(height: 14),
            // PROMOTED FROM A 13px TEXT LINK. Email signup is a real, equal
            // way to create an account — it just isn't the one-tap one — so
            // it now looks like a button. Outlined rather than filled keeps
            // the OAuth pair visually primary without making this one look
            // like fine print.
            // BOTH ARE REAL BUTTONS NOW, each with a leading icon.
            //
            // They were 13px text links — the guest one without even an
            // underline, so nothing marked it as tappable, and its tap
            // target was about half the 44px minimum. "Weakest entry point"
            // (ADR-033 §1 keeps a guest's view deliberately reduced) was
            // being rendered as "almost invisible", which is a different
            // thing and cost real signups.
            //
            // The hierarchy is now carried by FILL rather than by size:
            // filled OAuth buttons, then an accent-outlined email button,
            // then a plain-outlined guest button. All four are obviously
            // controls; only one tier looks like the default.
            SecondaryButton(
              key: const Key('signUpWithEmail'),
              label: 'SIGN UP WITH EMAIL',
              icon: Icons.mail_outline_rounded,
              height: 52,
              color: AppPalette.candyBlue,
              borderColor: AppPalette.candyBlue.withValues(alpha: 0.55),
              onPressed: _busy ? null : _openEmailSignup,
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              key: const Key('continueAsGuest'),
              label: 'CONTINUE AS GUEST',
              icon: Icons.explore_outlined,
              height: 52,
              color: AppPalette.textPrimary,
              onPressed: _busy ? null : _continueAsGuest,
            ),
          ],
        ),
      ),
    );
  }

  Widget _welcomeStep() {
    // Scrollable so it SHRINKS rather than overflows when the fixed block
    // beneath it (buttons + microcopy) is tall relative to the viewport.
    // Before ADR-002 § 6 added the guest entry point this had just enough
    // slack to get away with a plain Center; it no longer does, and a short
    // phone would have hit the same overflow eventually regardless. At normal
    // sizes nothing scrolls and it renders identically.
    // Heading first, then the picture. The generic handshake icon that used
    // to lead this screen said nothing the words below it did not already say
    // better, and it pushed the actual promise down the page. Reading order
    // now matches the hierarchy: what this is, then what it looks like, then
    // how to get in.
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
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
          const SizedBox(height: 14),
          Text(
            'Meet verified professionals in real life.\nYour next coffee, mentor, or co-founder is nearby.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppPalette.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          // Sized off the viewport rather than fixed: this sits above four
          // buttons and a paragraph, and on a short phone a fixed illustration
          // is the thing that pushes the sign-in options off screen. Clamped
          // so it neither disappears on small displays nor balloons on a
          // tablet.
          Builder(
            builder: (context) {
              final h = MediaQuery.sizeOf(context).height;
              return CafeScene(height: (h * 0.26).clamp(150.0, 260.0));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
