/// This build's version, as the server sees it in `X-App-Version`.
///
/// A constant rather than `package_info_plus`, which is held back by the
/// win32 constraint noted in pubspec.yaml. `test/app_version_test.dart`
/// fails the build if this and pubspec.yaml's `version:` ever disagree, so
/// bumping one without the other cannot ship.
///
/// 1.1.0 is the first build with the credits screens: the server refuses
/// to create a meetup for anything older (`MIN_CREDITS_APP_VERSION`, plan
/// 29 D11), because an older build cannot show what it costs.
abstract final class AppVersion {
  static const String name = '1.1.0';
  static const int build = 8;

  /// What `X-App-Version` carries: `1.1.0+8`.
  static const String header = '$name+$build';
}
