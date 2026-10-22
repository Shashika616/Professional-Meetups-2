import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// `find.byIcon` for the app's own stroke set.
///
/// The icons are authored SVG paths rendered by [AppIcon], not glyphs in a
/// font, so `find.byIcon(IconData)` cannot see them. This matches on the
/// path, which is the icon's identity.
Finder findAppIcon(String path) => find.byWidgetPredicate(
  (w) => w is AppIcon && w.path == path,
  description: 'AppIcon drawing the given path',
);
