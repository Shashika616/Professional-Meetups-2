import 'package:flutter/foundation.dart';

import 'package:professional_connections_platform/core/config/app_version.dart';

/// Set when the server answers 426 to the credit client: this build is too
/// old for what was asked (N1-D4). A static holder because the answer comes
/// from a service with no widget near it, and [UpdateGate] shows the same
/// screen for this as for a too-old version in `/v1/app-config`.
abstract final class UpdateRequired {
  static final ValueNotifier<bool> signalled = ValueNotifier(false);
}

/// True when [current] is older than [minimum]. Both are `1.2.3` or
/// `1.2.3+45`; the build number counts only if [minimum] names one.
///
/// Anything unreadable is false: a typo in a config value must not lock
/// everyone out of the app.
bool isBelowMinimumVersion(
  String minimum, {
  String current = AppVersion.header,
}) {
  final want = _parse(minimum);
  final have = _parse(current);
  if (want == null || have == null) return false;
  for (var i = 0; i < 3; i++) {
    if (have.$1[i] != want.$1[i]) return have.$1[i] < want.$1[i];
  }
  final wantBuild = want.$2;
  return wantBuild != null && (have.$2 ?? 0) < wantBuild;
}

(List<int>, int?)? _parse(String version) {
  final parts = version.trim().split('+');
  if (parts.length > 2) return null;
  final numbers = parts.first.split('.').map(int.tryParse).toList();
  if (numbers.isEmpty || numbers.length > 3 || numbers.contains(null)) {
    return null;
  }
  final digits = [for (final n in numbers) n!];
  while (digits.length < 3) {
    digits.add(0);
  }
  if (parts.length == 1) return (digits, null);
  final build = int.tryParse(parts[1]);
  return build == null ? null : (digits, build);
}
