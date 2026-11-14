import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/models.dart';
import '../platform/platform_bridge.dart';

/// Windows catalog freshness is independent of peer synchronization. Watcher
/// hints reduce disk reads; a persisted full-check deadline bounds missed edits
/// made while the application was not running.
class LocalCatalogMaintenance {
  LocalCatalogMaintenance({
    required this.bridge,
    required this.folders,
    required this.intervalHours,
    required this.active,
    required this.scanning,
    required this.refresh,
    required this.readSetting,
    required this.writeSetting,
    required this.onError,
    DateTime Function()? clock,
    this.debounce = const Duration(seconds: 2),
    this.maxBatchDelay = const Duration(seconds: 10),
    this.retryDelay = const Duration(minutes: 1),
  }) : clock = clock ?? DateTime.now;

  static const checkpointKey = 'localCatalogFullScan';
  static const maxPendingChanges = 4096;
  final PlatformBridge bridge;
  final List<SharedFolder> Function() folders;
  final int Function() intervalHours;
  final bool Function() active, scanning;
  final Future<void> Function(List<LocalCatalogChange>? changes) refresh;
  final Future<String?> Function(String key) readSetting;
  final Future<void> Function(String key, String value) writeSetting;
  final void Function(Object error) onError;
  final DateTime Function() clock;
  final Duration debounce, maxBatchDelay, retryDelay;

  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _periodic, _batch;
  int _generation = 0;
  bool _running = false, _forceFull = false;
  Object? _refreshOwner;
  bool get _refreshing => _refreshOwner != null;
  bool _lastAttemptFailed = false;
  bool _checkpointWritable = true;
  bool _watchNeedsRestart = false;
  String? _watchedRoots, _checkedRoots;
  DateTime? _lastFullScan, _lastAttempt, _firstEvent, _lastEvent;
  final Map<String, LocalCatalogChange> _changes = {};
  Future<void> _writes = Future.value();
  Future<void>? _starting;
  String? _startingRoots;

  String get _roots => jsonEncode(folders().map((f) => f.toJson()).toList());
  DateTime? get lastFullScan => _checkedRoots == _roots ? _lastFullScan : null;

  bool get fullScanDue {
    final last = lastFullScan;
    final now = clock();
    return _forceFull ||
        last == null ||
        last.isAfter(now) ||
        !now.isBefore(last.add(Duration(hours: intervalHours())));
  }

  Future<void> load() async {
    final value = await readSetting(checkpointKey);
    if (value == null) return;
    // Invalid/older settings are retained. A new successful full check can
    // replace this auxiliary timestamp without touching the native index.
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data['version'] != 1) {
        _checkpointWritable = false;
        onError(PlatformException(code: 'LOCAL_CATALOG_CHECKPOINT'));
        return;
      }
      if (data['roots'] is! String ||
          data['completedMs'] is! int ||
          (data['completedMs'] as int) <= 0) {
        return;
      }
      _checkedRoots = data['roots'] as String;
      _forceFull = data['needsCheck'] == true;
      _lastFullScan = DateTime.fromMillisecondsSinceEpoch(
        data['completedMs'] as int,
      );
    } on Object {
      _checkedRoots = null;
      _lastFullScan = null;
    }
  }

  /// Subscribe before starting the native watcher, and arm it before restoring
  /// or scanning. Events arriving during either operation stay queued.
  Future<void> start() {
    if (_starting != null && _startingRoots == _roots) return _starting!;
    late final Future<void> starting;
    starting = _start().whenComplete(() {
      if (identical(_starting, starting)) {
        _starting = null;
        _startingRoots = null;
      }
    });
    _starting = starting;
    _startingRoots = _roots;
    return starting;
  }

  Future<void> _start() async {
    final roots = _roots;
    if (_running && _watchedRoots == roots) return;
    final stopping = stop();
    final stoppedGeneration = _generation;
    await stopping;
    if (stoppedGeneration != _generation) return;
    _running = true;
    _watchedRoots = roots;
    final generation = ++_generation;
    if (folders().isEmpty) return;
    _watchNeedsRestart = false;
    _subscription = bridge.catalogEvents.listen(
      (event) => _event(event, generation),
      onError: (Object _) => _watchFailed(generation),
    );
    try {
      await bridge.startWatchingDirectories(folders(), generation: generation);
    } catch (_) {
      _watchFailed(generation);
    }
  }

  Future<void> stop() async {
    final wasRunning = _running;
    final dirty =
        wasRunning &&
        (_changes.isNotEmpty || _refreshing || scanning() || _forceFull);
    if (dirty) {
      _forceFull = true;
      // Preserve already observed but not committed changes across process
      // exit too. This write is serialized before any later success marker.
      if (_checkpointWritable &&
          _checkedRoots != null &&
          _lastFullScan != null) {
        _saveCheckpoint(needsCheck: true);
      }
    }
    _running = false;
    _starting = null;
    _startingRoots = null;
    final generation = ++_generation;
    _refreshOwner = null;
    _periodic?.cancel();
    _batch?.cancel();
    _periodic = _batch = null;
    _changes.clear();
    _firstEvent = _lastEvent = null;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      onError(PlatformException(code: 'CATALOG_WATCH_UNAVAILABLE'));
    }
    if (generation != _generation) return;
    if (wasRunning) {
      try {
        await bridge.stopWatchingDirectories();
      } catch (_) {
        onError(PlatformException(code: 'CATALOG_WATCH_UNAVAILABLE'));
      }
    }
  }

  void _watchFailed(int generation) {
    if (!_running || generation != _generation) return;
    _forceFull = true;
    _watchNeedsRestart = true;
    onError(PlatformException(code: 'CATALOG_WATCH_UNAVAILABLE'));
    _arm();
  }

  void _event(Map<String, dynamic> event, int generation) {
    if (!_running ||
        generation != _generation ||
        event['generation'] != generation) {
      return;
    }
    if (event['type'] == 'error') {
      _watchFailed(generation);
      return;
    }
    if (event['type'] != 'changed') {
      // Includes overflow and unknown event types: never silently lose changes.
      _forceFull = true;
      // A root can have been renamed/replaced while the old watch still
      // references its former directory. Reopen before the recovery scan.
      _watchNeedsRestart = true;
      _arm();
      return;
    }
    try {
      final roots = folders().map((f) => f.id).toSet();
      for (final raw in event['changes'] as List) {
        final change = Map<String, dynamic>.from(raw as Map);
        final id = change['sharedFolderId'] as String;
        final path = change['relativePath'] as String;
        if (!roots.contains(id) ||
            path.isEmpty ||
            path.startsWith('/') ||
            path.contains('\\') ||
            path.contains('\u0000') ||
            path
                .split('/')
                .any((part) => part.isEmpty || part == '.' || part == '..')) {
          throw const FormatException('Invalid catalog event');
        }
        _changes['$id\u0000$path'] = LocalCatalogChange(id, path);
        if (_changes.length > maxPendingChanges) {
          _changes.clear();
          _forceFull = true;
          break;
        }
      }
    } on Object {
      _forceFull = true;
    }
    if (_changes.isNotEmpty) {
      _firstEvent ??= clock();
      _lastEvent = clock();
    }
    _arm();
  }

  /// Called at the beginning of a full disk walk, never merely on restore.
  /// Previously queued hints are covered by it; later hints must still run.
  void fullScanStarted() {
    _lastAttempt = clock();
    _lastAttemptFailed = false;
    _forceFull = false;
    _changes.clear();
    _firstEvent = _lastEvent = null;
    _batch?.cancel();
    _batch = null;
  }

  Future<void> prepareFullScan() async {
    if (_running && _watchNeedsRestart && folders().isNotEmpty) {
      final generation = ++_generation;
      final subscription = _subscription;
      _subscription = null;
      try {
        await subscription?.cancel();
      } catch (_) {}
      if (!_running || generation != _generation) return;
      try {
        await bridge.stopWatchingDirectories();
      } catch (_) {}
      if (!_running || generation != _generation) return;
      _watchNeedsRestart = false;
      _subscription = bridge.catalogEvents.listen(
        (event) => _event(event, generation),
        onError: (Object _) => _watchFailed(generation),
      );
      try {
        await bridge.startWatchingDirectories(
          folders(),
          generation: generation,
        );
      } catch (_) {
        _watchFailed(generation);
      }
      if (!_running || generation != _generation) return;
    }
    // Even when monitoring is unavailable, one complete check establishes the
    // current catalog. Its configured deadline is the fallback, not a hot loop.
    if (_running) fullScanStarted();
  }

  /// Only a complete snapshot accepted by the RPC service counts as success.
  /// Partial scans deliberately do not move the full-check deadline.
  void fullScanSucceeded({required bool cacheSaved}) {
    final completed = clock();
    final roots = _roots;
    _lastFullScan = completed;
    _checkedRoots = roots;
    _lastAttemptFailed = false;
    if (!cacheSaved || !_checkpointWritable) return;
    _saveCheckpoint(needsCheck: false);
  }

  void _saveCheckpoint({required bool needsCheck}) {
    final value = jsonEncode({
      'version': 1,
      'roots': _checkedRoots,
      'completedMs': _lastFullScan!.millisecondsSinceEpoch,
      if (needsCheck) 'needsCheck': true,
    });
    _writes = _writes.then((_) async {
      try {
        await writeSetting(checkpointKey, value);
      } catch (_) {
        onError(PlatformException(code: 'LOCAL_CATALOG_CHECKPOINT'));
      }
    });
  }

  Future<void> flushCheckpoint() => _writes;

  void catalogChanged({required bool failed}) {
    if (failed) {
      _lastAttemptFailed = true;
      _lastAttempt ??= clock();
      _forceFull = true;
    }
    _arm();
  }

  void reschedule() => _arm();

  void _arm() {
    _periodic?.cancel();
    _batch?.cancel();
    _periodic = _batch = null;
    if (!_running ||
        !active() ||
        scanning() ||
        _refreshing ||
        folders().isEmpty) {
      return;
    }
    final now = clock();
    final last = lastFullScan;
    var due = fullScanDue ? now : last!.add(Duration(hours: intervalHours()));
    if (_lastAttemptFailed && _lastAttempt != null) {
      final retry = _lastAttempt!.add(retryDelay);
      if (retry.isAfter(due)) due = retry;
    }
    // Re-evaluate at least hourly to handle system clock/sleep changes and to
    // avoid relying on platform timer limits for very large hour settings.
    var delay = due.difference(now);
    if (delay.isNegative) delay = Duration.zero;
    if (delay > const Duration(hours: 1)) delay = const Duration(hours: 1);
    _periodic = Timer(delay, () {
      _periodic = null;
      if (fullScanDue) {
        unawaited(_run(full: true));
      } else {
        _arm();
      }
    });
    if (_changes.isNotEmpty && !_forceFull) {
      final quiet = (_lastEvent ?? now).add(debounce);
      final maximum = (_firstEvent ?? now).add(maxBatchDelay);
      final ready = quiet.isBefore(maximum) ? quiet : maximum;
      final wait = ready.difference(now);
      _batch = Timer(wait.isNegative ? Duration.zero : wait, () {
        _batch = null;
        unawaited(_run(full: fullScanDue));
      });
    }
  }

  Future<void> _run({required bool full}) async {
    if (!_running || !active() || scanning() || _refreshing) return;
    final owner = Object();
    _refreshOwner = owner;
    _periodic?.cancel();
    _batch?.cancel();
    final changes = full ? null : _changes.values.toList();
    _changes.clear();
    _firstEvent = _lastEvent = null;
    _lastAttempt = clock();
    try {
      await refresh(changes);
    } catch (_) {
      // The service exposes the original error. Back off instead of looping
      // on an inaccessible disk or treating a failed partial check as empty.
      if (identical(_refreshOwner, owner)) {
        _lastAttemptFailed = true;
        _forceFull = true;
      }
    } finally {
      if (identical(_refreshOwner, owner)) {
        _refreshOwner = null;
        _arm();
      }
    }
  }
}
