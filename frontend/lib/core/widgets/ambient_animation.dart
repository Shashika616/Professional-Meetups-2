/// Freezes every AMBIENT animation in the app.
///
/// # WHAT COUNTS AS AMBIENT
///
/// An animation that repeats forever with no user input driving it: a
/// loading shimmer, an attention pulse. Not a transition, not a gesture
/// response — those start, finish, and settle.
///
/// # WHY IT HAS TO EXIST
///
/// A repeating AnimationController schedules frames forever, and
/// `pumpAndSettle` waits for frames to STOP. Any test that settles while one
/// is on screen hangs until it times out. The shimmer cost eight tests
/// before it was frozen; the review card's pulse cost two more, which is the
/// point at which this stopped being one widget's problem and became a
/// category with one switch.
///
/// # WHY NOT THE ACCESSIBILITY FLAG
///
/// Turning on the OS "reduce motion" setting for the suite also makes
/// Flutter scale EVERY other AnimationController by 0.05
/// (`AnimationBehavior.normal` under `SemanticsBinding.disableAnimations`),
/// which silently broke a legitimate pull-to-refresh test whose gesture
/// timings moved underneath it. This touches ambient animations and nothing
/// else.
///
/// Widgets should still honour the real accessibility setting separately —
/// this is the test seam, not the accessibility feature.
///
/// Deliberately NOT `@visibleForTesting`: that annotation permits the
/// defining library and tests only, and the whole point of this flag is that
/// widgets in other libraries read it. The `debug` prefix carries the same
/// message, and is exactly how Flutter itself ships this kind of switch
/// (`debugDisableShadows`, `debugRepaintRainbowEnabled`).
bool debugDisableAmbientAnimations = false;
