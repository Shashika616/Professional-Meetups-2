import 'package:flutter/widgets.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/flow_tracker.dart';

/// Typed, allowlisted attribute values: bool, int or a short lowercase
/// identifier. Never free text (the server drops it anyway).
typedef Attributes = Map<String, Object>;

/// The catalogued controls `track` may name (generated from the registry).
typedef Cta = AnalyticsCta;

/// The app's usage analytics (plan 29 §4, 29E): sessions, screens, the
/// catalogued controls, funnels and friction, sent in batches to
/// `POST /v1/analytics/events`.
///
/// # NEVER IN THE WAY
///
/// Every method returns immediately and none of them throws. Events go to a
/// bounded in-memory queue (persisted, 500 at most, oldest dropped) and are
/// sent in the background. Nothing is recorded or sent while the user has
/// opted out, while the server has analytics switched off, or for an install
/// outside the sample.
///
/// # PRIVACY
///
/// Only what the registry allows leaves the device: event names, screen,
/// flow and step names from the catalogue, and typed attributes. No names,
/// emails, phones, free text, meetup labels, coordinates, receipts or user
/// ids; the server derives the account key from the session itself.
abstract class Analytics {
  /// The app's instance. A no-op until `main()` installs the real client,
  /// which keeps tests (and anything built outside `main()`) silent.
  static Analytics instance = NoopAnalytics();

  /// Records [name] (an `AnalyticsEvent` constant). [screen] defaults to
  /// the screen showing now.
  void record(
    String name, {
    Attributes attributes = const {},
    String? screen,
    String? flowId,
    String? flowStep,
  });

  /// `cta_tapped` for one of the catalogued controls ([Cta]).
  void cta(String cta) => record(
    AnalyticsEvent.ctaTapped,
    attributes: {AnalyticsAttribute.cta: cta},
  );

  /// The funnel [flowId] (an `AnalyticsFlow` constant).
  FlowTracker flow(String flowId);

  /// A new observer for one navigator, feeding the screen tracker. One per
  /// navigator: the theme switch builds a second one before the first goes.
  NavigatorObserver newNavigatorObserver();

  /// The shell's tab changed (tap or swipe).
  void tabChanged(int index);

  /// The screen showing now, or null.
  String? get currentScreen;

  /// Bumped on every screen change (the rage-tap detector's "no navigation").
  int get navigationGeneration;

  /// App lifecycle: sessions, time on screen, flushing on background.
  void lifecycleChanged(AppLifecycleState state);

  /// Whether the user switched analytics off in Privacy Controls.
  bool get optedOut;

  /// Stores the choice; turning it off clears the queue and stops
  /// recording, and tells the server when signed in.
  Future<void> setOptedOut(bool optedOut);

  /// A new install id, so what follows cannot be joined to the account that
  /// just left this phone (N1-D5). Sends what is queued first, then starts
  /// clean.
  Future<void> rotateInstallId();

  /// The server's `analytics.enabled` and `analytics.sample_rate` (0-100).
  void applyRemoteConfig({required bool enabled, required int sampleRate});

  /// Sends what is queued (best effort).
  Future<void> flush();
}

/// Does nothing: the default, and what tests run with.
class NoopAnalytics extends Analytics {
  NoopAnalytics();

  @override
  void record(
    String name, {
    Attributes attributes = const {},
    String? screen,
    String? flowId,
    String? flowStep,
  }) {}

  @override
  FlowTracker flow(String flowId) => FlowTracker.noop(flowId);

  @override
  NavigatorObserver newNavigatorObserver() => NavigatorObserver();

  @override
  void tabChanged(int index) {}

  @override
  String? get currentScreen => null;

  @override
  int get navigationGeneration => 0;

  @override
  void lifecycleChanged(AppLifecycleState state) {}

  @override
  bool get optedOut => false;

  @override
  Future<void> setOptedOut(bool optedOut) async {}

  @override
  Future<void> rotateInstallId() async {}

  @override
  void applyRemoteConfig({required bool enabled, required int sampleRate}) {}

  @override
  Future<void> flush() async {}
}

/// `cta_tapped` for one of the catalogued controls: `track(Cta.sos)`.
void track(String cta) => Analytics.instance.cta(cta);

/// `error_shown` with a kind (an identifier such as `load_failed`), never
/// the message the user saw.
void trackError(String kind) => Analytics.instance.record(
  AnalyticsEvent.errorShown,
  attributes: {AnalyticsAttribute.kind: kind},
);

/// The route template of a request, as `api_error` and `request_timeout`
/// report it: the method and the path with ids replaced, never the query
/// or the host. `GET /v1/meetups/9f2c.../requests` becomes
/// `get:v1.meetups.:id.requests`.
String routeTemplate(String method, Uri url) {
  final parts = [
    for (final segment in url.pathSegments)
      if (segment.isNotEmpty) _templateSegment(segment),
  ];
  final route = '${method.toLowerCase()}:${parts.join('.')}';
  return route.length <= 100 ? route : route.substring(0, 100);
}

final _idLike = RegExp(r'^[0-9a-fA-F-]{16,}$|^\d+$');

/// A path word the API itself defines: lowercase letters with `_` or `-`,
/// or a version (`v1`). Checked on the segment as sent, before any
/// lowercasing, so a mixed-case token cannot pass as a word.
final _pathWord = RegExp(r'^(v\d+|[a-z][a-z_-]*)$');

String _templateSegment(String segment) {
  if (_idLike.hasMatch(segment)) return ':id';
  // Anything else (a token, an email, a code with digits) is not reported
  // as is.
  return _pathWord.hasMatch(segment) ? segment : ':value';
}

/// What the HTTP clients report: one call that failed, as the analytics
/// client turns it into `api_error` or `request_timeout`.
abstract final class ApiActivity {
  /// Whether anything is listening: false under the no-op analytics, so
  /// tests (and builds without the client) start no timers.
  static bool get active => Analytics.instance is! NoopAnalytics;

  /// How long a request may go unanswered before it counts as a timeout:
  /// the shortest deadline any service sets (DeadlineHttpClient's).
  static const slowAfter = Duration(seconds: 15);

  /// A response with [status] 400 or above.
  static void status(String method, Uri url, int status) {
    if (status < 400 || _isAnalytics(url)) return;
    Analytics.instance.record(
      AnalyticsEvent.apiError,
      attributes: {
        AnalyticsAttribute.route: routeTemplate(method, url),
        AnalyticsAttribute.statusClass: status >= 500
            ? AnalyticsValue.apiErrorStatusClass5xx
            : AnalyticsValue.apiErrorStatusClass4xx,
      },
    );
  }

  /// A request that never got an answer: no connection, or ([timeout])
  /// no reply in time.
  static void failed(String method, Uri url, {required bool timeout}) {
    if (_isAnalytics(url)) return;
    final route = routeTemplate(method, url);
    if (timeout) {
      Analytics.instance.record(
        AnalyticsEvent.requestTimeout,
        attributes: {AnalyticsAttribute.route: route},
      );
      return;
    }
    Analytics.instance.record(
      AnalyticsEvent.apiError,
      attributes: {
        AnalyticsAttribute.route: route,
        AnalyticsAttribute.statusClass:
            AnalyticsValue.apiErrorStatusClassNetwork,
      },
    );
  }

  // The analytics endpoints themselves are never reported: a failing
  // ingest would otherwise queue an event about itself, forever.
  static bool _isAnalytics(Uri url) =>
      url.pathSegments.length >= 2 && url.pathSegments[1] == 'analytics';
}
