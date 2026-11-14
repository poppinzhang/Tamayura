import 'dart:async';
import 'dart:convert';

// Uses the fake clock already bundled and locked with flutter_test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/local_catalog_maintenance.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/platform/platform_bridge.dart';

const _folder = SharedFolder(id: 'photos', uri: r'C:\Photos', name: 'Photos');

class _WatchBridge extends PlatformBridge {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final generations = <int>[];
  int stops = 0;
  bool failStart = false;
  bool failStop = false;
  Completer<void>? nextCancellationGate;

  @override
  String get platformName => 'Windows';
  @override
  bool isValidDeviceId(String id) => true;
  @override
  Stream<Map<String, dynamic>> get catalogEvents =>
      _WatchEvents(events.stream, () async {
        final gate = nextCancellationGate;
        nextCancellationGate = null;
        await gate?.future;
      });

  @override
  Future<void> startWatchingDirectories(
    List<SharedFolder> directories, {
    required int generation,
  }) async {
    generations.add(generation);
    if (failStart) throw StateError('watch unavailable');
  }

  @override
  Future<void> stopWatchingDirectories() async {
    stops++;
    if (failStop) throw StateError('watch stop unavailable');
  }
}

// A platform event channel finishes cancellation through an async platform
// reply. Model that reply in this fake zone instead of depending on Dart's
// shared already-completed stream-cancellation future from another test zone.
class _WatchEvents extends Stream<Map<String, dynamic>> {
  _WatchEvents(this.source, this.afterCancel);
  final Stream<Map<String, dynamic>> source;
  final Future<void> Function() afterCancel;

  @override
  StreamSubscription<Map<String, dynamic>> listen(
    void Function(Map<String, dynamic>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _WatchSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    afterCancel,
  );
}

class _WatchSubscription implements StreamSubscription<Map<String, dynamic>> {
  _WatchSubscription(this.inner, this.afterCancel);
  final StreamSubscription<Map<String, dynamic>> inner;
  final Future<void> Function() afterCancel;
  @override
  Future<void> cancel() async {
    unawaited(inner.cancel());
    await afterCancel();
  }

  @override
  void onData(void Function(Map<String, dynamic>)? handler) =>
      inner.onData(handler);
  @override
  void onError(Function? handler) => inner.onError(handler);
  @override
  void onDone(void Function()? handler) => inner.onDone(handler);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture(futureValue);
}

class _Scan {
  _Scan(this.changes, this.at);
  final List<LocalCatalogChange>? changes;
  final DateTime at;
}

class _Harness {
  _Harness(this.time) {
    maintenance = LocalCatalogMaintenance(
      bridge: bridge,
      folders: () => folders,
      intervalHours: () => hours,
      active: () => active,
      scanning: () => scanning,
      refresh: _refresh,
      readSetting: (key) async => settings[key],
      writeSetting: (key, value) async {
        if (failWrite) throw StateError('database unavailable');
        settings[key] = value;
      },
      onError: errors.add,
      clock: () => now,
    );
  }

  final FakeAsync time;
  final bridge = _WatchBridge();
  final settings = <String, String>{};
  final errors = <Object>[];
  final scans = <_Scan>[];
  List<SharedFolder> folders = [_folder];
  int hours = 24;
  bool active = true, scanning = false, failRefresh = false, failWrite = false;
  bool cacheSaved = true;
  Duration clockOffset = Duration.zero;
  Completer<void>? nextScanGate;
  Object? _scanOwner;
  late final LocalCatalogMaintenance maintenance;

  DateTime get now =>
      time.getClock(DateTime.utc(2026)).now().add(clockOffset).toLocal();

  void checkpoint(DateTime completed, {List<SharedFolder>? roots}) {
    settings[LocalCatalogMaintenance.checkpointKey] = jsonEncode({
      'version': 1,
      'roots': jsonEncode((roots ?? folders).map((f) => f.toJson()).toList()),
      'completedMs': completed.millisecondsSinceEpoch,
    });
  }

  void start({bool seed = true}) {
    if (seed) checkpoint(now);
    settle(maintenance.load());
    settle(maintenance.start());
    maintenance.reschedule();
    time.elapse(Duration.zero);
  }

  void settle(Future<void> operation) {
    var finished = false;
    operation.then((_) => finished = true);
    time.flushMicrotasks();
    expect(
      finished,
      isTrue,
      reason: 'An immediate fake operation must complete',
    );
  }

  void event(
    String type, {
    List<Map<String, Object>> changes = const [],
    int? generation,
  }) {
    bridge.events.add({
      'type': type,
      'generation': generation ?? bridge.generations.last,
      if (type == 'changed') 'changes': changes,
    });
  }

  void changed(List<String> paths, {int? generation}) => event(
    'changed',
    generation: generation,
    changes: [
      for (final path in paths)
        {'sharedFolderId': _folder.id, 'relativePath': path},
    ],
  );

  Future<void> _refresh(List<LocalCatalogChange>? changes) async {
    final owner = Object();
    _scanOwner = owner;
    final gate = nextScanGate;
    nextScanGate = null;
    scanning = true;
    if (changes == null) await maintenance.prepareFullScan();
    final generation = bridge.generations.last;
    scans.add(_Scan(changes, now));
    try {
      await gate?.future;
      if (generation != bridge.generations.last) return;
      if (failRefresh) throw StateError('scan unavailable');
      if (changes == null) {
        maintenance.fullScanSucceeded(cacheSaved: cacheSaved);
      }
      maintenance.catalogChanged(failed: false);
    } catch (_) {
      if (generation == bridge.generations.last) {
        maintenance.catalogChanged(failed: true);
      }
      rethrow;
    } finally {
      if (identical(_scanOwner, owner)) {
        scanning = false;
        maintenance.catalogChanged(failed: false);
      }
    }
  }

  void close() {
    settle(maintenance.stop());
    settle(maintenance.flushCheckpoint());
    settle(bridge.events.close());
  }
}

void _maintenanceTest(
  String name,
  void Function(FakeAsync time, _Harness harness) body,
) {
  test(name, () {
    fakeAsync((time) {
      final harness = _Harness(time);
      try {
        body(time, harness);
      } finally {
        harness.close();
      }
      expect(time.pendingTimers, isEmpty);
    });
  });
}

void main() {
  _maintenanceTest(
    'recent full checkpoint survives stop and restart without resetting',
    (tester, h) {
      final completed = h.now.subtract(const Duration(hours: 22));
      h.checkpoint(completed);
      h.start(seed: false);
      expect(h.maintenance.lastFullScan, completed);
      expect(h.scans, isEmpty);
      tester.elapse(const Duration(hours: 1));
      h.settle(h.maintenance.stop());
      h.settle(h.maintenance.start());
      h.maintenance.reschedule();
      tester.elapse(const Duration(minutes: 59));
      expect(h.scans, isEmpty);
      tester.elapse(const Duration(minutes: 1));
      expect(h.scans, hasLength(1));
      expect(h.scans.single.changes, isNull);
      expect(h.maintenance.lastFullScan, h.now);
    },
  );

  for (final invalid in [
    null,
    '',
    'broken',
    '[]',
    '{"version":1,"roots":[],"completedMs":1}',
    '{"version":1,"roots":"[]","completedMs":-1}',
    '{"version":1,"roots":"[]","completedMs":"1"}',
  ]) {
    _maintenanceTest(
      'missing or invalid checkpoint requests a full check: $invalid',
      (tester, h) {
        if (invalid != null) {
          h.settings[LocalCatalogMaintenance.checkpointKey] = invalid;
        }
        h.start(seed: false);
        expect(h.scans, hasLength(1));
        expect(h.scans.single.changes, isNull);
        expect(h.maintenance.lastFullScan, h.now);
      },
    );
  }

  _maintenanceTest(
    'newer checkpoint versions are preserved after a successful full check',
    (tester, h) {
      const newer = '{"version":2,"roots":"[]","completedMs":1,"future":true}';
      h.settings[LocalCatalogMaintenance.checkpointKey] = newer;
      h.start(seed: false);
      h.settle(h.maintenance.flushCheckpoint());
      expect(h.scans.single.changes, isNull);
      expect(h.settings[LocalCatalogMaintenance.checkpointKey], newer);
      expect(
        h.errors.single,
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'LOCAL_CATALOG_CHECKPOINT',
        ),
      );
    },
  );

  _maintenanceTest(
    'future checkpoint and changed shared roots require full checks',
    (tester, h) {
      h.checkpoint(h.now.add(const Duration(hours: 1)));
      h.start(seed: false);
      expect(h.scans, hasLength(1));
      h.settle(h.maintenance.stop());
      h.folders = [
        const SharedFolder(id: 'other', uri: r'D:\Pictures', name: 'Pictures'),
      ];
      h.settle(h.maintenance.start());
      h.maintenance.reschedule();
      tester.elapse(Duration.zero);
      expect(h.scans, hasLength(2));
    },
  );

  _maintenanceTest(
    'shorter interval checks now and longer interval postpones the deadline',
    (tester, h) {
      h.checkpoint(h.now.subtract(const Duration(hours: 10)));
      h.start(seed: false);
      h.hours = 6;
      h.maintenance.reschedule();
      tester.elapse(Duration.zero);
      expect(h.scans, hasLength(1));
      h.hours = 48;
      h.maintenance.reschedule();
      tester.elapse(const Duration(hours: 24));
      expect(h.scans, hasLength(1));
      tester.elapse(const Duration(hours: 24));
      expect(h.scans, hasLength(2));
    },
  );

  _maintenanceTest(
    'duplicate notifications coalesce and partial checks retain the full deadline',
    (tester, h) {
      h.start();
      final completed = h.maintenance.lastFullScan;
      h.changed(['trip/a.jpg', 'trip/a.jpg']);
      tester.elapse(const Duration(seconds: 1));
      h.changed(['trip/b.jpg']);
      tester.elapse(const Duration(seconds: 1));
      expect(h.scans, isEmpty);
      tester.elapse(const Duration(seconds: 1));
      expect(h.scans, hasLength(1));
      expect(h.scans.single.changes!.map((item) => item.relativePath), [
        'trip/a.jpg',
        'trip/b.jpg',
      ]);
      expect(h.maintenance.lastFullScan, completed);
      final persisted =
          jsonDecode(h.settings[LocalCatalogMaintenance.checkpointKey]!) as Map;
      expect(persisted['completedMs'], completed!.millisecondsSinceEpoch);
    },
  );

  _maintenanceTest(
    'continuous imports do not postpone a batch beyond maximum wait',
    (tester, h) {
      h.start();
      for (var index = 0; index < 10; index++) {
        h.changed(['trip/$index.jpg']);
        tester.elapse(const Duration(seconds: 1));
      }
      expect(h.scans, hasLength(1));
      expect(h.scans.single.changes, hasLength(10));
    },
  );

  _maintenanceTest(
    'notifications received while another scan runs stay queued',
    (tester, h) {
      h.start();
      h.scanning = true;
      h.changed(['trip/late.jpg']);
      tester.elapse(const Duration(seconds: 15));
      expect(h.scans, isEmpty);
      h.scanning = false;
      h.maintenance.catalogChanged(failed: false);
      tester.elapse(Duration.zero);
      expect(h.scans.single.changes!.single.relativePath, 'trip/late.jpg');
    },
  );

  _maintenanceTest(
    'notifications arriving during a partial check run in the next batch',
    (tester, h) {
      h.start();
      final gate = Completer<void>();
      h.nextScanGate = gate;
      h.changed(['trip/first.jpg']);
      tester.elapse(const Duration(seconds: 2));
      h.changed(['trip/second.jpg']);
      tester.elapse(const Duration(seconds: 2));
      expect(h.scans, hasLength(1));
      gate.complete();
      tester.elapse(Duration.zero);
      expect(h.scans, hasLength(2));
      expect(h.scans.last.changes!.single.relativePath, 'trip/second.jpg');
    },
  );

  _maintenanceTest('overflow and invalid hints request a complete check', (
    tester,
    h,
  ) {
    h.start();
    h.changed(['trip/a.jpg']);
    h.event('overflow');
    tester.elapse(Duration.zero);
    expect(h.scans.single.changes, isNull);
    h.changed(['../outside.jpg']);
    tester.elapse(Duration.zero);
    expect(h.scans, hasLength(2));
    expect(h.scans.last.changes, isNull);
  });

  _maintenanceTest('too many pending hints use a bounded full-check fallback', (
    tester,
    h,
  ) {
    h.start();
    h.changed(
      List.generate(
        LocalCatalogMaintenance.maxPendingChanges + 1,
        (index) => '$index.jpg',
      ),
    );
    tester.elapse(Duration.zero);
    expect(h.scans.single.changes, isNull);
  });

  _maintenanceTest(
    'overflow during a full check is not cleared by its success',
    (tester, h) {
      h.start();
      final gate = Completer<void>();
      h.nextScanGate = gate;
      h.event('overflow');
      tester.elapse(Duration.zero);
      h.event('overflow');
      gate.complete();
      tester.elapse(Duration.zero);
      expect(h.scans, hasLength(2));
      expect(h.scans.every((scan) => scan.changes == null), isTrue);
    },
  );

  _maintenanceTest('failed partial checks back off before a full retry', (
    tester,
    h,
  ) {
    h.start();
    h.failRefresh = true;
    h.changed(['trip/a.jpg']);
    tester.elapse(const Duration(seconds: 2));
    expect(h.scans, hasLength(1));
    tester.elapse(const Duration(seconds: 59));
    expect(h.scans, hasLength(1));
    h.failRefresh = false;
    tester.elapse(const Duration(seconds: 1));
    expect(h.scans, hasLength(2));
    expect(h.scans.last.changes, isNull);
    expect(h.maintenance.fullScanDue, isFalse);
  });

  _maintenanceTest(
    'watcher setup failure is visible and falls back to full checks',
    (tester, h) {
      h.bridge.failStart = true;
      h.start();
      expect(h.errors, isNotEmpty);
      expect(
        h.errors.every(
          (error) =>
              error is PlatformException &&
              error.code == 'CATALOG_WATCH_UNAVAILABLE',
        ),
        isTrue,
      );
      expect(h.scans.single.changes, isNull);
      tester.elapse(const Duration(hours: 1));
      expect(h.scans, hasLength(1));
      tester.elapse(const Duration(hours: 23));
      expect(h.scans, hasLength(2));
    },
  );

  _maintenanceTest(
    'stopping cancels scheduled work and rejects earlier generations',
    (tester, h) {
      h.start();
      final oldGeneration = h.bridge.generations.last;
      h.changed(['trip/a.jpg']);
      h.settle(h.maintenance.stop());
      tester.elapse(const Duration(seconds: 15));
      expect(h.scans, isEmpty);
      h.settle(h.maintenance.start());
      h.maintenance.reschedule();
      h.changed(['trip/stale.jpg'], generation: oldGeneration);
      tester.elapse(const Duration(seconds: 3));
      expect(h.scans, hasLength(1));
      expect(h.scans.single.changes, isNull);
      h.changed(['trip/current.jpg']);
      tester.elapse(const Duration(seconds: 2));
      expect(h.scans, hasLength(2));
      expect(h.scans.last.changes!.single.relativePath, 'trip/current.jpg');
    },
  );

  _maintenanceTest('watch failures reconnect before the next complete scan', (
    tester,
    h,
  ) {
    h.start();
    final oldGeneration = h.bridge.generations.last;
    h.event('error');
    tester.elapse(Duration.zero);
    expect(h.scans.single.changes, isNull);
    expect(h.bridge.generations.last, isNot(oldGeneration));
    h.changed(['trip/old.jpg'], generation: oldGeneration);
    tester.elapse(const Duration(seconds: 2));
    expect(h.scans, hasLength(1));
    h.changed(['trip/new.jpg']);
    tester.elapse(const Duration(seconds: 2));
    expect(h.scans, hasLength(2));
    expect(h.scans.last.changes!.single.relativePath, 'trip/new.jpg');
  });

  _maintenanceTest(
    'uncommitted hints force a full check after a new process restores the checkpoint',
    (tester, h) {
      h.start();
      final lastComplete = h.maintenance.lastFullScan;
      tester.elapse(const Duration(seconds: 1));
      h.changed(['trip/uncommitted.jpg']);
      h.settle(h.maintenance.stop());
      h.settle(h.maintenance.flushCheckpoint());
      final dirty =
          jsonDecode(h.settings[LocalCatalogMaintenance.checkpointKey]!) as Map;
      expect(dirty['needsCheck'], isTrue);
      expect(dirty['completedMs'], lastComplete!.millisecondsSinceEpoch);
      expect(h.scans, isEmpty);

      final restarted = _Harness(tester)..settings.addAll(h.settings);
      try {
        restarted.start(seed: false);
        expect(restarted.scans.single.changes, isNull);
        restarted.settle(restarted.maintenance.flushCheckpoint());
        final saved =
            jsonDecode(
                  restarted.settings[LocalCatalogMaintenance.checkpointKey]!,
                )
                as Map;
        expect(saved['needsCheck'], isNot(true));
        final cleanRestart = _Harness(tester)
          ..settings.addAll(restarted.settings);
        try {
          cleanRestart.start(seed: false);
          expect(cleanRestart.scans, isEmpty);
          expect(cleanRestart.maintenance.fullScanDue, isFalse);
        } finally {
          cleanRestart.close();
        }
      } finally {
        restarted.close();
      }
    },
  );

  _maintenanceTest(
    'a late recovery cancellation cannot stop a newer watcher or discard its hints',
    (tester, h) {
      h.start();
      h.scanning = true;
      h.event('error');
      final cancelled = Completer<void>();
      h.bridge.nextCancellationGate = cancelled;
      var recovered = false;
      final recovering = h.maintenance.prepareFullScan().then(
        (_) => recovered = true,
      );
      tester.flushMicrotasks();
      expect(recovered, isFalse);
      try {
        h.settle(h.maintenance.stop());
        h.scanning = false;
        h.settle(h.maintenance.start());
        // The new session finishes its own full check while the old event
        // channel's cancellation reply is still pending.
        h.settle(h.maintenance.prepareFullScan());
        h.maintenance.fullScanSucceeded(cacheSaved: true);
        h.maintenance.catalogChanged(failed: false);
        final currentGeneration = h.bridge.generations.last;
        final stopCount = h.bridge.stops;
        final startCount = h.bridge.generations.length;
        h.changed(['trip/current.jpg']);
        cancelled.complete();
        h.settle(recovering);
        expect(h.bridge.stops, stopCount);
        expect(h.bridge.generations, hasLength(startCount));
        expect(h.bridge.generations.last, currentGeneration);
        tester.elapse(const Duration(seconds: 2));
        expect(h.scans.single.changes!.single.relativePath, 'trip/current.jpg');
      } finally {
        if (!cancelled.isCompleted) cancelled.complete();
        h.settle(recovering);
      }
    },
  );

  _maintenanceTest(
    'native stop failures stay visible but cannot keep timers running',
    (tester, h) {
      h.start();
      h.bridge.failStop = true;
      h.changed(['trip/pending.jpg']);
      h.settle(h.maintenance.stop());
      tester.elapse(const Duration(days: 2));
      expect(h.scans, isEmpty);
      expect(h.errors.single, isA<PlatformException>());
      h.bridge.failStop = false;
    },
  );

  _maintenanceTest(
    'clock jumps are rechecked without waiting the original interval',
    (tester, h) {
      h.start();
      h.clockOffset = const Duration(hours: 48);
      tester.elapse(const Duration(hours: 1));
      expect(h.scans, hasLength(1));
      h.clockOffset = Duration.zero;
      h.maintenance.reschedule();
      tester.elapse(Duration.zero);
      expect(h.scans, hasLength(2));
    },
  );

  _maintenanceTest(
    'a stopped generation cannot hold a restarted watcher behind its pending scan',
    (tester, h) {
      h.start();
      final oldGate = Completer<void>();
      final newGate = Completer<void>();
      try {
        h.nextScanGate = oldGate;
        h.changed(['trip/old.jpg']);
        tester.elapse(const Duration(seconds: 2));
        expect(h.scans, hasLength(1));
        h.settle(h.maintenance.stop());
        // The RPC/native generation is revoked even if its obsolete worker has
        // not completed yet. A new session can restore a usable catalog.
        h.scanning = false;
        h.settle(h.maintenance.start());
        h.maintenance.reschedule();
        h.nextScanGate = newGate;
        h.changed(['trip/new.jpg']);
        tester.elapse(const Duration(seconds: 2));
        expect(h.scans, hasLength(2));
        // The abandoned partial update makes the restored catalog dirty, so
        // the new generation performs a complete recovery before more hints.
        expect(h.scans.last.changes, isNull);
        oldGate.complete();
        tester.elapse(Duration.zero);
        h.changed(['trip/after.jpg']);
        tester.elapse(const Duration(seconds: 2));
        expect(h.scans, hasLength(2));
        newGate.complete();
        tester.elapse(Duration.zero);
        expect(h.scans, hasLength(3));
        expect(h.scans.last.changes!.single.relativePath, 'trip/after.jpg');
      } finally {
        if (!oldGate.isCompleted) oldGate.complete();
        if (!newGate.isCompleted) newGate.complete();
        tester.elapse(Duration.zero);
      }
    },
  );

  _maintenanceTest(
    'checkpoint write failure preserves sharing and reports a retryable error',
    (tester, h) {
      h.start();
      final previous = h.settings[LocalCatalogMaintenance.checkpointKey];
      h.failWrite = true;
      tester.elapse(const Duration(seconds: 1));
      h.event('overflow');
      tester.elapse(Duration.zero);
      h.settle(h.maintenance.flushCheckpoint());
      expect(h.maintenance.lastFullScan, h.now);
      expect(h.maintenance.fullScanDue, isFalse);
      expect(h.settings[LocalCatalogMaintenance.checkpointKey], previous);
      expect(
        h.errors.single,
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'LOCAL_CATALOG_CHECKPOINT',
        ),
      );
      h.failWrite = false;
      tester.elapse(const Duration(seconds: 1));
      h.event('overflow');
      tester.elapse(Duration.zero);
      h.settle(h.maintenance.flushCheckpoint());
      expect(
        h.settings[LocalCatalogMaintenance.checkpointKey],
        isNot(previous),
      );
    },
  );

  _maintenanceTest(
    'failed index persistence cannot advance the persisted full-check time',
    (tester, h) {
      h.start();
      final previous = h.settings[LocalCatalogMaintenance.checkpointKey];
      h.cacheSaved = false;
      tester.elapse(const Duration(seconds: 1));
      h.event('overflow');
      tester.elapse(Duration.zero);
      h.settle(h.maintenance.flushCheckpoint());
      expect(h.maintenance.lastFullScan, h.now);
      expect(h.settings[LocalCatalogMaintenance.checkpointKey], previous);
    },
  );
}
