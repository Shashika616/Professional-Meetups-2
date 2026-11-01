import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';

/// Emits `screen_viewed` (no duration) or `screen_left` (with one).
typedef ScreenSink =
    void Function(String event, String screen, int? durationMs);

/// Which screen the user is looking at, and for how long (plan 29E).
///
/// A [NavigatorObserver] on the app's navigator keeps a stack of the named
/// routes; the visible screen is the top one, except that the signed-in
/// shell reports its current tab. Every change of visible screen emits
/// `screen_left` for the old one, with the time it was on screen, and
/// `screen_viewed` for the new one, so a return to a screen counts as a
/// view of it.
///
/// Time on screen excludes time in the background: [pause] and [resume]
/// come from the app lifecycle.
///
/// A [NavigatorObserver] may belong to one navigator at a time, and the
/// theme switch remounts the app (a second navigator before the first is
/// gone), so each navigator gets its own [observer] forwarding here.
///
/// Routes without a name (a context menu, an unnamed dialog) do not change
/// the screen: what is underneath is still what the user is on.
class ScreenTracker {
  ScreenTracker(this._sink);

  final ScreenSink _sink;

  final List<_Entry> _stack = [];
  int _tab = 0;

  String? _screen;
  DateTime? _since;
  int _accumulatedMs = 0;
  bool _paused = false;

  int _generation = 0;

  /// The screen showing now.
  String? get current => _screen;

  /// Bumped on every screen change.
  int get generation => _generation;

  static String? _nameOf(Route<dynamic> route) {
    final name = route.settings.name;
    if (name == null) return null;
    // MaterialApp's `home` is the initial route, named '/'.
    return name == Navigator.defaultRouteName ? ScreenNames.splash : name;
  }

  String? _visible() {
    if (_stack.isEmpty) return null;
    final top = _stack.last.name;
    return top == ScreenNames.appShell ? ScreenNames.tab(_tab) : top;
  }

  /// A fresh observer for one navigator, feeding this tracker.
  NavigatorObserver observer() => _Forwarder(this);

  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = _nameOf(route);
    if (previousRoute == null) {
      // A new navigator (first launch, or the theme switch remounting the
      // app): whatever the old one held is gone.
      _stack.clear();
    }
    if (name == null) return;
    _stack.add(_Entry(route, name));
    _show(_visible());
  }

  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = _stack.indexWhere((e) => identical(e.route, oldRoute));
    final name = newRoute == null ? null : _nameOf(newRoute);
    if (i >= 0) {
      if (name == null) {
        _stack.removeAt(i);
      } else {
        _stack[i] = _Entry(newRoute!, name);
      }
    } else if (name != null) {
      _stack.add(_Entry(newRoute!, name));
    }
    _show(_visible());
  }

  void _drop(Route<dynamic> route) {
    final before = _stack.length;
    _stack.removeWhere((e) => identical(e.route, route));
    if (_stack.length != before) _show(_visible());
  }

  /// The shell's tab changed.
  void tabChanged(int index) {
    _tab = index;
    if (_stack.isNotEmpty && _stack.last.name == ScreenNames.appShell) {
      _show(_visible());
    }
  }

  /// The app went to the background: the clock stops.
  void pause() {
    if (_paused) return;
    _paused = true;
    if (_since != null) {
      _accumulatedMs += clock.now().difference(_since!).inMilliseconds;
      _since = null;
    }
  }

  /// Back in the foreground: the clock runs again.
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_screen != null) _since = clock.now();
  }

  /// Ends the current visit and starts a new one of the same screen (a new
  /// session begins while the user is on it).
  void restartVisit() {
    final screen = _screen;
    if (screen == null) return;
    _leave();
    _enter(screen);
  }

  void _show(String? screen) {
    if (screen == _screen) return;
    _generation++;
    _leave();
    if (screen != null) _enter(screen);
  }

  void _enter(String screen) {
    _screen = screen;
    _accumulatedMs = 0;
    _since = _paused ? null : clock.now();
    _sink(AnalyticsEvent.screenViewed, screen, null);
  }

  void _leave() {
    final screen = _screen;
    if (screen == null) return;
    var ms = _accumulatedMs;
    if (_since != null) ms += clock.now().difference(_since!).inMilliseconds;
    _screen = null;
    _since = null;
    _accumulatedMs = 0;
    _sink(AnalyticsEvent.screenLeft, screen, ms < 0 ? 0 : ms);
  }
}

class _Entry {
  _Entry(this.route, this.name);
  final Route<dynamic> route;
  final String name;
}

class _Forwarder extends NavigatorObserver {
  _Forwarder(this._tracker);
  final ScreenTracker _tracker;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _tracker.didPush(route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _tracker.didPop(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _tracker.didRemove(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _tracker.didReplace(newRoute: newRoute, oldRoute: oldRoute);
}
