import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where the queue survives a restart.
abstract interface class QueueStore {
  Future<List<String>> read();
  Future<void> write(List<String> events);
}

/// The device's store: one `shared_preferences` string list.
class SharedPreferencesQueueStore implements QueueStore {
  SharedPreferencesQueueStore({this.key = 'analytics.queue.v1'});

  final String key;

  @override
  Future<List<String>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(key) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> write(List<String> events) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(key, events);
    } catch (_) {
      // Losing queued analytics on a storage error is acceptable; failing
      // anything the user is doing is not.
    }
  }
}

/// A store that lives only in memory (tests).
class MemoryQueueStore implements QueueStore {
  List<String> events = [];

  @override
  Future<List<String>> read() async => List.of(events);

  @override
  Future<void> write(List<String> events) async =>
      this.events = List.of(events);
}

/// The bounded event queue (plan 29E): at most [capacity] events, the oldest
/// dropped when full, persisted so a restart does not lose what was not sent
/// yet. Events are the JSON objects the ingest takes, minus the batch-level
/// context.
class AnalyticsQueue {
  AnalyticsQueue({required this.store, this.capacity = 500});

  final QueueStore store;
  final int capacity;
  final List<Map<String, Object?>> _events = [];

  /// How many were dropped because the queue was full (since start).
  int droppedOldest = 0;

  int get length => _events.length;
  bool get isEmpty => _events.isEmpty;

  /// Loads what a previous run left. Events already in memory (recorded
  /// before the load finished) stay, after the loaded ones.
  Future<void> load() async {
    final stored = await store.read();
    final loaded = <Map<String, Object?>>[];
    for (final raw in stored) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) loaded.add(decoded);
      } catch (_) {
        // A corrupt entry is skipped, not fatal.
      }
    }
    _events.insertAll(0, loaded);
    _trim();
  }

  void add(Map<String, Object?> event) {
    _events.add(event);
    _trim();
  }

  void _trim() {
    final over = _events.length - capacity;
    if (over > 0) {
      _events.removeRange(0, over);
      droppedOldest += over;
    }
  }

  /// The oldest [n] events, not removed.
  List<Map<String, Object?>> peek(int n) => List.unmodifiable(_events.take(n));

  /// Removes the events with these ids (the ones a batch delivered or the
  /// server refused for good), wherever they are now.
  void removeIds(Set<String> ids) =>
      _events.removeWhere((e) => ids.contains(e['event_id']));

  void clear() => _events.clear();

  Future<void> persist() =>
      store.write([for (final e in _events) jsonEncode(e)]);
}
