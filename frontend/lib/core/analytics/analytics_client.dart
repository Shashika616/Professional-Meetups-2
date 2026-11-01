import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/analytics_queue.dart';
import 'package:professional_connections_platform/core/analytics/analytics_transport.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/flow_tracker.dart';
import 'package:professional_connections_platform/core/analytics/screen_tracker.dart';
import 'package:professional_connections_platform/core/config/app_version.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';

/// The coarse, batch-level context the ingest takes (plan 29 §4.2). No
/// device identifiers: the install id is random and stays on this install.
class DeviceContext {
  const DeviceContext({
    required this.appVersion,
    required this.osName,
    this.osVersion = '',
    required this.deviceClass,
    required this.locale,
  });

  final String appVersion;
  final String osName;
  final String osVersion;
  final String deviceClass;
  final String locale;

  /// Read from the platform. Android's OS version is left out: Dart only
  /// sees the kernel's, not the Android release, and a wrong number is
  /// worse than none.
  static DeviceContext current() {
    final view = PlatformDispatcher.instance.views.isEmpty
        ? null
        : PlatformDispatcher.instance.views.first;
    var deviceClass = 'phone';
    if (view != null) {
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.shortestSide >= 600) deviceClass = 'tablet';
    }
    var osName = 'other';
    var osVersion = '';
    if (!kIsWeb) {
      if (Platform.isIOS) {
        osName = 'ios';
        osVersion =
            RegExp(
              r'(\d+(\.\d+){0,2})',
            ).firstMatch(Platform.operatingSystemVersion)?.group(1) ??
            '';
      } else if (Platform.isAndroid) {
        osName = 'android';
      }
    }
    return DeviceContext(
      appVersion: AppVersion.header,
      osName: osName,
      osVersion: osVersion,
      deviceClass: deviceClass,
      locale: PlatformDispatcher.instance.locale.toLanguageTag(),
    );
  }
}

/// Local settings: the install id and the opt-out.
abstract interface class AnalyticsSettings {
  Future<String?> installId();
  Future<void> setInstallId(String id);
  Future<bool> optedOut();
  Future<void> setOptedOut(bool value);
}

class SharedPreferencesAnalyticsSettings implements AnalyticsSettings {
  static const _installKey = 'analytics.install_id';
  static const _optOutKey = 'analytics.opted_out';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> installId() async => (await _prefs())?.getString(_installKey);

  @override
  Future<void> setInstallId(String id) async =>
      (await _prefs())?.setString(_installKey, id);

  @override
  Future<bool> optedOut() async =>
      (await _prefs())?.getBool(_optOutKey) ?? false;

  @override
  Future<void> setOptedOut(bool value) async =>
      (await _prefs())?.setBool(_optOutKey, value);
}

class MemoryAnalyticsSettings implements AnalyticsSettings {
  MemoryAnalyticsSettings({this.install, this.opted = false});
  String? install;
  bool opted;

  @override
  Future<String?> installId() async => install;
  @override
  Future<void> setInstallId(String id) async => install = id;
  @override
  Future<bool> optedOut() async => opted;
  @override
  Future<void> setOptedOut(bool value) async => opted = value;
}

/// The real analytics client (see [Analytics] for the contract).
class AnalyticsClient extends Analytics {
  AnalyticsClient({
    required this.transport,
    required QueueStore store,
    required this.settings,
    this._device,
    this.flushInterval = const Duration(seconds: 30),
    this.persistDelay = const Duration(seconds: 1),
    this.flushAt = 20,
    this.batchSize = 50,
    this.sessionTimeout = const Duration(minutes: 30),
    this.maxBackoff = const Duration(minutes: 10),
  }) : queue = AnalyticsQueue(store: store) {
    _screens = ScreenTracker(_onScreen);
  }

  final AnalyticsTransport transport;
  final AnalyticsSettings settings;
  final AnalyticsQueue queue;

  /// How often queued events are sent (null: only on the other triggers).
  final Duration? flushInterval;

  /// How long after the last event the queue is saved (null: at once).
  final Duration? persistDelay;
  final int flushAt;
  final int batchSize;
  final Duration sessionTimeout;
  final Duration maxBackoff;

  DeviceContext? _device;
  late final ScreenTracker _screens;
  final Map<String, FlowTracker> _flows = {};

  String _installId = '';
  String _sessionId = '';
  DateTime _sessionStart = clock.now();
  DateTime? _backgroundedAt;
  bool _started = false;

  bool _optedOut = false;
  bool _remoteEnabled = true;
  int _sampleRate = 100;

  Timer? _flushTimer;
  Timer? _persistTimer;
  bool _flushing = false;
  int _failures = 0;
  DateTime? _nextAttempt;

  /// Loads the install id, the opt-out and the persisted queue, then opens
  /// the first session. Call once, at app start.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // The session exists before anything is awaited: the first screen is
    // recorded while the stored queue is still loading, and it belongs to
    // this session.
    _sessionId = uuidV4();
    _sessionStart = clock.now();
    _device ??= DeviceContext.current();
    var id = await settings.installId();
    if (id == null || id.length != 36) {
      id = uuidV4();
      await settings.setInstallId(id);
    }
    _installId = id;
    _optedOut = await settings.optedOut();
    await queue.load();
    if (_optedOut) {
      queue.clear();
      await queue.persist();
    }
    final interval = flushInterval;
    if (interval != null) {
      _flushTimer = Timer.periodic(interval, (_) => unawaited(flush()));
    }
    record(AnalyticsEvent.sessionStarted);
    record(
      AnalyticsEvent.appOpened,
      attributes: {AnalyticsAttribute.coldStart: true},
    );
  }

  /// Stops the timers (tests; the app never stops it).
  void dispose() {
    _flushTimer?.cancel();
    _persistTimer?.cancel();
  }

  String get installId => _installId;
  String get sessionId => _sessionId;

  /// Whether this install is inside `analytics.sample_rate`: a stable
  /// choice per install, so a user is either counted or not, not half.
  bool get _sampled {
    if (_sampleRate >= 100) return true;
    if (_sampleRate <= 0 || _installId.length < 8) return false;
    final bucket = int.parse(_installId.substring(0, 8), radix: 16) % 100;
    return bucket < _sampleRate;
  }

  bool get _recording => _started && !_optedOut && _remoteEnabled && _sampled;

  @override
  void record(
    String name, {
    Attributes attributes = const {},
    String? screen,
    String? flowId,
    String? flowStep,
  }) {
    if (!_recording) return;
    final s = screen ?? _screens.current;
    queue.add({
      'event_id': uuidV7(clock.now()),
      'event_name': name,
      'schema_version': analyticsEventVersions[name] ?? 1,
      'occurred_at': clock.now().toUtc().toIso8601String(),
      'session_id': _sessionId,
      'screen': ?s,
      'flow_id': ?flowId,
      if (flowId != null && flowStep != null) 'flow_step': flowStep,
      'attributes': attributes,
    });
    _schedulePersist();
    if (queue.length >= flushAt) unawaited(flush());
  }

  void _onScreen(String event, String screen, int? durationMs) => record(
    event,
    screen: screen,
    attributes: {
      if (durationMs != null) AnalyticsAttribute.durationMs: _cap(durationMs),
    },
  );

  static int _cap(int ms) => ms > 86400000 ? 86400000 : ms;

  @override
  FlowTracker flow(String flowId) => _flows.putIfAbsent(
    flowId,
    () => FlowTracker(
      flowId,
      (event, id, step, attributes) =>
          record(event, flowId: id, flowStep: step, attributes: attributes),
    ),
  );

  @override
  NavigatorObserver newNavigatorObserver() => _screens.observer();

  @override
  void tabChanged(int index) => _screens.tabChanged(index);

  @override
  String? get currentScreen => _screens.current;

  @override
  int get navigationGeneration => _screens.generation;

  void _beginSession() {
    _sessionId = uuidV4();
    _sessionStart = clock.now();
    record(AnalyticsEvent.sessionStarted);
  }

  void _endSession(DateTime endedAt) {
    for (final f in _flows.values) {
      f.abandon(AnalyticsValue.flowAbandonedReasonBackgrounded);
    }
    record(
      AnalyticsEvent.sessionEnded,
      attributes: {
        AnalyticsAttribute.durationMs: _cap(
          endedAt.difference(_sessionStart).inMilliseconds,
        ),
      },
    );
  }

  @override
  void lifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_backgroundedAt != null) return;
        _backgroundedAt = clock.now();
        record(AnalyticsEvent.appBackgrounded);
        _screens.pause();
        unawaited(queue.persist());
        unawaited(flush());
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        if (since == null) return;
        _backgroundedAt = null;
        if (clock.now().difference(since) >= sessionTimeout) {
          // A new session: the old one ended when the app went away.
          _endSession(since);
          _screens.resume();
          _beginSession();
          _screens.restartVisit();
        } else {
          _screens.resume();
        }
        record(AnalyticsEvent.appForegrounded);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  bool get optedOut => _optedOut;

  @override
  Future<void> setOptedOut(bool optedOut) async {
    _optedOut = optedOut;
    await settings.setOptedOut(optedOut);
    if (optedOut) {
      queue.clear();
      await queue.persist();
    }
    // Server side too, when signed in (the server then drops anything that
    // still carries this account, and deletes what it has).
    unawaited(transport.setConsent(optedOut: optedOut));
  }

  @override
  void applyRemoteConfig({required bool enabled, required int sampleRate}) {
    _remoteEnabled = enabled;
    _sampleRate = sampleRate.clamp(0, 100);
    if (!enabled || !_sampled) {
      // Switched off by the server: what is queued is not sent either.
      queue.clear();
      unawaited(queue.persist());
    }
  }

  void _schedulePersist() {
    final delay = persistDelay;
    if (delay == null) {
      unawaited(queue.persist());
      return;
    }
    _persistTimer?.cancel();
    _persistTimer = Timer(delay, () => unawaited(queue.persist()));
  }

  /// When the next send may happen, after [_failures] failures in a row:
  /// 30 s, 1, 2, 4, 8 minutes, then [maxBackoff].
  Duration _backoff() {
    final seconds = 30 * (1 << (_failures - 1).clamp(0, 10));
    final d = Duration(seconds: seconds);
    return d > maxBackoff ? maxBackoff : d;
  }

  @override
  Future<void> flush() async {
    if (!_started || _flushing || _optedOut || !_remoteEnabled) return;
    final next = _nextAttempt;
    if (next != null && clock.now().isBefore(next)) return;
    _flushing = true;
    try {
      while (!queue.isEmpty && !_optedOut) {
        final events = queue.peek(batchSize);
        final device = _device!;
        final result = await transport.send({
          'install_id': _installId,
          'app_version': device.appVersion,
          'os_name': device.osName,
          if (device.osVersion.isNotEmpty) 'os_version': device.osVersion,
          'device_class': device.deviceClass,
          'locale': device.locale,
          'events': events,
        });
        final ids = {for (final e in events) e['event_id'] as String};
        switch (result) {
          case Sent():
          case Refused():
            queue.removeIds(ids);
            _failures = 0;
            _nextAttempt = null;
          case RetryLater(:final after):
            _failures++;
            _nextAttempt = clock.now().add(after ?? _backoff());
            return;
        }
      }
    } finally {
      _flushing = false;
      unawaited(queue.persist());
    }
  }
}
