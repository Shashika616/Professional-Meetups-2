part of 'schedule_flow.dart';

/// One consistent timing step for every meetup, "today" included (ADR-016)
/// — a date picker (defaulting to today) plus typed 24-hour FROM and TO
/// times. Every rule (strict `HH:MM`, start must still be ahead of the
/// clock, an end at or before the start means the next day) lives in
/// `meetup_window_input.dart` as pure functions; this widget only collects
/// input, shows the resolved outcome, and hands a concrete window up.
class _TimingStep extends StatefulWidget {
  const _TimingStep({
    required this.initialStart,
    required this.initialEnd,
    required this.maxAdvanceDays,
    required this.onPick,
  });

  final DateTime? initialStart;
  final DateTime? initialEnd;

  /// How far ahead the date picker reaches: the host's entitlement (14
  /// days free, 30 with a plan), not a number written here.
  final int maxAdvanceDays;

  /// Awaited: CONTINUE shows its spinner until this resolves, since the
  /// flow asks the server about the window before moving on.
  final Future<void> Function(DateTime windowStart, DateTime windowEnd) onPick;

  @override
  State<_TimingStep> createState() => _TimingStepState();
}

class _TimingStepState extends State<_TimingStep> {
  // CONTINUE is waiting on the schedule check.
  bool _checking = false;
  late DateTime _date = widget.initialStart ?? _now();
  TimeOfDay? _from;
  TimeOfDay? _to;

  static DateTime _now() =>
      debugScheduleFlowNowOverride?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _from = widget.initialStart != null
        ? TimeOfDay.fromDateTime(widget.initialStart!)
        : null;
    _to = widget.initialEnd != null
        ? TimeOfDay.fromDateTime(widget.initialEnd!)
        : null;
  }

  ResolvedMeetupWindow? get _resolved {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return null;
    return resolveMeetupWindow(date: _date, from: from, to: to, now: _now());
  }

  Future<void> _pickDate() async {
    final now = _now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(now) ? now : _date,
      firstDate: now,
      lastDate: now.add(Duration(days: widget.maxAdvanceDays)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String? _problemText(ResolvedMeetupWindow r) => switch (r.problem) {
    MeetupWindowProblem.none => null,
    MeetupWindowProblem.endEqualsStart =>
      'End time must be different from the start time.',
    MeetupWindowProblem.startInPast =>
      'That start time has already passed today. Pick a later time or '
          'another date.',
  };

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    final problem = resolved == null ? null : _problemText(resolved);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('When should it happen?'),
        // THE PICTURE SITS ON TOP, NOT DOWN THE SIDE.
        //
        // Both cards used to be a row: copy on the left, a 104pt strip of
        // photograph down the right edge. At that width the artwork was a
        // sliver nobody could read as a picture, and it squeezed the date
        // and the two time fields into two thirds of the card — the
        // "compacted" feeling was mostly this. The screen set draws these
        // as a banner across the top with the content beneath it, which
        // is also the shape the intent tiles and the meetup hero already
        // use everywhere else in the app.
        _BannerCard(
          asset: 'assets/images/schedule/date_card.jpg',
          onTap: _pickDate,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FieldLabel('Date'),
                    const SizedBox(height: 5),
                    Text(
                      formatPickedDate(_date, now: _now()),
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              AppIcon(AppIcons.forward, color: AppPalette.textSecondary),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // FROM and TO side by side in one card — the window is one thing,
        // so it gets one surface.
        _BannerCard(
          asset: 'assets/images/schedule/time_card.jpg',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TimeField24h(
                      label: 'From',
                      initialValue: _from,
                      onChanged: (t) => setState(() => _from = t),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: AppIcon(
                      AppIcons.arrowRight,
                      size: 18,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  Expanded(
                    child: TimeField24h(
                      label: 'To',
                      initialValue: _to,
                      onChanged: (t) => setState(() => _to = t),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Named outright: the fields accept only the 24-hour clock,
              // and a person used to "7:30" needs to be told so before
              // they type it, not by a rejected digit.
              Row(
                children: [
                  AppIcon(
                    AppIcons.clock,
                    size: 13,
                    color: AppPalette.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '24-hour format, e.g. 09:30 or 18:00',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11.5,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (problem != null) ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(AppIcons.warning, size: 16, color: AppPalette.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  problem,
                  style: TextStyle(color: AppPalette.danger, fontSize: 12),
                ),
              ),
            ],
          ),
        ] else if (resolved != null) ...[
          const SizedBox(height: 14),
          // The resolved window read back in one line, with its length —
          // the sanity check that catches a mistyped hour here rather than
          // on the review step. The next-day case gets a second, explicit
          // sentence: "(+1)" alone is timetable shorthand not everyone
          // reads.
          _WindowSummary(
            text: describeWindow(resolved),
            note: resolved.endsNextDay
                ? 'Ends the next day at ${formatTime24h(_to!)}.'
                : null,
          ),
        ],
        // Pushes CONTINUE to the bottom edge when the step does not fill
        // the screen, which until now left a third of the page empty
        // under the button while everything above it was crowded. It
        // collapses to nothing once the keyboard takes the room.
        const Spacer(),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Continue',
          isLoading: _checking,
          onPressed: resolved != null && resolved.isValid && !_checking
              ? () => _continue(resolved.start, resolved.end)
              : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _continue(DateTime start, DateTime end) async {
    setState(() => _checking = true);
    try {
      await widget.onPick(start, end);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }
}

/// A timing-step card: a wide illustration across the top, the content
/// beneath it.
///
/// The artwork keeps its own warm ground rather than being tinted to the
/// theme — it is meant to read as a picture on the card, the way the
/// intent tiles carry their scenes. Decoded at the banner's own width.
class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.asset, required this.child, this.onTap});

  final String asset;
  final Widget child;
  final VoidCallback? onTap;

  // Generous on purpose. At 92 the two cards finished a third of the way
  // down the screen and everything below them was dead space; the step
  // read as crammed into the top even though the page was mostly empty.
  static const double _bannerHeight = 126;
  static const double _radius = 18;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final card = FlatCard(
      radius: _radius,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(_radius - 1),
            ),
            // Sized off the screen rather than a LayoutBuilder: the card
            // is the full width of the step's gutter, and a LayoutBuilder
            // here cannot answer the intrinsic-height question the
            // step's SliverFillRemaining asks of it.
            child: SizedBox(
              height: _bannerHeight,
              child: Image.asset(
                asset,
                fit: BoxFit.cover,
                cacheWidth: (MediaQuery.sizeOf(context).width * dpr).round(),
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: AppPalette.surface),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: child,
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return Pressable(onTap: onTap, child: card);
  }
}

/// The small-caps label the timing cards share with [TimeField24h].
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.3,
      ),
    );
  }
}

/// The one-line readback under the timing fields — green edge like an
/// "active" meetup card, since what it describes is exactly the card that
/// is about to exist.
class _WindowSummary extends StatelessWidget {
  const _WindowSummary({required this.text, this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    // No coloured rule down the left edge, and an opaque tint rather
    // than a translucent one — the same two corrections every other
    // card in the app got. The leading check already carries the green.
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.tintedSurface(
            AppPalette.brandGreen.withValues(alpha: 0.10),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
          child: Row(
            children: [
              AppIcon(
                AppIcons.checkCircle,
                size: 16,
                color: AppPalette.brandGreen,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        note!,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
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

// FALLBACK STOPGAP — commented out, not deleted (frontend/meetup-
// scheduling-PLAN.md's 2026-08-18 testing addendum, Step 3). This manual
// lat/lng/label entry was the original placeholder for the location step
// before any map provider was wired up. It's kept here, fully intact, as
// the emergency fallback if the active map provider (currently Stadia
// Maps via MapLocationStep, see widgets/map_location_step.dart) ever needs
// to be temporarily disabled again — a bad/expired API key, a provider
// outage during a demo, etc. To bring it back: uncomment this block, and
// in the switch statement above swap `MapLocationStep(...)` back for
// `_LocationStep(...)`.
//
// /// **Blocked on Mapbox credentials (ADR-013 § 4)**: the real location step
// /// is a `mapbox_maps_flutter` map + Mapbox Search Box search bar, biased
// /// toward POI-category places, with the existing "Choose a public place..."
// /// safety copy from Safety UX Flows.md shown directly on screen. None of
// /// that is wired here — no Mapbox access token has been provided
// /// (`AppConfig.mapboxAccessToken`/`mapboxSearchAccessToken` are empty
// /// placeholders, see `core/config/app_config.dart`), and per
// /// frontend/meetup-scheduling-PLAN.md's own instruction, a token is never
// /// hardcoded and a missing one fails loudly rather than silently. This
// /// manual lat/lng/label entry is a clearly-labeled temporary stand-in so
// /// the rest of the flow (and CreateMeetup end-to-end) is still testable —
// /// replace this whole widget, not extend it, once real credentials land.
// class _LocationStep extends StatefulWidget {
//   const _LocationStep({required this.onSubmit});
//
//   final void Function(double lat, double lng, String label) onSubmit;
//
//   @override
//   State<_LocationStep> createState() => _LocationStepState();
// }
//
// class _LocationStepState extends State<_LocationStep> {
//   final _labelController = TextEditingController();
//   final _latController = TextEditingController();
//   final _lngController = TextEditingController();
//
//   @override
//   void initState() {
//     super.initState();
//     for (final c in [_labelController, _latController, _lngController]) {
//       c.addListener(_onFieldChanged);
//     }
//   }
//
//   void _onFieldChanged() => setState(() {});
//
//   @override
//   void dispose() {
//     for (final c in [_labelController, _latController, _lngController]) {
//       c.removeListener(_onFieldChanged);
//       c.dispose();
//     }
//     super.dispose();
//   }
//
//   bool get _canContinue =>
//       _labelController.text.trim().isNotEmpty &&
//       double.tryParse(_latController.text.trim()) != null &&
//       double.tryParse(_lngController.text.trim()) != null;
//
//   @override
//   Widget build(BuildContext context) {
//     return Column(
//       crossAxisAlignment: CrossAxisAlignment.stretch,
//       children: [
//         const _StepTitle('Where?'),
//         Container(
//           padding: const EdgeInsets.all(12),
//           decoration: BoxDecoration(
//             color: AppPalette.candyBlue.withValues(alpha: 0.08),
//             borderRadius: BorderRadius.circular(14),
//             border: Border.all(
//               color: AppPalette.candyBlue.withValues(alpha: 0.3),
//             ),
//           ),
//           child: const Text(
//             'Map search is pending a Mapbox access token — enter the '
//             'address and coordinates manually for now. This step will '
//             'be replaced with a real map + search once that\'s set up.',
//             style: TextStyle(color: AppPalette.candyBlue, fontSize: 11),
//           ),
//         ),
//         const SizedBox(height: 16),
//         // Choose a public place — never a stranger's home address
//         // (Safety UX Flows.md's pre-meetup safety copy, ADR-013 § 4).
//         const Text(
//           'Choose a public place — a cafe, restaurant, or well-known '
//           'venue, not a private residence.',
//           style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
//         ),
//         const SizedBox(height: 16),
//         AppTextField(
//           controller: _labelController,
//           icon: AppIcons.pin,
//           hint: 'Venue name / address',
//         ),
//         const SizedBox(height: 12),
//         AppTextField(
//           controller: _latController,
//           icon: AppIcons.explore,
//           hint: 'Latitude (e.g. 6.9271)',
//           keyboardType: const TextInputType.numberWithOptions(
//             decimal: true,
//             signed: true,
//           ),
//         ),
//         const SizedBox(height: 12),
//         AppTextField(
//           controller: _lngController,
//           icon: AppIcons.explore,
//           hint: 'Longitude (e.g. 79.8612)',
//           keyboardType: const TextInputType.numberWithOptions(
//             decimal: true,
//             signed: true,
//           ),
//         ),
//         const SizedBox(height: 20),
//         PrimaryButton(
//           label: 'CONTINUE',
//           onPressed: _canContinue
//               ? () => widget.onSubmit(
//                   double.parse(_latController.text.trim()),
//                   double.parse(_lngController.text.trim()),
//                   _labelController.text.trim(),
//                 )
//               : null,
//         ),
//       ],
//     );
//   }
// }
