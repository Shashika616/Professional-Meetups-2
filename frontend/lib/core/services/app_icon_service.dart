import 'package:flutter/services.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// Keeps the home screen icon in step with the app's theme: the onyx icon by
/// default, the white one in the light theme. Android applies it when the app
/// next leaves the screen; iOS applies it at once, with its own alert.
///
/// Cosmetic, so a platform without the channel changes nothing.
abstract final class AppIconService {
  static const _channel = MethodChannel('tiehere/app_icon');

  static Future<void> apply(AppThemeMode mode) async {
    try {
      await _channel.invokeMethod<void>('set', mode.name);
    } on MissingPluginException {
      // Web, desktop and tests.
    } on PlatformException {
      // The icon stays as it was.
    }
  }
}
