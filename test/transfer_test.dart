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
  bool fail = false;
  String? savedName, destination;
  List<String>? savedDirectories;
  File? exported;
  Future<void> Function()? beforeSave;

  @override
  Future<String> saveDownload({
    required String sourcePath,
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
    await exports.create(recursive: true);
    exported = await File(sourcePath).copy(p.join(exports.path, name));
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
  }) => TransferRunner(
    store: store,
    repository: repository,
    bridge: bridge,
    directory: staging,
    clientFactory: clientFactory,
    progress: progress,
    retryDelay: Duration.zero,
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
        final bytes = Uint8List.fromList(
          List.generate(600321, (index) => index % 251),
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
      'network failures preserve flushed parts and manual retry resumes the exact offset',
      () async {
        final bytes = Uint8List.fromList(List.generate(10, (index) => index));
        final item = _item(size: bytes.length);
        final task = await store.enqueue(_peer, item, 'content://receive');
        var offline = true;
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
        );
        await worker.run(task.id);
        final failed = (await store.get(task.id))!;
        expect(failed.state, DownloadState.failed);
        expect(failed.received, 4);
        expect(offsets, [
          0,
          4,
          4,
        ], reason: 'Transient failures have three bounded attempts');
        final part = File(p.join(staging.path, task.id, '0.part'));
        expect(await part.readAsBytes(), orderedEquals(bytes.take(4)));
        expect(bridge.saves, 0);
        offline = false;
        final retry = await store.enqueue(_peer, item, 'content://receive');
        expect(retry.id, task.id);
        expect(retry.attempt, 2);
        await worker.run(task.id);
        expect(offsets.last, 4);
        expect((await store.get(task.id))!.state, DownloadState.completed);
        expect(await bridge.exported!.readAsBytes(), orderedEquals(bytes));
        expect(await part.exists(), isFalse);
      },
    );

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
          await File(
            p.join(staging.path, task.id, 'complete.partial'),
          ).readAsBytes(),
          bytes,
        );
        expect(await repository.getDownload(_peer.id, item.id), isNull);
        bridge.fail = false;
        await store.enqueue(_peer, item, 'content://replacement');
        await worker.run(task.id);
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
