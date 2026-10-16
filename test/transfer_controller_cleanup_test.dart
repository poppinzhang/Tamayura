import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge;

const _peer = Peer(
  id: 'source',
  name: 'Source',
  host: '192.168.1.2',
  port: 4000,
);

MediaItem _photo(String id) => MediaItem(
  id: id,
  deviceId: _peer.id,
  name: '$id.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 3,
  modifiedMs: 123,
  thumbnail: Uint8List(0),
);

class _StopGate {
  final entered = Completer<void>();
  final released = Completer<void>();
}

class _CleanupBridge extends FakeBridge {
  _CleanupBridge(this.staging);
  final Directory staging;
  final stops = <String>[];
  final gates = <String, _StopGate>{};
  bool failDirectoryLookup = false;

  _StopGate holdStop(String taskId) => gates[taskId] = _StopGate();

  @override
  Future<String> transferDirectory() async {
    if (failDirectoryLookup) {
      throw PlatformException(code: 'STORAGE_ERROR', message: '暂存目录暂时不可访问');
    }
    return staging.path;
  }

  @override
  Future<void> cancelTransfer(String id) async {
    stops.add(id);
    final gate = gates[id];
    if (gate != null) {
      if (!gate.entered.isCompleted) gate.entered.complete();
      await gate.released.future;
    }
    scheduled.remove(id);
  }

  void releaseStops() {
    for (final gate in gates.values) {
      if (!gate.released.isCompleted) gate.released.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  late Directory staging;
  late TamayuraRepository repository;
  late TransferStore tasks;
  late TransferStore workerTasks;
  late _CleanupBridge bridge;
  late AppController model;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'tamayura-controller-cleanup-',
    );
    staging = await Directory('${temporary.path}/staging').create();
    repository = await TamayuraRepository.open(
      path: '${temporary.path}/library.db',
      factory: databaseFactoryFfi,
    );
    final taskPath = '${temporary.path}/tasks.db';
    tasks = await TransferStore.open(
      path: taskPath,
      factory: databaseFactoryFfi,
    );
    // A separate connection models the headless worker's writes while the UI
    // owns the controller and its transfer-store connection.
    workerTasks = await TransferStore.open(
      path: taskPath,
      factory: databaseFactoryFfiNoIsolate,
    );
    bridge = _CleanupBridge(staging);
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => repository,
      openTransfers: () async => tasks,
    );
    // Exercise explicit refreshes without a timer or unrelated LAN activity.
    await model.setForeground(false);
  });
  tearDown(() async {
    bridge.releaseStops();
    await model.shutdown();
    await workerTasks.close();
    await tasks.close();
    await repository.close();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  Future<File> writePart(String taskId) async {
    final directory = await Directory('${staging.path}/$taskId').create();
    return File('${directory.path}/0.part').writeAsBytes([1, 2, 3]);
  }

  Future<TransferTask> enqueue(String mediaId) =>
      tasks.enqueue(_peer, _photo(mediaId), '${temporary.path}/received');

  test(
    'discard waits for the writer and restores a save that wins the race',
    () async {
      final item = _photo('saved-during-stop');
      await repository.replacePeerSnapshot(_peer, [item]);
      final task = await enqueue(item.id);
      await workerTasks.claim(task.id, 'old-worker');
      await workerTasks.update(task.id, {
        'state': 'saving',
        'received': item.size,
      }, runToken: 'old-worker');
      final part = await writePart(task.id);
      bridge.scheduled.add(task.id);
      await model.initialize();
      expect(model.error, isNull);
      expect(model.media.single.key, item.key);
      expect(model.transfers[item.key]!.status, TransferStatus.saving);

      final gate = bridge.holdStop(task.id);
      var discardFinished = false;
      final discard = model.discardDownload(item.key).then((_) {
        discardFinished = true;
      });
      await gate.entered.future;
      expect(discardFinished, isFalse);
      expect(await part.exists(), isTrue);
      expect((await workerTasks.get(task.id))!.state, DownloadState.discarded);
      expect(await workerTasks.claim(task.id, 'late-worker'), isNull);
      expect(
        await workerTasks.update(task.id, {
          'state': 'completed',
          'saved_uri': 'file:///wrong.jpg',
        }, runToken: 'old-worker'),
        isFalse,
      );

      // The native writer finishes just before acknowledging cancellation. The
      // export and durable download record are authoritative, even though its
      // old run token can no longer complete the discarded task row.
      final received = await Directory('${temporary.path}/received').create();
      final exported = await File(
        '${received.path}/${item.name}',
      ).writeAsBytes(await part.readAsBytes());
      await repository.saveDownload(
        DownloadRecord(
          deviceId: item.deviceId,
          mediaId: item.id,
          uri: exported.uri.toString(),
          completedAt: DateTime.now(),
        ),
      );
      expect(await part.exists(), isTrue);
      gate.released.complete();
      await discard;

      expect(await tasks.get(task.id), isNull);
      expect(await part.parent.exists(), isFalse);
      expect(await exported.readAsBytes(), [1, 2, 3]);
      expect(
        (await repository.getDownload(item.deviceId, item.id))!.uri,
        exported.uri.toString(),
      );
      final view = model.transfers[item.key]!;
      expect(view.status, TransferStatus.completed);
      expect(view.complete, isTrue);
      expect(view.savedUri, exported.uri.toString());
      expect(view.receivedBytes, item.size);
      expect(model.error, isNull);
    },
  );

  test(
    'failed cleanup keeps a discard tombstone and succeeds on explicit retry',
    () async {
      final item = _photo('retry-cleanup');
      await repository.replacePeerSnapshot(_peer, [item]);
      final task = await enqueue(item.id);
      await tasks.cancel(task.id);
      final part = await writePart(task.id);
      await model.initialize();
      expect(model.transfers[item.key]!.status, TransferStatus.cancelled);

      bridge.failDirectoryLookup = true;
      await model.discardDownload(item.key);
      expect((await workerTasks.get(task.id))!.state, DownloadState.discarded);
      expect(model.transfers[item.key]!.status, TransferStatus.discarded);
      expect(await part.exists(), isTrue);
      expect(model.error, contains('暂存目录暂时不可访问'));
      await expectLater(enqueue(item.id), throwsStateError);

      bridge.failDirectoryLookup = false;
      model.clearError();
      await model.discardDownload(item.key);
      expect(await tasks.get(task.id), isNull);
      expect(await part.parent.exists(), isFalse);
      expect(model.transfers.containsKey(item.key), isFalse);
      expect(model.error, isNull);
      expect(bridge.stops.where((id) => id == task.id), hasLength(2));
    },
  );

  test(
    'startup drains discarded tasks and removes orphans while retaining pause',
    () async {
      final paused = await enqueue('paused');
      await tasks.cancel(paused.id);
      final pausedPart = await writePart(paused.id);
      final discarded = await enqueue('discarded');
      await workerTasks.claim(discarded.id, 'old-worker');
      await tasks.requestDiscard(discarded.id);
      final discardedPart = await writePart(discarded.id);
      final missingFolder = await enqueue('discarded-without-folder');
      await tasks.requestDiscard(missingFolder.id);
      final orphanPart = await writePart('orphan-task');
      bridge.scheduled.add(discarded.id);
      final gate = bridge.holdStop(discarded.id);

      final initialization = model.initialize();
      await gate.entered.future;
      expect(await discardedPart.exists(), isTrue);
      expect(await pausedPart.exists(), isTrue);
      expect(model.loading, isTrue);
      gate.released.complete();
      await initialization;

      expect(model.loading, isFalse);
      expect(model.error, isNull);
      expect(await tasks.get(discarded.id), isNull);
      expect(await tasks.get(missingFolder.id), isNull);
      expect(await discardedPart.parent.exists(), isFalse);
      expect(await orphanPart.parent.exists(), isFalse);
      expect(await pausedPart.readAsBytes(), [1, 2, 3]);
      expect((await tasks.get(paused.id))!.state, DownloadState.cancelled);
      expect(
        model.transfers[paused.item.key]!.status,
        TransferStatus.cancelled,
      );
      expect(bridge.stops, containsAll([discarded.id, missingFolder.id]));
      expect(bridge.stops, isNot(contains(paused.id)));
    },
  );
}
