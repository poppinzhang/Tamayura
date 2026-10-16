import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/background/transfer_scheduler.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/macos_bridge.dart';
import 'package:tamayura/platform/platform_bridge.dart';

import 'controller_test.dart' show FakeBridge, MemorySource;

const _peer = Peer(id: 'remote', name: 'Phone', host: '127.0.0.1', port: 50728);
final _item = MediaItem(
  id: 'photo',
  deviceId: _peer.id,
  name: 'photo.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '旅行/photo.jpg',
  mimeType: 'image/jpeg',
  size: 6,
  modifiedMs: 1,
  thumbnail: Uint8List(0),
);

class _DesktopBridge extends MacOSBridge {
  _DesktopBridge(this.directory);
  final Directory directory;
  @override
  Future<TransferSpaceInfo> transferSpace({
    required String directoryUri,
  }) async => const TransferSpaceInfo();

  int directoryReads = 0, exports = 0;
  Future<void> Function()? beforeDirectory;
  Future<void> Function(String)? beforeSave;
  Future<void> Function()? beforeAcquire;
  bool directoryFails = false;
  bool acquireFails = false, releaseFails = false;
  final activityEvents = <String>[];
  final activeTasks = <String>{};
  Uint8List? exported;

  @override
  Future<void> setTransferActivity(
    String taskId, {
    required bool active,
  }) async {
    activityEvents.add('${active ? 'acquire' : 'release'}:$taskId');
    if (active) {
      await beforeAcquire?.call();
      if (acquireFails) {
        throw PlatformException(code: 'ACTIVITY_FAILED', message: '无法保持后台下载');
      }
      activeTasks.add(taskId);
    } else {
      activeTasks.remove(taskId);
      if (releaseFails) throw StateError('Activity release failed');
    }
  }

  @override
  Future<String> transferDirectory() async {
    directoryReads++;
    await beforeDirectory?.call();
    if (directoryFails) {
      throw PlatformException(code: 'STAGING_UNAVAILABLE', message: '暂存目录不可用');
    }
    return p.join(directory.path, 'staging');
  }

  @override
  Future<String> saveDownload({
    required List<String> sourcePaths,
    required int expectedSize,
    required String directoryUri,
    required String name,
    required String mimeType,
    required List<String> directories,
  }) async {
    await beforeSave?.call(name);
    final bytes = BytesBuilder(copy: false);
    for (final path in sourcePaths) {
      bytes.add(await File(path).readAsBytes());
    }
    exported = bytes.takeBytes();
    expect(exported!.length, expectedSize);
    exports++;
    return 'file:///Users/test/Downloads/$name';
  }
}

class _Client implements MediaRpcClient {
  _Client(this.peer, this.read, {this.onClose});
  @override
  final Peer peer;
  final Stream<Uint8List> Function(int, int) read;
  final void Function()? onClose;
  bool _reading = false;
  @override
  Future<Peer> identity() async => peer;
  @override
  Stream<Uint8List> readRange(String id, int offset, int length) {
    _reading = true;
    return read(offset, length);
  }

  @override
  Future<void> close() async {
    if (_reading) onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControllerDesktopBridge extends FakeBridge {
  _ControllerDesktopBridge(this.directory);
  final Directory directory;
  @override
  bool get usesInProcessTransfers => true;
  @override
  Future<String> transferDirectory() async => directory.path;
  @override
  Future<void> setTransferActivity(
    String taskId, {
    required bool active,
  }) async {}
  @override
  Future<void> scheduleTransfer(String id) async =>
      throw StateError('Desktop must not invoke native job scheduling');
  @override
  Future<List<String>> scheduledTransferIds() async =>
      throw StateError('Desktop must not invoke native job queries');
  @override
  Future<void> cancelTransfer(String id) async =>
      throw StateError('Desktop must not invoke native job cancellation');
}

Future<void> _until(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late TransferStore store;
  late TamayuraRepository repository;
  late _DesktopBridge bridge;
  InProcessTransferScheduler? scheduler;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tamayura-desktop-');
    store = await TransferStore.open(
      path: p.join(root.path, 'tasks.db'),
      factory: databaseFactoryFfi,
    );
    repository = await TamayuraRepository.open(
      path: p.join(root.path, 'catalog.db'),
      factory: databaseFactoryFfi,
    );
    bridge = _DesktopBridge(root);
    scheduler = null;
  });
  tearDown(() async {
    await scheduler?.shutdown();
    await store.close();
    await repository.close();
    await root.delete(recursive: true);
  });

  // Without an outage window a run fails once its local retries are spent;
  // automatic retry tests opt into a window explicitly.
  InProcessTransferScheduler createScheduler({
    Stream<Uint8List> Function(int, int)? read,
    void Function()? onClose,
    Duration outageWindow = Duration.zero,
    Duration autoRetryDelay = Duration.zero,
  }) => InProcessTransferScheduler(
    store: store,
    repository: repository,
    bridge: bridge,
    retryDelay: Duration.zero,
    outageWindow: outageWindow,
    autoRetryDelay: autoRetryDelay,
    clientFactory: (peer) => _Client(
      peer,
      read ??
          (offset, length) async* {
            yield Uint8List.fromList(
              [1, 2, 3, 4, 5, 6].sublist(offset, offset + length),
            );
          },
      onClose: onClose,
    ),
  );

  test(
    'duplicate scheduling has one worker and setup is visible to reconciliation',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      bridge.beforeDirectory = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      scheduler = createScheduler();
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await Future.wait(
        List.generate(3, (_) => scheduler!.scheduleTransfer(task.id)),
      );
      await entered.future;
      try {
        expect(bridge.activeTasks, {task.id});
        expect(bridge.activityEvents, ['acquire:${task.id}']);
        expect(await scheduler!.scheduledTransferIds(), [task.id]);
        await store.reconcile(
          (await scheduler!.scheduledTransferIds()).toSet(),
        );
        expect((await store.get(task.id))!.state, DownloadState.queued);
      } finally {
        release.complete();
      }
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
      expect(bridge.directoryReads, 1);
      expect(bridge.exports, 1);
      expect(bridge.exported, [1, 2, 3, 4, 5, 6]);
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test(
    'setup errors persist a retryable failure and release the scheduled id',
    () async {
      bridge.directoryFails = true;
      scheduler = createScheduler();
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.failed);
      expect((await store.get(task.id))!.error, contains('暂存目录不可用'));
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
      bridge.directoryFails = false;
      await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
    },
  );

  test(
    'activity acquisition failure is retryable and never starts file work',
    () async {
      bridge.acquireFails = true;
      scheduler = createScheduler();
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.failed);
      expect((await store.get(task.id))!.error, contains('无法保持后台下载'));
      expect(bridge.directoryReads, 0);
      expect(bridge.exports, 0);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
      bridge.acquireFails = false;
      await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test(
    'activity remains held through network retry and final export',
    () async {
      final saving = Completer<void>(), finishSave = Completer<void>();
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      var reads = 0;
      bridge.beforeSave = (_) {
        saving.complete();
        return finishSave.future;
      };
      scheduler = createScheduler(
        read: (offset, length) async* {
          expect(bridge.activeTasks, {task.id});
          if (++reads == 1) throw const GrpcError.unavailable('retry');
          yield Uint8List.fromList([1, 2, 3, 4, 5, 6]);
        },
      );
      try {
        await scheduler!.scheduleTransfer(task.id);
        await saving.future;
        expect(reads, 2);
        expect((await store.get(task.id))!.state, DownloadState.saving);
        expect(bridge.activeTasks, {task.id});
        expect(bridge.activityEvents, ['acquire:${task.id}']);
      } finally {
        finishSave.complete();
      }
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test('failed downloads release their activity after retries end', () async {
    var reads = 0;
    scheduler = createScheduler(
      read: (_, _) async* {
        reads++;
        throw const GrpcError.unavailable('offline');
      },
    );
    final task = await store.enqueue(_peer, _item, 'file:///Downloads');
    await scheduler!.scheduleTransfer(task.id);
    await _until(() async => (await scheduler!.scheduledTransferIds()).isEmpty);
    expect(reads, 3);
    expect((await store.get(task.id))!.state, DownloadState.failed);
    expect(bridge.activeTasks, isEmpty);
    expect(bridge.activityEvents, ['acquire:${task.id}', 'release:${task.id}']);
  });

  test(
    'an unreachable peer is retried automatically until it returns',
    () async {
      var reads = 0;
      scheduler = createScheduler(
        outageWindow: const Duration(minutes: 30),
        read: (offset, length) async* {
          // Two runs of three empty attempts each, then the peer is back.
          if (++reads <= 6) throw const GrpcError.unavailable('offline');
          yield Uint8List.fromList(
            [1, 2, 3, 4, 5, 6].sublist(offset, offset + length),
          );
        },
      );
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect(reads, 7);
      final done = (await store.get(task.id))!;
      expect(done.state, DownloadState.completed);
      expect(done.error, isNull);
      expect(done.outageSinceMs, isNull);
      expect(bridge.exported, [1, 2, 3, 4, 5, 6]);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test(
    'a waiting retry stays scheduled and queued, and cancellation ends the wait',
    () async {
      var reads = 0;
      scheduler = createScheduler(
        outageWindow: const Duration(minutes: 30),
        autoRetryDelay: const Duration(hours: 1),
        read: (_, _) async* {
          reads++;
          throw const GrpcError.unavailable('offline');
        },
      );
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(() async => (await store.get(task.id))!.error != null);
      final waiting = (await store.get(task.id))!;
      expect(waiting.state, DownloadState.queued);
      expect(waiting.error, contains('稍后会自动重试'));
      expect(waiting.outageSinceMs, isNotNull);
      expect(reads, 3);
      expect(await scheduler!.scheduledTransferIds(), [task.id]);
      await store.reconcile((await scheduler!.scheduledTransferIds()).toSet());
      expect(
        (await store.get(task.id))!.state,
        DownloadState.queued,
        reason: 'A task waiting for its peer is not an interrupted task',
      );
      expect(bridge.activeTasks, {task.id});
      await store.cancel(task.id);
      await scheduler!
          .cancelTransfer(task.id)
          .timeout(const Duration(seconds: 3));
      expect(await scheduler!.scheduledTransferIds(), isEmpty);
      expect((await store.get(task.id))!.state, DownloadState.cancelled);
      expect(reads, 3);
      expect(bridge.activeTasks, isEmpty);
    },
  );

  test(
    'cancellation while acquiring activity releases without file work',
    () async {
      final acquiring = Completer<void>(), finishAcquire = Completer<void>();
      bridge.beforeAcquire = () {
        acquiring.complete();
        return finishAcquire.future;
      };
      scheduler = createScheduler();
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await acquiring.future;
      await store.cancel(task.id);
      final cancelling = scheduler!.cancelTransfer(task.id);
      await Future<void>.delayed(Duration.zero);
      finishAcquire.complete();
      await cancelling;
      expect((await store.get(task.id))!.state, DownloadState.cancelled);
      expect(bridge.directoryReads, 0);
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test('activity release errors do not escape an unawaited worker', () async {
    bridge.releaseFails = true;
    scheduler = createScheduler();
    final task = await store.enqueue(_peer, _item, 'file:///Downloads');
    await scheduler!.scheduleTransfer(task.id);
    await _until(() async => (await scheduler!.scheduledTransferIds()).isEmpty);
    await scheduler!.shutdown();
    expect((await store.get(task.id))!.state, DownloadState.completed);
    expect(bridge.activityEvents, ['acquire:${task.id}', 'release:${task.id}']);
  });

  test(
    'concurrent tasks retain independent activity until each export ends',
    () async {
      final first = await store.enqueue(_peer, _item, 'file:///Downloads');
      final second = await store.enqueue(
        _peer,
        MediaItem(
          id: 'other',
          deviceId: _peer.id,
          name: 'other.jpg',
          sharedFolderId: 'camera',
          sharedFolderName: 'Camera',
          relativePath: '旅行/other.jpg',
          mimeType: 'image/jpeg',
          size: 6,
          modifiedMs: 1,
          thumbnail: Uint8List(0),
        ),
        'file:///Downloads',
      );
      final firstSave = Completer<void>(), secondSave = Completer<void>();
      final saving = <String>{};
      bridge.beforeSave = (name) {
        saving.add(name);
        return name == _item.name ? firstSave.future : secondSave.future;
      };
      scheduler = createScheduler();
      try {
        await Future.wait([
          scheduler!.scheduleTransfer(first.id),
          scheduler!.scheduleTransfer(second.id),
        ]);
        await _until(() async => saving.length == 2);
        expect(bridge.activeTasks, {first.id, second.id});
        firstSave.complete();
        await _until(() async => !bridge.activeTasks.contains(first.id));
        expect((await store.get(first.id))!.state, DownloadState.completed);
        expect(bridge.activeTasks, {second.id});
        expect(await scheduler!.scheduledTransferIds(), [second.id]);
      } finally {
        if (!firstSave.isCompleted) firstSave.complete();
        secondSave.complete();
      }
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(second.id))!.state, DownloadState.completed);
      expect(bridge.activeTasks, isEmpty);
      expect(
        bridge.activityEvents.where((event) => event == 'release:${first.id}'),
        hasLength(1),
      );
      expect(
        bridge.activityEvents.where((event) => event == 'release:${second.id}'),
        hasLength(1),
      );
    },
  );

  test(
    'cancel and immediate retry serialize part-file access and resume flushed bytes',
    () async {
      final partial = Completer<void>(), closed = Completer<void>();
      final releaseOldReader = Completer<void>();
      final offsets = <int>[];
      var first = true;
      scheduler = createScheduler(
        read: (offset, length) async* {
          offsets.add(offset);
          if (first) {
            first = false;
            yield Uint8List.fromList([1, 2, 3]);
            partial.complete();
            await releaseOldReader.future;
            throw const GrpcError.cancelled('cancelled');
          }
          yield Uint8List.fromList(
            [1, 2, 3, 4, 5, 6].sublist(offset, offset + length),
          );
        },
        onClose: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await partial.future;
      await store.cancel(task.id);
      final cancelling = scheduler!.cancelTransfer(task.id);
      await closed.future;
      await store.enqueue(_peer, _item, 'file:///Downloads');
      final retrying = scheduler!.scheduleTransfer(task.id);
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.directoryReads,
        1,
        reason: 'Retry waits for the old writer',
      );
      releaseOldReader.complete();
      await Future.wait([cancelling, retrying]);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
      expect((await store.get(task.id))!.attempt, 2);
      expect(offsets, [0, 3]);
      expect(bridge.exports, 1);
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
    },
  );

  test(
    'shutdown preserves parts, rejects schedules and restart offers manual retry',
    () async {
      final partial = Completer<void>(), closed = Completer<void>();
      scheduler = createScheduler(
        read: (offset, length) async* {
          yield Uint8List.fromList([1, 2, 3]);
          partial.complete();
          await closed.future;
          throw const GrpcError.cancelled('process exiting');
        },
        onClose: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      final task = await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await partial.future;
      await scheduler!.shutdown();
      expect(bridge.activeTasks, isEmpty);
      expect(bridge.activityEvents, [
        'acquire:${task.id}',
        'release:${task.id}',
      ]);
      await expectLater(scheduler!.scheduleTransfer(task.id), throwsStateError);
      expect((await store.get(task.id))!.state, DownloadState.queued);
      expect(
        await File(
          p.join(root.path, 'staging', task.id, '0.part'),
        ).readAsBytes(),
        [1, 2, 3],
      );
      await store.close();
      store = await TransferStore.open(
        path: p.join(root.path, 'tasks.db'),
        factory: databaseFactoryFfi,
      );
      scheduler = createScheduler();
      await store.reconcile((await scheduler!.scheduledTransferIds()).toSet());
      expect((await store.get(task.id))!.state, DownloadState.failed);
      expect((await store.get(task.id))!.error, contains('重试'));
      await store.enqueue(_peer, _item, 'file:///Downloads');
      await scheduler!.scheduleTransfer(task.id);
      await _until(
        () async => (await scheduler!.scheduledTransferIds()).isEmpty,
      );
      expect((await store.get(task.id))!.state, DownloadState.completed);
      expect(bridge.exported, [1, 2, 3, 4, 5, 6]);
    },
  );

  test(
    'controller automatically downloads through real gRPC while its window is hidden',
    () async {
      final server = MediaRpcServer(identity: _peer, source: MemorySource());
      await server.start();
      final desktop = _ControllerDesktopBridge(
        Directory(p.join(root.path, 'controller-staging')),
      );
      final model = AppController(
        bridge: desktop,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => store,
      );
      try {
        desktop.selection = {'uri': 'file:///Downloads', 'name': 'Downloads'};
        await repository.upsertPeer(_peer.copyWith(port: server.port));
        await model.initialize();
        await model.chooseDownloadFolder();
        final photo = model.media.single;
        await model.setForeground(false);
        expect(
          model.port,
          0,
          reason: 'Foreground sharing stops independently of downloads',
        );
        await model.download(photo);
        await _until(
          () async =>
              model.transfers[photo.key]?.status == TransferStatus.completed,
        );
        expect(desktop.savedBytes, [1, 2, 3]);
        expect(model.error, isNull);
      } finally {
        await model.shutdown();
        await desktop.events.close();
        await server.stop();
      }
    },
  );
}
