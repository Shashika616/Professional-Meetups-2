import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps what is on screen out of screenshots, screen recordings and the
/// app switcher while [child] is mounted (#94).
///
/// For the screens where a glance over someone's shoulder, or a recents
/// thumbnail, would expose something that matters: one-time codes, the
/// people a user trusts in an emergency, and the SOS screen itself.
///
/// - Android: `FLAG_SECURE`. Screenshots and recordings come out black, and
///   the recents preview is blank.
/// - iOS cannot block screenshots. What it can do is keep the app-switcher
///   snapshot from showing the screen, so the window is blurred whenever
///   the app stops being active.
///
/// Counted, so nested or overlapping secure screens (a sheet over a secure
/// page) leave secure mode on until the LAST one goes. A platform failure is
/// swallowed: this is protection on top of the screen, and the screen must
/// keep working without it.
class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child});

  final Widget child;

  static const MethodChannel channel = MethodChannel('tiehere/secure_screen');

  static int _active = 0;

  @visibleForTesting
  static int get activeCount => _active;

  @visibleForTesting
  static void resetForTest() => _active = 0;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    if (SecureScreen._active++ == 0) _invoke('enable');
  }

  @override
  void dispose() {
    if (--SecureScreen._active == 0) _invoke('disable');
    super.dispose();
  }

  static Future<void> _invoke(String method) async {
    try {
      await SecureScreen.channel.invokeMethod<void>(method);
    } catch (_) {
      // No channel (tests, an unsupported platform): the screen still works.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
