import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/background/transfer_worker.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/downloader.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/android_bridge.dart';
import 'package:tamayura/platform/platform_bridge.dart';

const _peer = Peer(
  id: 'source-phone',
  name: '来源手机',
  host: '127.0.0.1',
  port: 50728,
);

MediaItem _item({
  String id = 'photo',
  int size = 10,
  int modified = 1234,
  String deviceId = 'source-phone',
  String folderId = 'camera',
  String folderName = 'Camera',
  String? relativePath,
}) => MediaItem(
  id: id,
  deviceId: deviceId,
  name: '$id.jpg',
  sharedFolderId: folderId,
  sharedFolderName: folderName,
  relativePath: relativePath ?? '旅行/秋天/$id.jpg',
  mimeType: 'image/jpeg',
  size: size,
  modifiedMs: modified,
  thumbnail: Uint8List.fromList([1, 2, 3]),
);

class _ExportBridge extends AndroidBridge {
  _ExportBridge(this.exports);
  final Directory exports;
  int saves = 0;
  TransferSpaceInfo space = const TransferSpaceInfo();
  final spaceChecks = <String>[];

  @override
  Future<TransferSpaceInfo> transferSpace({
    required String directoryUri,
  }) async {
    spaceChecks.add(directoryUri);
    return space;
  }

  bool fail = false;
  String? savedName, destination;
  List<String>? savedDirectories;
  List<String>? savedSourcePaths;
  File? exported;
  Future<void> Function()? beforeSave;

  @override
  Future<String> saveDownload({
    required List<String> sourcePaths,
    required int expectedSize,
    required String directoryUri,
    required String name,
    required String mimeType,
    required List<String> directories,
  }) async {
    saves++;
    await beforeSave?.call();
    if (fail) {
      throw PlatformException(code: 'PERMISSION', message: '接收目录权限已失效');
    }
    expect(mimeType, 'image/jpeg');
    destination = directoryUri;
    savedName = name;
    savedDirectories = directories;
    savedSourcePaths = List.of(sourcePaths);
    await exports.create(recursive: true);
    exported = File(p.join(exports.path, name));
    final output = await exported!.open(mode: FileMode.write);
    try {
      for (final path in sourcePaths) {
        await for (final bytes in File(path).openRead()) {
          await output.writeFrom(bytes);
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }
    expect(await exported!.length(), expectedSize);
    return 'content://tamayura-test/$name';
  }
}

class _MemorySource implements LocalMediaSource {
  _MemorySource(this.item, this.bytes);
  final MediaItem item;
  final Uint8List bytes;
  final List<int> offsets = [];

  @override
  Future<List<MediaMetadata>> scan() async => [item];
  @override
  Future<Uint8List> readThumbnail(String id) async => item.thumbnail;
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    expect(id, item.id);
    offsets.add(offset);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

/// Only the runner's identity/read/close surface is faked. Data transfer itself
/// still uses the real resumable downloader and files on disk.
class _ScriptClient implements MediaRpcClient {
  _ScriptClient(this.peer, this.read, {this.onClose, this.identityOverride});
  @override
  final Peer peer;
  final Stream<Uint8List> Function(String id, int offset, int length) read;
  final void Function()? onClose;
  final Peer? identityOverride;
  bool _reading = false;
  bool _closed = false;

  @override
  Future<Peer> identity() async => identityOverride ?? peer;
  @override
  Stream<Uint8List> readRange(String id, int offset, int length) {
    _reading = true;
    return read(id, offset, length);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_reading) onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late Directory staging;
  late TransferStore store;
  late TamayuraRepository repository;
  late _ExportBridge bridge;

  Future<TransferStore> openStore() => TransferStore.open(
    path: p.join(root.path, 'transfers.db'),
    factory: databaseFactoryFfi,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tamayura-transfer-test-');
    staging = Directory(p.join(root.path, 'staging'));
    store = await openStore();
    repository = await TamayuraRepository.open(
      path: p.join(root.path, 'catalog.db'),
      factory: databaseFactoryFfi,
    );
    bridge = _ExportBridge(Directory(p.join(root.path, 'exports')));
  });

  tearDown(() async {
    await store.close();
    await repository.close();
    await root.delete(recursive: true);
  });

  TransferRunner runner({
    MediaRpcClient Function(Peer)? clientFactory,
    Future<void> Function(int, int, String)? progress,
    DateTime Function()? clock,
    Duration stallTimeout = defaultStallTimeout,
  }) => TransferRunner(
    store: store,
    repository: repository,
    bridge: bridge,
    directory: staging,
    clientFactory: clientFactory,
    progress: progress,
    retryDelay: Duration.zero,
    clock: clock,
    stallTimeout: stallTimeout,
  );

  group('durable transfer store', () {
    test(
      'nested destination and metadata survive process restart and retry',
      () async {
        final item = _item();
        final task = await store.enqueue(_peer, item, 'content://receive');
        expect(task.destinationDirectories, ['来源手机', 'Camera', '旅行', '秋天']);
        await store.cancel(task.id);
        await store.close();
        store = await openStore();
        final restored = (await store.get(task.id))!;
        expect(restored.item.sharedFolderId, 'camera');
        expect(restored.item.relativePath, '旅行/秋天/photo.jpg');
        final retried = await store.enqueue(
          _peer.copyWith(name: '手机已改名'),
          item,
          'content://receive',
        );
        expect(retried.destinationDirectories, restored.destinationDirectories);
        expect(retried.id, restored.id);
      },
    );

    test(
      'equal device/root names and sanitized nested names never share a destination',
      () async {
        final first = await store.enqueue(_peer, _item(), 'content://receive');
        const otherPeer = Peer(
          id: 'second-phone',
          name: '来源手机',
          host: '127.0.0.1',
          port: 50728,
        );
        final otherDevice = await store.enqueue(
          otherPeer,
          _item(deviceId: otherPeer.id),
          'content://receive',
        );
        expect(otherDevice.destinationDirectories.first, '来源手机 (2)');
        final otherRoot = await store.enqueue(
          _peer,
          _item(id: 'another', folderId: 'second-camera'),
          'content://receive',
        );
        expect(otherRoot.destinationDirectories.take(2), [
          '来源手机',
          'Camera (2)',
        ]);
        expect(first.destinationDirectories.take(2), ['来源手机', 'Camera']);
        final punctuation = await store.enqueue(
          _peer,
          _item(id: 'one', relativePath: 'trip?/one.jpg'),
          'content://receive',
        );
        final sanitized = await store.enqueue(
          _peer,
          _item(id: 'two', relativePath: 'trip*/two.jpg'),
          'content://receive',
        );
        expect(punctuation.destinationDirectories.last, 'trip_');
        expect(sanitized.destinationDirectories.last, 'trip_ (2)');
        final sameSubfolder = await store.enqueue(
          _peer,
          _item(id: 'three', relativePath: 'trip?/three.jpg'),
          'content://receive',
        );
        expect(
          sameSubfolder.destinationDirectories,
          punctuation.destinationDirectories,
        );
        final sibling = await store.enqueue(
          _peer,
          _item(id: 'four', relativePath: 'summer/trip?/four.jpg'),
          'content://receive',
        );
        expect(sibling.destinationDirectories.skip(2), ['summer', 'trip_']);
        final rootFile = await store.enqueue(
          _peer,
          _item(id: 'five', relativePath: 'five.jpg'),
          'content://receive',
        );
        expect(rootFile.destinationDirectories, ['来源手机', 'Camera']);
      },
    );

    test(
      'case collisions and receive roots have independent stable mappings',
      () async {
        await store.enqueue(_peer, _item(), 'content://receive');
        final differentlyCased = await store.enqueue(
          _peer,
          _item(id: 'case', folderId: 'other', folderName: 'camera'),
          'content://receive',
        );
        expect(differentlyCased.destinationDirectories[1], 'camera (2)');
        final anotherDestination = await store.enqueue(
          _peer,
          _item(id: 'elsewhere', folderId: 'other', folderName: 'camera'),
          'content://elsewhere',
        );
        expect(anotherDestination.destinationDirectories[1], 'camera');
        final accented = await store.enqueue(
          _peer,
          _item(id: 'accent', folderId: 'summer-a', folderName: 'Été'),
          'content://receive',
        );
        final accentedLower = await store.enqueue(
          _peer,
          _item(id: 'accent-lower', folderId: 'summer-b', folderName: 'été'),
          'content://receive',
        );
        expect(accented.destinationDirectories[1], 'Été');
        expect(accentedLower.destinationDirectories[1], 'été (2)');
      },
    );

    test('invalid relative paths never become queued jobs', () async {
      for (final path in [
        '../photo.jpg',
        '/photo.jpg',
        'a//photo.jpg',
        'a/./photo.jpg',
        r'a\photo.jpg',
        'different.jpg',
      ]) {
        await expectLater(
          store.enqueue(_peer, _item(relativePath: path), 'content://receive'),
          throwsFormatException,
        );
      }
      expect(await store.recent(), isEmpty);
    });

    test(
      'reconcile with an old snapshot leaves new jobs and new attempts queued',
      () async {
        final old = await store.enqueue(
          _peer,
          _item(id: 'old-attempt'),
          'content://receive',
        );
        final abandoned = await store.enqueue(
          _peer,
          _item(id: 'abandoned'),
          'content://receive',
        );
        final candidates = await store.recent();
        final newlyQueued = await store.enqueue(
          _peer,
          _item(id: 'brand-new'),
          'content://receive',
        );
        await store.cancel(old.id);
        final newerAttempt = await store.enqueue(
          _peer,
          old.item,
          'content://replacement',
        );
        expect(newerAttempt.attempt, 2);
        await store.reconcile({}, candidates: candidates);
        expect((await store.get(newlyQueued.id))!.state, DownloadState.queued);
        final retry = (await store.get(old.id))!;
        expect(retry.state, DownloadState.queued);
        expect(retry.attempt, 2);
        expect(retry.error, isNull);
        expect((await store.get(abandoned.id))!.state, DownloadState.failed);
      },
    );

    test(
      'setup failure cannot revive cancellation or overwrite a newer attempt',
      () async {
        final item = _item();
        final first = await store.enqueue(_peer, item, 'content://receive');
        await store.cancel(first.id);
        await store.failSetup(first.id, first.attempt, 'old setup failed');
        final cancelled = (await store.get(first.id))!;
        expect(cancelled.state, DownloadState.cancelled);
        expect(cancelled.error, isNull);

        final second = await store.enqueue(
          _peer,
          item,
          'content://replacement',
        );
        expect(second.attempt, 2);
        await store.failSetup(
          first.id,
          first.attempt,
          'old setup failed again',
        );
        final queued = (await store.get(second.id))!;
        expect(queued.state, DownloadState.queued);
        expect(queued.attempt, 2);
        expect(queued.error, isNull);
        expect(queued.runToken, isNull);

        await store.failSetup(
          second.id,
          second.attempt,
          'current setup failed',
        );
        final failed = (await store.get(second.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.error, 'current setup failed');
      },
    );

    test('retains all task data across close and a new connection', () async {
      final item = _item();
      final task = await store.enqueue(_peer, item, 'content://receive/album');
      await store.claim(task.id, 'worker-one');
      await store.update(task.id, {'received': 4}, runToken: 'worker-one');
      await store.close();
      store = await openStore();
      final restored = (await store.get(task.id))!;
      expect(restored.state, DownloadState.downloading);
      expect(restored.received, 4);
      expect(restored.attempt, 1);
      expect(restored.directoryUri, 'content://receive/album');
      expect(restored.peer.id, _peer.id);
      expect(restored.peer.host, _peer.host);
      expect(restored.peer.port, _peer.port);
      expect(restored.item.hasSameMetadata(item), isTrue);
      expect(restored.item.thumbnail, orderedEquals(item.thumbnail));
      expect((await store.forMedia(_peer.id, item.id))!.id, task.id);
    });

    test(
      'independent worker connection closes without closing the UI store',
      () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        final worker = await openStore();
        await worker.claim(task.id, 'worker');
        await worker.update(task.id, {'received': 3}, runToken: 'worker');
        expect((await store.get(task.id))!.received, 3);
        await worker.close();
        expect((await store.get(task.id))!.state, DownloadState.downloading);
        await store.cancel(task.id);
        expect((await store.get(task.id))!.state, DownloadState.cancelled);
      },
    );

    test('enqueue is idempotent while active or already completed', () async {
      final item = _item();
      final task = await store.enqueue(_peer, item, 'content://first');
      final duplicate = await store.enqueue(_peer, item, 'content://second');
      expect(duplicate.id, task.id);
      expect(duplicate.directoryUri, 'content://first');
      expect(duplicate.attempt, 1);
      await store.update(task.id, {
        'state': 'completed',
        'saved_uri': 'content://saved',
      });
      final completed = await store.enqueue(_peer, item, 'content://third');
      expect(completed.id, task.id);
      expect(completed.attempt, 1);
      expect(completed.state, DownloadState.completed);
      await store.cancel(task.id);
      expect((await store.get(task.id))!.state, DownloadState.completed);
    });

    test(
      'cancel and a newer attempt reject every old worker mutation',
      () async {
        final item = _item();
        final task = await store.enqueue(_peer, item, 'content://receive');
        await store.claim(task.id, 'old-worker');
        await store.update(task.id, {'received': 4}, runToken: 'old-worker');
        await store.cancel(task.id);
        expect(
          await store.update(task.id, {
            'state': 'completed',
            'saved_uri': 'content://stale',
          }, runToken: 'old-worker'),
          isFalse,
        );
        expect(await store.claim(task.id, 'cannot-claim-cancelled'), isNull);
        final retry = await store.enqueue(
          _peer,
          item,
          'content://new-destination',
        );
        expect(retry.id, task.id);
        expect(retry.received, 4);
        expect(retry.attempt, 2);
        expect(retry.runToken, isNull);
        expect(
          await store.update(task.id, {
            'state': 'failed',
            'error': 'stale',
          }, runToken: 'old-worker'),
          isFalse,
        );
        await store.claim(task.id, 'new-worker');
        expect(
          await store.update(task.id, {'received': 9}, runToken: 'new-worker'),
          isTrue,
        );
        expect(
          await store.update(task.id, {'received': 5}, runToken: 'old-worker'),
          isFalse,
        );
        final current = (await store.get(task.id))!;
        expect(current.received, 9);
        expect(current.state, DownloadState.downloading);
        expect(current.runToken, 'new-worker');
        expect(current.error, isNull);
        expect(current.savedUri, isNull);
      },
    );

    test(
      're-enqueue resets resume count when source metadata changed',
      () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        await store.update(task.id, {
          'state': 'failed',
          'received': 7,
          'error': 'offline',
        });
        final retry = await store.enqueue(
          _peer,
          _item(size: 12, modified: 5678),
          'content://receive',
        );
        expect(retry.id, task.id);
        expect(retry.received, 0);
        expect(retry.attempt, 2);
        expect(retry.item.size, 12);
        expect(retry.error, isNull);
      },
    );

    test(
      'reconcile fails unscheduled active jobs and preserves all other states',
      () async {
        final queued = await store.enqueue(
          _peer,
          _item(id: 'queued'),
          'content://receive',
        );
        final downloading = await store.enqueue(
          _peer,
          _item(id: 'running'),
          'content://receive',
        );
        final saving = await store.enqueue(
          _peer,
          _item(id: 'saving'),
          'content://receive',
        );
        final scheduled = await store.enqueue(
          _peer,
          _item(id: 'scheduled'),
          'content://receive',
        );
        final cancelled = await store.enqueue(
          _peer,
          _item(id: 'cancelled'),
          'content://receive',
        );
        final complete = await store.enqueue(
          _peer,
          _item(id: 'complete'),
          'content://receive',
        );
        await store.claim(downloading.id, 'orphan-worker');
        await store.update(downloading.id, {'received': 3});
        await store.claim(saving.id, 'orphan-saver');
        await store.update(saving.id, {'state': 'saving'});
        await store.cancel(cancelled.id);
        await store.update(complete.id, {
          'state': 'completed',
          'saved_uri': 'content://saved',
        });
        await store.reconcile({scheduled.id});
        for (final orphan in [queued, downloading, saving]) {
          final current = (await store.get(orphan.id))!;
          expect(current.state, DownloadState.failed);
          expect(current.runToken, isNull);
          expect(current.error, contains('重试'));
        }
        expect((await store.get(downloading.id))!.received, 3);
        expect((await store.get(scheduled.id))!.state, DownloadState.queued);
        expect((await store.get(cancelled.id))!.state, DownloadState.cancelled);
        expect((await store.get(complete.id))!.savedUri, 'content://saved');
        expect(
          await store.update(downloading.id, {
            'state': 'completed',
          }, runToken: 'orphan-worker'),
          isFalse,
        );
      },
    );

    test(
      'recent history retains active work beyond the history window',
      () async {
        final active = await store.enqueue(
          _peer,
          _item(id: 'old-active'),
          'content://receive',
        );
        for (var i = 0; i < 105; i++) {
          final done = await store.enqueue(
            _peer,
            _item(id: 'done-$i'),
            'content://receive',
          );
          await store.update(done.id, {
            'state': 'completed',
            'saved_uri': 'content://saved/$i',
          });
        }
        final recent = await store.recent();
        expect(
          recent.any((task) => task.id == active.id && task.active),
          isTrue,
        );
        expect(recent.where((task) => !task.active).length, 100);
      },
    );

    test(
      'invalidated exports become retryable without a stale saved URI',
      () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        await store.update(task.id, {
          'state': 'completed',
          'saved_uri': 'content://missing',
        });
        await store.invalidate(_peer.id, task.item.id);
        final invalidated = (await store.get(task.id))!;
        expect(invalidated.state, DownloadState.failed);
        expect(invalidated.savedUri, isNull);
        expect(invalidated.error, contains('重新下载'));
      },
    );
  });

  group('background transfer runner', () {
    test(
      'already stopped runner cannot claim or mutate a newer active attempt',
      () async {
        var clientsCreated = 0;
        final worker = runner(
          clientFactory: (peer) {
            clientsCreated++;
            throw StateError('A stopped runner must never connect');
          },
        );
        for (final activeState in [
          DownloadState.queued,
          DownloadState.downloading,
        ]) {
          final item = _item(id: activeState.name);
          final first = await store.enqueue(_peer, item, 'content://receive');
          await store.cancel(first.id);
          final second = await store.enqueue(
            _peer,
            item,
            'content://replacement',
          );
          if (activeState == DownloadState.downloading) {
            await store.claim(second.id, 'new-worker');
            await store.update(second.id, {
              'received': 4,
            }, runToken: 'new-worker');
          }
          final before = (await store.get(second.id))!;
          final stopped = DownloadCancellation()..cancel();
          await worker.run(
            second.id,
            cancellation: stopped,
            isUserCancelled: () => true,
          );
          final after = (await store.get(second.id))!;
          expect(after.state, before.state);
          expect(after.attempt, 2);
          expect(after.runToken, before.runToken);
          expect(after.received, before.received);
          expect(after.updatedMs, before.updatedMs);
          expect(after.error, isNull);
        }
        expect(clientsCreated, 0);
        expect(bridge.saves, 0);
      },
    );

    test(
      'superseded worker cannot export or complete a newly claimed attempt',
      () async {
        final item = _item(size: 6);
        final task = await store.enqueue(_peer, item, 'content://receive');
        final firstChunk = Completer<void>();
        final continueOldWorker = Completer<void>();
        Stream<Uint8List> read(String id, int offset, int length) async* {
          yield Uint8List.fromList([1, 2, 3]);
          firstChunk.complete();
          await continueOldWorker.future;
          yield Uint8List.fromList([4, 5, 6]);
        }

        final oldRun = runner(
          clientFactory: (peer) => _ScriptClient(peer, read),
        ).run(task.id);
        await firstChunk.future.timeout(const Duration(seconds: 3));
        await store.cancel(task.id);
        final retry = await store.enqueue(
          _peer,
          item,
          'content://new-destination',
        );
        await store.claim(retry.id, 'replacement-worker');
        continueOldWorker.complete();
        await oldRun.timeout(const Duration(seconds: 3));
        final current = (await store.get(task.id))!;
        expect(current.state, DownloadState.downloading);
        expect(current.runToken, 'replacement-worker');
        expect(current.attempt, 2);
        expect(current.directoryUri, 'content://new-destination');
        expect(current.savedUri, isNull);
        expect(bridge.saves, 0);
        expect(await repository.getDownload(_peer.id, item.id), isNull);
      },
    );

    test(
      'real gRPC file reaches export, commits both records, and cleans staging',
      () async {
        // Two full chunks and a partial one.
        final bytes = Uint8List.fromList(
          List.generate(mediaChunkSize * 2 + 76033, (index) => index % 251),
        );
        final item = _item(size: bytes.length);
        final source = _MemorySource(item, bytes);
        final server = MediaRpcServer(identity: _peer, source: source);
        await server.start();
        addTearDown(server.stop);
        final peer = _peer.copyWith(port: server.port);
        // The task remembered an old address, but a fresh discovery updates it.
        await repository.upsertPeer(peer);
        final task = await store.enqueue(
          _peer.copyWith(port: 1),
          item,
          'content://receive',
        );
        bridge.beforeSave = () async {
          expect((await store.get(task.id))!.state, DownloadState.saving);
          expect(
            await File(
              p.join(staging.path, task.id, 'complete.partial'),
            ).exists(),
            isFalse,
          );
        };
        final progress = <int>[];
        await runner(
          progress: (received, total, name) async {
            progress.add(received);
            expect(total, bytes.length);
            expect(name, item.name);
          },
        ).run(task.id);
        final done = (await store.get(task.id))!;
        expect(done.state, DownloadState.completed);
        expect(done.received, bytes.length);
        expect(done.error, isNull);
        expect(await bridge.exported!.readAsBytes(), orderedEquals(bytes));
        expect(bridge.destination, 'content://receive');
        expect(bridge.savedDirectories, ['来源手机', 'Camera', '旅行', '秋天']);
        expect(
          (await repository.getDownload(peer.id, item.id))!.uri,
          done.savedUri,
        );
        expect(progress.last, bytes.length);
        expect(source.offsets.length, 3);
        expect(
          await Directory(p.join(staging.path, task.id)).exists(),
          isFalse,
        );
        await runner().run(task.id);
        expect(
          bridge.saves,
          1,
          reason: 'A completed system job must not export twice',
        );
      },
    );

    test(
      'large transfers export all four ordered parts without another staging copy',
      () async {
        final size = parallelDownloadThreshold + 3;
        final item = _item(size: size);
        final task = await store.enqueue(_peer, item, 'content://receive');
        final ranges = downloadRanges(size);
        bridge.beforeSave = () async {
          final files = await Directory(
            p.join(staging.path, task.id),
          ).list().toList();
          expect(
            files.map((file) => p.basename(file.path)),
            unorderedEquals([
              'manifest.json',
              '0.part',
              '1.part',
              '2.part',
              '3.part',
            ]),
          );
          var staged = 0;
          for (final file in files.whereType<File>().where(
            (file) => file.path.endsWith('.part'),
          )) {
            staged += await file.length();
          }
          expect(staged, size);
        };
        await runner(
          clientFactory: (peer) =>
              _ScriptClient(peer, (_, offset, length) async* {
                final marker =
                    ranges.indexWhere((range) => range.offset == offset) + 1;
                while (length > 0) {
                  final count = length.clamp(0, 256 * 1024);
                  yield Uint8List(count)..fillRange(0, count, marker);
                  length -= count;
                }
              }),
        ).run(task.id);
        expect((await store.get(task.id))!.state, DownloadState.completed);
        expect(bridge.savedSourcePaths!.map(p.basename), [
          '0.part',
          '1.part',
          '2.part',
          '3.part',
        ]);
        final exported = await bridge.exported!.open();
        try {
          for (var index = 0; index < ranges.length; index++) {
            final range = ranges[index];
            await exported.setPosition(range.offset);
            expect(await exported.readByte(), index + 1);
            await exported.setPosition(range.offset + range.length - 1);
            expect(await exported.readByte(), index + 1);
          }
        } finally {
          await exported.close();
        }
      },
    );

    test(
      'a lost peer queues automatic retries until the outage window ends, keeping flushed parts',
      () async {
        final bytes = Uint8List.fromList(List.generate(10, (index) => index));
        final item = _item(size: bytes.length);
        final task = await store.enqueue(_peer, item, 'content://receive');
        var offline = true;
        var now = DateTime(2026, 10, 17, 9);
        final offsets = <int>[];
        Stream<Uint8List> read(String id, int offset, int length) async* {
          offsets.add(offset);
          if (offline) {
            if (offset == 0) yield Uint8List.sublistView(bytes, 0, 4);
            throw const GrpcError.unavailable(
              'network temporarily disconnected',
            );
          }
          yield Uint8List.sublistView(bytes, offset, offset + length);
        }

        final worker = runner(
          clientFactory: (peer) => _ScriptClient(peer, read),
          clock: () => now,
        );
        expect(await worker.run(task.id), TransferOutcome.retryLater);
        final waiting = (await store.get(task.id))!;
        expect(waiting.state, DownloadState.queued);
        expect(waiting.received, 4);
        expect(waiting.error, contains('稍后会自动重试'));
        expect(waiting.outageSinceMs, now.millisecondsSinceEpoch);
        expect(
          offsets,
          [0, 4, 4, 4],
          reason: 'Arriving bytes reset the count before three empty attempts',
        );
        final part = File(p.join(staging.path, task.id, '0.part'));
        expect(await part.readAsBytes(), orderedEquals(bytes.take(4)));

        // Still unreachable: the outage keeps its original start.
        final started = now;
        now = now.add(const Duration(minutes: 10));
        expect(await worker.run(task.id), TransferOutcome.retryLater);
        expect(
          (await store.get(task.id))!.outageSinceMs,
          started.millisecondsSinceEpoch,
        );

        // Past the window the task fails and waits for the user.
        now = started.add(transferOutageWindow);
        expect(await worker.run(task.id), TransferOutcome.finished);
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.error, isNot(contains('自动重试')));
        expect(failed.outageSinceMs, isNull);
        expect(await part.readAsBytes(), orderedEquals(bytes.take(4)));
        expect(bridge.saves, 0);

        offline = false;
        final retry = await store.enqueue(_peer, item, 'content://receive');
        expect(retry.id, task.id);
        expect(retry.attempt, 2);
        expect(retry.outageSinceMs, isNull);
        await worker.run(task.id);
        expect(offsets.last, 4);
        expect((await store.get(task.id))!.state, DownloadState.completed);
        expect(await bridge.exported!.readAsBytes(), orderedEquals(bytes));
        expect(await part.exists(), isFalse);
      },
    );

    test('bytes arriving during an outage restart its window', () async {
      final item = _item(size: 10);
      final task = await store.enqueue(_peer, item, 'content://receive');
      var now = DateTime(2026, 10, 17, 9);
      var deliver = 0;
      Stream<Uint8List> read(String id, int offset, int length) async* {
        if (deliver > 0) {
          final count = deliver;
          deliver = 0;
          yield Uint8List(count);
        }
        throw const GrpcError.unknown('HTTP/2 error: Connection error');
      }

      final worker = runner(
        clientFactory: (peer) => _ScriptClient(peer, read),
        clock: () => now,
      );
      final started = now;
      expect(await worker.run(task.id), TransferOutcome.retryLater);
      expect(
        (await store.get(task.id))!.outageSinceMs,
        started.millisecondsSinceEpoch,
      );
      now = started.add(const Duration(minutes: 20));
      deliver = 3;
      expect(await worker.run(task.id), TransferOutcome.retryLater);
      expect(
        (await store.get(task.id))!.outageSinceMs,
        now.millisecondsSinceEpoch,
      );
      now = started.add(const Duration(minutes: 40));
      expect(
        await worker.run(task.id),
        TransferOutcome.retryLater,
        reason: 'Only 20 minutes have passed since bytes last arrived',
      );
      expect((await store.get(task.id))!.received, 3);
    });

    for (final stopImmediately in [true, false]) {
      test(
        'recovery clears the old outage ${stopImmediately ? 'when immediately stopped' : 'before a system stop'}',
        () async {
          final task = await store.enqueue(_peer, _item(), 'content://receive');
          final started = DateTime(2026, 10, 17, 9);
          var now = started.add(const Duration(minutes: 20));
          await store.update(task.id, {
            'outage_since_ms': started.millisecondsSinceEpoch,
          });
          final observer = await openStore();
          addTearDown(observer.close);
          final initialProgress = Completer<void>();
          final recoverySaved = Completer<TransferTask>();
          final channelClosed = Completer<void>();
          final cancellation = DownloadCancellation();
          Stream<Uint8List> read(String id, int offset, int length) async* {
            await initialProgress.future;
            yield Uint8List.fromList([1, 2, 3]);
            if (stopImmediately) cancellation.cancel();
            await channelClosed.future;
            throw const GrpcError.cancelled('system stop');
          }

          final running = runner(
            clock: () => now,
            clientFactory: (peer) => _ScriptClient(
              peer,
              read,
              onClose: () {
                if (!channelClosed.isCompleted) channelClosed.complete();
              },
            ),
            progress: (received, _, _) async {
              if (received == 0 && !initialProgress.isCompleted) {
                initialProgress.complete();
              }
              if (received == 3 && !recoverySaved.isCompleted) {
                recoverySaved.complete((await observer.get(task.id))!);
              }
            },
          ).run(task.id, cancellation: cancellation);
          try {
            if (!stopImmediately) {
              // The injected clock has not advanced past the 400 ms throttle.
              // Another connection must see recovery while the run is active.
              final active = await recoverySaved.future.timeout(
                const Duration(seconds: 3),
              );
              expect(active.state, DownloadState.downloading);
              expect(active.received, 3);
              expect(active.outageSinceMs, isNull);
            }
          } finally {
            if (!stopImmediately) cancellation.cancel();
            await running.timeout(const Duration(seconds: 3));
          }
          final paused = (await store.get(task.id))!;
          expect(paused.state, DownloadState.queued);
          expect(paused.received, 3);
          expect(paused.outageSinceMs, isNull);
          expect(bridge.saves, 0);

          // A new worker must not apply the outage from before the recovery.
          await store.close();
          store = await openStore();
          now = started.add(const Duration(minutes: 31));
          expect(
            await runner(
              clock: () => now,
              clientFactory: (peer) => _ScriptClient(
                peer,
                (_, _, _) => Stream.error(const GrpcError.unavailable()),
              ),
            ).run(task.id),
            TransferOutcome.retryLater,
          );
          final waiting = (await store.get(task.id))!;
          expect(waiting.state, DownloadState.queued);
          expect(waiting.outageSinceMs, now.millisecondsSinceEpoch);
        },
      );
    }

    test('a system stop without new bytes preserves the old outage', () async {
      final task = await store.enqueue(_peer, _item(), 'content://receive');
      final started = DateTime(2026, 10, 17, 9);
      var now = started.add(const Duration(minutes: 20));
      await store.update(task.id, {
        'outage_since_ms': started.millisecondsSinceEpoch,
      });
      final cancellation = DownloadCancellation();
      Stream<Uint8List> read(String id, int offset, int length) async* {
        cancellation.cancel();
        throw const GrpcError.cancelled('system stop');
      }

      await runner(
        clock: () => now,
        clientFactory: (peer) => _ScriptClient(peer, read),
      ).run(task.id, cancellation: cancellation);
      final paused = (await store.get(task.id))!;
      expect(paused.state, DownloadState.queued);
      expect(paused.received, 0);
      expect(paused.outageSinceMs, started.millisecondsSinceEpoch);

      now = started.add(const Duration(minutes: 31));
      expect(
        await runner(
          clock: () => now,
          clientFactory: (peer) => _ScriptClient(
            peer,
            (_, _, _) => Stream.error(const GrpcError.unavailable()),
          ),
        ).run(task.id),
        TransferOutcome.finished,
      );
      expect((await store.get(task.id))!.state, DownloadState.failed);
    });

    test(
      'existing parts ahead of stored progress do not reset an outage',
      () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        var now = DateTime(2026, 10, 17, 9);
        final offsets = <int>[];
        Stream<Uint8List> read(String id, int offset, int length) async* {
          offsets.add(offset);
          if (offset == 0) yield Uint8List.fromList([1, 2, 3]);
          throw const GrpcError.unavailable('offline');
        }

        final worker = runner(
          clock: () => now,
          clientFactory: (peer) => _ScriptClient(peer, read),
        );
        expect(await worker.run(task.id), TransferOutcome.retryLater);
        // The process can stop after flushing parts but before recording progress.
        await store.update(task.id, {'received': 0});
        now = now.add(const Duration(minutes: 31));
        offsets.clear();
        expect(await worker.run(task.id), TransferOutcome.finished);
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.received, 3);
        expect(offsets, [3, 3, 3]);
      },
    );

    test(
      'a silent peer is caught by the stall watchdog and retried later',
      () async {
        final item = _item(size: 6);
        final task = await store.enqueue(_peer, item, 'content://receive');
        final streams = <StreamController<Uint8List>>[];
        Stream<Uint8List> read(String id, int offset, int length) {
          // A peer that went to sleep: no more bytes, no error, no reset.
          final stream = StreamController<Uint8List>();
          streams.add(stream);
          if (offset == 0) stream.add(Uint8List.fromList([1, 2]));
          return stream.stream;
        }

        final outcome = await runner(
          stallTimeout: const Duration(milliseconds: 50),
          clientFactory: (peer) => _ScriptClient(
            peer,
            read,
            onClose: () {
              for (final stream in streams) {
                if (!stream.isClosed) unawaited(stream.close());
              }
            },
          ),
        ).run(task.id).timeout(const Duration(seconds: 5));
        expect(outcome, TransferOutcome.retryLater);
        final waiting = (await store.get(task.id))!;
        expect(waiting.state, DownloadState.queued);
        expect(waiting.received, 2);
        expect(waiting.error, contains('对端长时间没有响应'));
        expect(streams, hasLength(4));
        expect(
          await File(p.join(staging.path, task.id, '0.part')).readAsBytes(),
          [1, 2],
        );
      },
    );

    for (final (name, error) in [
      ('deleted file', const GrpcError.notFound('Media is not shared')),
      ('changed file', const GrpcError.dataLoss('size changed')),
      ('unusable folder', const GrpcError.failedPrecondition('revoked')),
    ]) {
      test('$name fails at once without automatic retry', () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        var reads = 0;
        Stream<Uint8List> read(String id, int offset, int length) async* {
          reads++;
          throw error;
        }

        expect(
          await runner(
            clientFactory: (peer) => _ScriptClient(peer, read),
          ).run(task.id),
          TransferOutcome.finished,
        );
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.error, isNot(contains('自动重试')));
        expect(reads, 1);
      });
    }

    for (final manuallyCancelled in [false, true]) {
      test(
        '${manuallyCancelled ? 'manual cancellation' : 'system stop'} preserves resumable bytes and correct state',
        () async {
          final item = _item();
          final task = await store.enqueue(_peer, item, 'content://receive');
          final partialWritten = Completer<void>();
          final channelClosed = Completer<void>();
          final cancellation = DownloadCancellation();
          Stream<Uint8List> read(String id, int offset, int length) async* {
            yield Uint8List.fromList([1, 2, 3]);
            partialWritten.complete();
            await channelClosed.future;
            throw const GrpcError.cancelled('transport closed');
          }

          final worker = runner(
            clientFactory: (peer) => _ScriptClient(
              peer,
              read,
              onClose: () {
                if (!channelClosed.isCompleted) channelClosed.complete();
              },
            ),
          );
          final running = worker.run(
            task.id,
            cancellation: cancellation,
            isUserCancelled: () => manuallyCancelled,
          );
          await partialWritten.future.timeout(const Duration(seconds: 3));
          if (manuallyCancelled) await store.cancel(task.id);
          cancellation.cancel();
          await running.timeout(const Duration(seconds: 3));
          final stopped = (await store.get(task.id))!;
          expect(
            stopped.state,
            manuallyCancelled ? DownloadState.cancelled : DownloadState.queued,
          );
          expect(stopped.error, isNull);
          expect(bridge.saves, 0);
          expect(
            await File(p.join(staging.path, task.id, '0.part')).readAsBytes(),
            [1, 2, 3],
          );
          if (!manuallyCancelled) expect(stopped.received, 3);
        },
      );
    }

    test(
      'an export permission failure retains completed bytes for export retry',
      () async {
        final item = _item(size: 4);
        final bytes = Uint8List.fromList([8, 6, 7, 5]);
        final task = await store.enqueue(_peer, item, 'content://receive');
        var readCalls = 0;
        Stream<Uint8List> read(String id, int offset, int length) async* {
          readCalls++;
          yield Uint8List.sublistView(bytes, offset, offset + length);
        }

        final worker = runner(
          clientFactory: (peer) => _ScriptClient(peer, read),
        );
        bridge.fail = true;
        await worker.run(task.id);
        expect((await store.get(task.id))!.state, DownloadState.failed);
        expect((await store.get(task.id))!.error, contains('权限'));
        expect(
          await File(p.join(staging.path, task.id, '0.part')).readAsBytes(),
          bytes,
        );
        expect(
          await File(
            p.join(staging.path, task.id, 'complete.partial'),
          ).exists(),
          isFalse,
        );
        expect(await repository.getDownload(_peer.id, item.id), isNull);
        bridge.fail = false;
        await store.enqueue(_peer, item, 'content://replacement');
        await runner(
          clientFactory: (_) => throw StateError('The source is offline'),
        ).run(task.id);
        expect(
          readCalls,
          1,
          reason:
              'A successful byte transfer need not be repeated to retry export',
        );
        expect(bridge.destination, 'content://replacement');
        expect((await store.get(task.id))!.state, DownloadState.completed);
      },
    );

    for (final example in [
      (
        'shared volume counts remaining staging and destination together',
        const TransferSpaceInfo(
          stagingAvailableBytes: transferSpaceReserve + 15,
          destinationAvailableBytes: transferSpaceReserve + 15,
          sameVolume: true,
        ),
      ),
      (
        'separate staging volume has insufficient space',
        const TransferSpaceInfo(
          stagingAvailableBytes: transferSpaceReserve + 9,
          destinationAvailableBytes: transferSpaceReserve + 100,
          sameVolume: false,
        ),
      ),
      (
        'separate destination volume has insufficient space',
        const TransferSpaceInfo(
          stagingAvailableBytes: transferSpaceReserve + 100,
          destinationAvailableBytes: transferSpaceReserve + 9,
          sameVolume: false,
        ),
      ),
    ]) {
      test(example.$1, () async {
        bridge.space = example.$2;
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        var connections = 0;
        await runner(
          clientFactory: (_) {
            connections++;
            throw StateError('Preflight must happen before connecting');
          },
        ).run(task.id);
        expect(connections, 0);
        expect(bridge.saves, 0);
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.error, contains('空间不足'));
      });
    }

    test(
      'capacity uses durable partial bytes rather than database progress',
      () async {
        final item = _item(size: 10);
        final task = await store.enqueue(_peer, item, 'content://receive');
        final cancellation = DownloadCancellation();
        await expectLater(
          MediaDownloader(
            clientFactory: (peer) => _ScriptClient(peer, (_, _, _) async* {
              yield Uint8List.fromList([1, 2, 3, 4]);
            }),
          ).downloadResumable(
            peer: _peer,
            item: item,
            directory: staging,
            taskId: task.id,
            cancellation: cancellation,
            onProgress: (received, _) {
              if (received == 4) cancellation.cancel();
            },
          ),
          throwsA(isA<DownloadCancelled>()),
        );
        // SQLite still says zero. Only six staging bytes plus ten target bytes
        // remain, so the shared volume has exactly enough capacity.
        bridge.space = const TransferSpaceInfo(
          stagingAvailableBytes: transferSpaceReserve + 16,
          destinationAvailableBytes: transferSpaceReserve + 16,
          sameVolume: true,
        );
        final offsets = <int>[];
        await runner(
          clientFactory: (peer) =>
              _ScriptClient(peer, (_, offset, length) async* {
                offsets.add(offset);
                yield Uint8List(length);
              }),
        ).run(task.id);
        expect(offsets, [4]);
        expect((await store.get(task.id))!.state, DownloadState.completed);
        expect(bridge.spaceChecks, ['content://receive', 'content://receive']);
      },
    );

    test(
      'destination capacity is checked again before export and parts survive',
      () async {
        final item = _item(size: 10);
        final task = await store.enqueue(_peer, item, 'content://receive');
        await runner(
          clientFactory: (peer) => _ScriptClient(peer, (_, _, length) async* {
            bridge.space = const TransferSpaceInfo(
              destinationAvailableBytes: transferSpaceReserve + 9,
            );
            yield Uint8List(length);
          }),
        ).run(task.id);
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.error, contains('空间不足'));
        expect(bridge.saves, 0);
        expect(
          await File(p.join(staging.path, task.id, '0.part')).length(),
          10,
        );
        bridge.space = const TransferSpaceInfo();
        await store.enqueue(_peer, item, 'content://receive');
        await runner(
          clientFactory: (_) =>
              throw StateError('Export retry must remain offline'),
        ).run(task.id);
        expect((await store.get(task.id))!.state, DownloadState.completed);
      },
    );

    test(
      'notification failures cannot turn a successful transfer into a failed task',
      () async {
        final item = _item(size: 2);
        final task = await store.enqueue(_peer, item, 'content://receive');
        Stream<Uint8List> read(String id, int offset, int length) async* {
          yield Uint8List.fromList([4, 2]);
        }

        await runner(
          clientFactory: (peer) => _ScriptClient(peer, read),
          progress: (_, _, _) async =>
              throw PlatformException(code: 'NOTIFICATION'),
        ).run(task.id);
        expect((await store.get(task.id))!.state, DownloadState.completed);
        expect(await bridge.exported!.readAsBytes(), [4, 2]);
      },
    );

    test(
      'identity mismatch never reads or exports another device file',
      () async {
        final task = await store.enqueue(_peer, _item(), 'content://receive');
        var reads = 0;
        Stream<Uint8List> read(String id, int offset, int length) async* {
          reads++;
          yield Uint8List(10);
        }

        await runner(
          clientFactory: (peer) => _ScriptClient(
            peer,
            read,
            identityOverride: const Peer(
              id: 'another-device',
              name: 'other',
              host: '127.0.0.1',
              port: 1,
            ),
          ),
        ).run(task.id);
        expect((await store.get(task.id))!.state, DownloadState.failed);
        expect((await store.get(task.id))!.error, contains('另一台设备'));
        expect(reads, 0);
        expect(bridge.saves, 0);
      },
    );
  });
}
