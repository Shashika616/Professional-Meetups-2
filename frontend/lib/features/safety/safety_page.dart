import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/widgets/secure_screen.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// Emergency phone number dialed by "Call emergency services" — Sri Lanka's
/// general emergency line (the launch market, see
/// `docs/00-project/vision.md`).
///
/// This is deliberately NOT a picker, unlike the phone-verification field,
/// which now has one. The two are different problems: a member's own
/// number can belong to any country, but the emergency line that reaches
/// help depends on where the member physically is, and this app does not
/// establish that reliably enough to dial on someone's behalf.
const String _emergencyServicesNumber = '119';

class SafetyPage extends ConsumerStatefulWidget {
  const SafetyPage({super.key});

  @override
  ConsumerState<SafetyPage> createState() => _SafetyPageState();
}

/// # WHY THIS STATE IS KEPT ALIVE
///
/// Same reason as the other three tabs: AppShell's `PageView` disposes the
/// tab you swipe away from, and remounting re-runs everything the page reads.
/// This page has no network fetch of its own, so it never showed the grey
/// skeleton — but it does hold scroll position and the trusted-contacts
/// sheet's state, and a tab that silently jumps back to the top when you
/// return is the same class of bug with a quieter symptom.
///
/// Kept consistent with its three siblings deliberately: one tab behaving
/// differently from the rest is worse than the small cost of holding a
/// stateless-ish page alive.
/// The trust level trusted contacts and SOS require (ADR-003) — the same
/// floor as joining a meetup. Mirrors the backend's safetyFeatureTrustFloor;
/// the server is what enforces it, this is here so the UI can explain the
/// lock instead of letting the call fail.
const safetyFeatureTrustLevel = 2;

class _SafetyPageState extends ConsumerState<SafetyPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required by the mixin — see [_HomePageState] for the full reasoning.
    super.build(context);

    // Watched, not read at tap time: authSessionProvider is an AsyncNotifier,
    // and a tap-time read on a provider nothing is watching yet returns
    // AsyncLoading — which would read as Level 0 and lock out a verified
    // user. Same shape meetup_detail_page.dart uses.
    final trustLevel = ref.watch(
      authSessionProvider.select((s) => s.value?.profile?.trustLevel ?? 0),
    );

    final checklist = [
      'Meet in a public place',
      'Tell a trusted contact where you are going',
      'Keep first meetings short',
      'Never share OTP codes',
      'Never send money',
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      // extendBodyBehindAppBar so AppBackground paints the app-bar strip
      // too — without it the (transparent) bar shows through to nothing and
      // sits as a flat band above the image. Same shape as
      // verification_checklist_page.dart's Scaffold.
      //
      // Safe to add even though this is also an AppShell tab, where the
      // shell already paints one: AppBackground detects an enclosing
      // instance and returns its child untouched, so the nested case costs
      // nothing. It only actually paints on the pushed route from Profile,
      // which is where the background was missing.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Safety center')),
      body: AppBackground(
        // SafeArea is not optional alongside extendBodyBehindAppBar: the
        // flag makes the body start at y=0, under the bar and the status
        // bar. The bar's height is folded into MediaQuery's top padding, so
        // this is what puts the content back below it — without it the
        // checklist drew over the clock and the title.
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading('Pre meetup checklist'),
                const SizedBox(height: 12),
                // One scrolling column rather than a ListView of checklist
                // items alone: the trusted-contacts section below has to share
                // this space, and pinning SOS at the bottom means everything
                // above it needs somewhere to go on a short screen.
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      // ONE card with divided rows, not five cards each
                      // carrying the same lightbulb.
                      //
                      // Two things were wrong with the old shape. Five
                      // identical glyphs down the left edge is wallpaper:
                      // an icon that never varies carries no information
                      // and just widens the text column's left margin.
                      // And five separate cards made five pieces of advice
                      // look like five separate objects, when they are one
                      // list — the Trusted contacts section directly below
                      // was already one card with divided rows, so the page
                      // disagreed with itself.
                      //
                      // (The icons were green check_circles before that,
                      // which was worse: a tick says "done", and these are
                      // advice to read, not steps the app can know anyone
                      // took. Nothing here is tickable, so nothing here is
                      // drawn as a checkbox either.)
                      FlatCard(
                        radius: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            for (final item in checklist) ...[
                              if (item != checklist.first)
                                Divider(height: 1, color: AppPalette.hairline),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // A small dot, the one mark that can
                                    // repeat down a list without becoming
                                    // noise, because that is what a bullet
                                    // is for.
                                    Container(
                                      margin: const EdgeInsets.only(
                                        top: 6,
                                        right: 12,
                                      ),
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: AppPalette.textTertiary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        item,
                                        style: TextStyle(
                                          color: AppPalette.textPrimary,
                                          fontSize: 13.5,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      const SectionHeading('Trusted contacts'),
                      const SizedBox(height: 12),
                      _TrustedContactsSection(trustLevel: trustLevel),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Pressable(
                  onTap: () => _onSosTapped(context, ref, trustLevel),
                  child: FlatCard(
                    radius: 18,
                    tint: AppPalette.danger.withValues(alpha: 0.12),
                    border: AppPalette.danger.withValues(alpha: 0.5),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // dangerOnTint, not danger: this is danger-coloured
                        // content ON a danger tint, which measures 3.86:1
                        // with the plain colour (UI review #23). The border
                        // and the tint keep using `danger` — a 1px edge and
                        // a wash are not text.
                        AppIcon(
                          AppIcons.broadcast,
                          color: AppPalette.dangerOnTint,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Trigger SOS',
                          style: TextStyle(
                            color: AppPalette.dangerOnTint,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Was `80 + MediaQuery.padding.bottom` to clear AppShell's old
                // floating bar, which the body drew underneath via
                // extendBody: true. Both are gone (ADR-032 round 2) — the
                // Scaffold now lays this body out above a flush, pinned
                // AppBottomBar, so any clearance here would just be dead space
                // at the end of the scroll. Kept as ordinary bottom breathing
                // room only.
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Real SOS entry point (ADR-026, replacing the old canned-toast
  /// confirm). Checks trusted contacts first — zero contacts routes to the
  /// manage-contacts screen instead of ever showing the confirm dialog, so
  /// CONFIRM can never silently "succeed" with nobody to notify.
  Future<void> _onSosTapped(
    BuildContext context,
    WidgetRef ref,
    int trustLevel,
  ) async {
    // ADR-003. This one check covers both safety actions: the SOS trigger
    // below, and the add-a-contact screen this method routes to when the
    // caller has none. UX only — the server gate is what is enforced.
    if (trustLevel < safetyFeatureTrustLevel) {
      _routeToSafetyUnlock(context);
      return;
    }

    final List<TrustedContact> contacts;
    try {
      contacts = await ref.read(authServiceProvider).listTrustedContacts();
    } on ForbiddenActionException {
      // The client check above passed but the server refused — a cached
      // profile that is behind the real trust level. Same destination
      // rather than a raw error toast, so a stale read is indistinguishable
      // from a fresh one to the user.
      if (context.mounted) _routeToSafetyUnlock(context);
      return;
    } on AuthException catch (error) {
      if (context.mounted) {
        showSnack(context, error.message, type: ToastType.error);
      }
      return;
    }
    if (!context.mounted) return;

    if (contacts.isEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (context) =>
              const ManageTrustedContactsPage(explainSosPrompt: true),
        ),
      );
      return;
    }

    // A sheet, not a centred dialog (showAppSheet's own comment has the
    // reasoning): this is the hardest confirmation in the app to get right,
    // and it belongs where the thumb already is.
    await showAppSheet<void>(
      context,
      builder: (dialogContext) => _SosConfirmDialog(ref: ref),
    );
  }

  /// The locked-tap treatment, identical in shape to meetup_card.dart's
  /// `_handleLockedTap` — a toast saying what is locked and why, then the
  /// checklist that unlocks it. Never a dead button or a raw error.
  static void _routeToSafetyUnlock(BuildContext context) {
    showSnack(
      context,
      'Trusted contacts and SOS require Level $safetyFeatureTrustLevel '
      'trust. Verify your phone, personal email, and details to unlock them.',
      type: ToastType.locked,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VerificationChecklistPage(
          title: 'Unlock safety features',
          description:
              'Complete these to reach Level 2 trust and unlock trusted '
              'contacts and SOS.',
        ),
      ),
    );
  }
}

/// Who would be alerted, and the way to add more of them.
///
/// # WHY THIS EXISTS
///
/// Adding a trusted contact was reachable from exactly one place: the SOS
/// button, and only when the caller had ZERO contacts. The moment someone
/// added their first, the manage screen became unreachable — so the cap of
/// three was real but only the first slot was usable. This makes the list
/// visible and the remaining slots reachable, and says what the cap is
/// rather than leaving it to be discovered by hitting it.
///
/// Below Level 2 (ADR-003) it shows the locked treatment instead and never
/// fetches: the contacts belong to a feature the caller cannot use yet, and
/// asking the server for a list it would refuse to add to is a round trip
/// for nothing.
class _TrustedContactsSection extends ConsumerWidget {
  const _TrustedContactsSection({required this.trustLevel});

  final int trustLevel;

  Future<void> _openManage(BuildContext context, WidgetRef ref) async {
    if (trustLevel < safetyFeatureTrustLevel) {
      _SafetyPageState._routeToSafetyUnlock(context);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => const ManageTrustedContactsPage(),
      ),
    );
    // The manage screen adds and removes; this list has to reflect that on
    // the way back.
    ref.invalidate(trustedContactsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (trustLevel < safetyFeatureTrustLevel) {
      return _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: [
          _ContactsHint(
            icon: AppIcons.lock,
            text:
                'Verify your account to add the people we should alert in an '
                'emergency.',
            // The card already routed here; now it says so.
            action: 'Verify',
          ),
        ],
      );
    }

    final contactsAsync = ref.watch(trustedContactsProvider);
    return contactsAsync.when(
      // A skeleton in the shape of the rows it stands in for, inside the
      // same card, so the section keeps its size while it loads. On a
      // failure the skeleton holds a moment, then the card says so in the
      // app's one failure style, still tappable through to manage.
      loading: () => _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: const [_ContactsSkeletonRows()],
      ),
      error: (error, _) => _ContactsCard(
        onTap: () => _openManage(context, ref),
        children: [
          SkeletonThenFailure(
            skeleton: const _ContactsSkeletonRows(),
            failure: LoadFailedState(
              compact: true,
              failure: LoadFailure.of(error),
              onRetry: () => ref.invalidate(trustedContactsProvider),
            ),
          ),
        ],
      ),
      data: (contacts) {
        final remaining = maxTrustedContacts - contacts.length;
        return _ContactsCard(
          onTap: () => _openManage(context, ref),
          children: [
            if (contacts.isEmpty)
              _ContactsHint(
                icon: AppIcons.personAdd,
                text:
                    'No one yet. Add someone we should alert if you trigger '
                    'SOS.',
              )
            else
              for (final contact in contacts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      // The person, as a person: initials in the app's
                      // avatar rather than one generic glyph repeated
                      // down the list. The number lives on the Trusted
                      // contacts page, which this list leads to — here it
                      // was a second line of small grey type against the
                      // one name that matters.
                      ProfessionalAvatar(name: contact.name, size: 32),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          contact.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            Divider(height: 18, color: AppPalette.hairline),
            Row(
              children: [
                AppIcon(
                  remaining > 0 ? AppIcons.plusCircle : AppIcons.checkCircle,
                  size: 18,
                  color: remaining > 0
                      ? AppPalette.candyBlue
                      : AppPalette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // States the cap either way, so it is known before it is
                    // hit rather than discovered by being refused.
                    remaining > 0
                        ? 'Add a contact · ${contacts.length} of '
                              '$maxTrustedContacts added'
                        : 'All $maxTrustedContacts contacts added · tap to '
                              'manage',
                    style: TextStyle(
                      color: remaining > 0
                          ? AppPalette.textPrimary
                          : AppPalette.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AppIcon(
                  AppIcons.forward,
                  size: 18,
                  color: AppPalette.textSecondary,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ContactsCard extends StatelessWidget {
  const _ContactsCard({required this.onTap, required this.children});

  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // opaque so the whole card is the target, not just the painted rows.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FlatCard(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _ContactsHint extends StatelessWidget {
  const _ContactsHint({required this.icon, required this.text, this.action});

  final String icon;
  final String text;

  /// A label for what tapping does, shown with a chevron.
  ///
  /// # WHY THIS EXISTS (UI review #21)
  ///
  /// The review said the locked card "has no button or link". It was half
  /// right in a way worth spelling out: the whole card has always been
  /// tappable and routes to the unlock screen, so the ACTION was there —
  /// nothing told the user about it. A lock icon above a grey sentence looks
  /// exactly like a disabled state, and the one thing a disabled state
  /// means is "do not bother tapping this".
  ///
  /// So this is not a new destination, just the affordance the existing one
  /// never had. No new call, no new route, no new state.
  final String? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(icon, size: 17, color: AppPalette.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 8),
          Text(
            action!,
            style: TextStyle(
              // candyBlue, the app's one action colour: this reads as a
              // link, which is what it behaves like.
              color: AppPalette.candyBlue,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          AppIcon(AppIcons.forward, size: 18, color: AppPalette.candyBlue),
        ],
      ],
    );
  }
}

/// The SOS confirm dialog — extracted as its own widget (rather than an
/// inline `AlertDialog` like the old fake version) because it now needs its
/// own mutable state: CONFIRM triggers a real, multi-step async flow
/// (fresh location read → triggerSos call) with a loading state and a real
/// result to show, not an instant `Navigator.pop`.
class _SosConfirmDialog extends StatefulWidget {
  const _SosConfirmDialog({required this.ref});

  final WidgetRef ref;

  @override
  State<_SosConfirmDialog> createState() => _SosConfirmDialogState();
}

enum _SosDialogPhase { confirming, sending, succeeded, failed }

class _SosConfirmDialogState extends State<_SosConfirmDialog> {
  /// Shorter than the map picker's, for the same reason the SOS request
  /// itself is: somebody is waiting during an emergency. A fix that has
  /// not arrived in eight seconds is not going to change the outcome,
  /// and the alert is better sent without it.
  static const Duration _sosLocationTimeout = Duration(seconds: 8);
  static const Duration _sosLocationFallback = Duration(seconds: 5);

  _SosDialogPhase _phase = _SosDialogPhase.confirming;
  String _resultMessage = '';

  /// True once an attempt has been made without a usable location, so
  /// the success line can say so — a contact who gets "Location
  /// unavailable" should not be a surprise to the person who sent it.
  bool _sentWithoutLocation = false;

  Future<void> _confirm() async {
    setState(() => _phase = _SosDialogPhase.sending);

    // # THE LOCATION IS BEST-EFFORT, AND NEVER A REASON NOT TO SEND
    //
    // This used to await requestCurrentLocation() in the same try as the
    // alert, so LocationUnavailableException ended the whole thing in a
    // failure state (tracker #78, review finding N-D2). Being indoors,
    // having denied the permission once, or simply a slow fix therefore
    // disabled the one feature whose entire purpose is to work when
    // things have gone wrong.
    //
    // Now a failed read costs the coordinates and nothing else: the
    // alert goes out saying the location is unavailable, which a trusted
    // contact can act on. Silence is not.
    double? latitude;
    double? longitude;
    try {
      final position = await requestCurrentLocation(
        accuracy: LocationAccuracy.medium,
        timeLimit: _sosLocationTimeout,
        gpsFallbackLimit: _sosLocationFallback,
      );
      latitude = position.latitude;
      longitude = position.longitude;
    } catch (_) {
      // Deliberately bare. Permission denied, services off, a timeout,
      // or a platform channel that threw something undocumented all mean
      // the same thing here — no coordinates — and none of them is worth
      // failing an emergency alert over.
    }

    try {
      final contactsNotified = await widget.ref
          .read(authServiceProvider)
          .triggerSos(
            contextMessage: 'Triggered from the Safety Center.',
            latitude: latitude,
            longitude: longitude,
          );
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.succeeded;
        _sentWithoutLocation = latitude == null || longitude == null;
        _resultMessage = contactsNotified == 1
            ? '1 trusted contact was alerted.'
            : '$contactsNotified trusted contacts were alerted.';
      });
    } on SessionExpiredException {
      // SessionExpiredException is an AuthException, so without this
      // clause first it fell into the one below and showed "failed" with
      // a message the user could only retry — on a session that is
      // already gone.
      if (mounted) {
        widget.ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.failed;
        _resultMessage = error.message;
      });
    } catch (error) {
      // # NOTHING ESCAPES THIS METHOD (finding N-D3)
      //
      // Any throw that was not an AuthException used to propagate out of
      // _confirm and leave the sheet sitting on "Getting your location
      // and alerting your contacts…" forever, with no way to tell that
      // it had failed. During an emergency.
      //
      // Whatever it was, the user has the same two things to do: try
      // again, or call emergency services. Both are on the failure
      // state.
      if (!mounted) return;
      setState(() {
        _phase = _SosDialogPhase.failed;
        _resultMessage =
            'Could not send the alert. Try again, or call emergency services.';
      });
    }
  }

  Future<void> _callEmergencyServices() async {
    await launchUrl(Uri(scheme: 'tel', path: _emergencyServicesNumber));
  }

  // Kept out of screenshots, recordings and the app switcher (#94):
  // the SOS sheet: where you are, and who is about to be told.
  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: _buildSecured(context));

  Widget _buildSecured(BuildContext context) {
    return AppSheet(
      title: 'Emergency SOS',
      titleColor: AppPalette.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildContent(),
          const SizedBox(height: 18),
          // Stacked full-width, not a right-aligned row of text buttons:
          // the dialog's actions were three words in a corner, and in a
          // sheet the action the user came for should be the widest thing
          // on it. Same labels, same order of preference, same behaviour.
          ..._buildActions(context),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_phase) {
      case _SosDialogPhase.confirming:
        return Text(
          'This will share your live location with your trusted contacts.',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        );
      case _SosDialogPhase.sending:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppPalette.danger,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Getting your location and alerting your contacts…',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
            ),
          ],
        );
      case _SosDialogPhase.succeeded:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.checkCircle,
                  color: AppPalette.verified,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _resultMessage,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            // Said out loud, because the contact's message says it too:
            // they were told the location is unavailable, and the person
            // who sent it should know that before they assume help is on
            // its way to the right place.
            if (_sentWithoutLocation) ...[
              const SizedBox(height: 8),
              Text(
                'Your location could not be determined, so the alert says so. '
                'Call your contacts if they need to find you.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ],
          ],
        );
      case _SosDialogPhase.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(AppIcons.warning, color: AppPalette.danger, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _resultMessage,
                style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
              ),
            ),
          ],
        );
    }
  }

  List<Widget> _buildActions(BuildContext context) {
    // "Call emergency services" is available in every phase — it works
    // independent of whether triggerSos succeeds or fails, and has no
    // backend dependency at all (ADR-026 §6).
    final callAction = TextButton(
      onPressed: _callEmergencyServices,
      child: Text(
        'Call emergency services',
        style: TextStyle(color: AppPalette.danger, fontWeight: FontWeight.w700),
      ),
    );

    switch (_phase) {
      case _SosDialogPhase.confirming:
        return [
          PrimaryButton(
            label: 'Confirm',
            height: 50,
            fillColor: AppPalette.danger,
            foregroundColor: Colors.white,
            onPressed: _confirm,
          ),
          const SizedBox(height: 8),
          callAction,
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
        ];
      case _SosDialogPhase.sending:
        return [callAction];
      case _SosDialogPhase.failed:
        // RETRY FIRST (#78). A failed alert has exactly two useful
        // answers and this is the cheaper one: the common failure is a
        // dropped connection, where pressing it again works. Calling
        // emergency services sits directly under it for when it does
        // not.
        return [
          PrimaryButton(
            label: 'Retry',
            height: 50,
            fillColor: AppPalette.danger,
            foregroundColor: Colors.white,
            onPressed: _confirm,
          ),
          const SizedBox(height: 8),
          callAction,
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(color: AppPalette.textPrimary),
            ),
          ),
        ];
      case _SosDialogPhase.succeeded:
        return [
          callAction,
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(color: AppPalette.textPrimary),
            ),
          ),
        ];
    }
  }
}

/// Two placeholder contact rows, shimmering, for the card while the list
/// loads or (briefly) after it failed.
class _ContactsSkeletonRows extends StatelessWidget {
  const _ContactsSkeletonRows();

  @override
  Widget build(BuildContext context) {
    return SkeletonLoader(
      child: Column(
        children: [
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: const [
                  SkeletonBox(width: 17, height: 17, radius: 9),
                  SizedBox(width: 10),
                  Expanded(
                    child: SkeletonBox(width: double.infinity, height: 12),
                  ),
                  SizedBox(width: 24),
                  SkeletonBox(width: 60, height: 10),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
