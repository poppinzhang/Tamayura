import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository, StubRpcClient;

const _peer = Peer(id: 'phone', name: 'Phone', host: '192.0.2.1', port: 50728);

MediaItem _photo(int index, {String folder = 'camera'}) => MediaItem(
  id: '$folder-$index',
  deviceId: _peer.id,
  name: '${index.isEven ? 'A' : 'z'}-${index.toString().padLeft(4, '0')}.jpg',
  mimeType: 'image/jpeg',
  size: 100,
  modifiedMs: 100000 + index,
  sharedFolderId: folder,
  sharedFolderName: folder,
  relativePath:
      '${index.isEven ? 'A' : 'z'}-${index.toString().padLeft(4, '0')}.jpg',
  thumbnail: Uint8List.fromList([index % 256]),
);

class _ScrollRepository extends GatedRepository {
  _ScrollRepository(super.inner);

  final windows = <List<String>>[];
  Future<void> Function(List<MediaScrollEntry>)? beforeWindow;
  Future<void> Function()? beforeIndex;

  @override
  Future<void> upsertPeer(Peer peer) => inner.upsertPeer(peer);

  @override
  Future<List<MediaScrollEntry>> listMediaScrollEntries({
    required String deviceId,
    required String sharedFolderId,
    MediaSortOrder sortOrder = MediaSortOrder.dateDescending,
  }) async {
    await beforeIndex?.call();
    return super.listMediaScrollEntries(
      deviceId: deviceId,
      sharedFolderId: sharedFolderId,
      sortOrder: sortOrder,
    );
  }

  @override
  Future<List<MediaItem>> readMediaScrollEntries(
    List<MediaScrollEntry> entries,
  ) async {
    windows.add(entries.map((entry) => entry.key).toList());
    await beforeWindow?.call(entries);
    return super.readMediaScrollEntries(entries);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('album scroll repository', () {
    late TamayuraRepository db;

    setUp(() async {
      db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await db.replacePeerSnapshot(_peer, [
        for (var index = 0; index < 121; index++) _photo(index),
        _photo(999, folder: 'other'),
      ]);
    });
    tearDown(() => db.close());

    for (final order in MediaSortOrder.values) {
      test(
        '$order index matches paginated order across the whole album',
        () async {
          final entries = await db.listMediaScrollEntries(
            deviceId: _peer.id,
            sharedFolderId: 'camera',
            sortOrder: order,
          );
          final expected = await db.listMediaPage(
            deviceId: _peer.id,
            sharedFolderId: 'camera',
            sortOrder: order,
            limit: 200,
          );
          expect(
            entries.map((entry) => entry.key),
            expected.items.map((item) => item.key),
          );
          expect(entries, hasLength(121));
          expect(entries.first.name, expected.items.first.name);
          expect(
            entries.first.modified.millisecondsSinceEpoch,
            expected.items.first.modifiedMs,
          );
          final window = [entries[120], entries[64], entries[10]];
          final items = await db.readMediaScrollEntries(window);
          expect(
            items.map((item) => item.key),
            window.map((entry) => entry.key),
          );
          expect(items.every((item) => item.thumbnail.length == 1), isTrue);
        },
      );
    }

    test(
      'index includes only ready staged items and uses stable requested identities',
      () async {
        final oldIndex = await db.listMediaScrollEntries(
          deviceId: _peer.id,
          sharedFolderId: 'camera',
        );
        final session = await db.beginPeerSnapshot(_peer, 'new', 2);
        final ready = _photo(500);
        final pending = _photo(501);
        await db.stageMediaPage(session, [ready, pending]);
        await db.saveStagedThumbnail(session, ready.id, ready.thumbnail);
        final entries = await db.listMediaScrollEntries(
          deviceId: _peer.id,
          sharedFolderId: 'camera',
        );
        expect(entries.first.key, ready.key);
        expect(entries.any((entry) => entry.key == pending.key), isFalse);
        final oldWindow = oldIndex.sublist(70, 80);
        expect(
          (await db.readMediaScrollEntries(oldWindow)).map((item) => item.key),
          oldWindow.map((entry) => entry.key),
        );
        await db.replacePeerSnapshot(_peer, [_photo(0)]);
        expect(await db.readMediaScrollEntries(oldWindow), isEmpty);
      },
    );

    test('empty and bounded window requests are validated', () async {
      expect(await db.readMediaScrollEntries([]), isEmpty);
      final entries = await db.listMediaScrollEntries(
        deviceId: _peer.id,
        sharedFolderId: 'missing',
      );
      expect(entries, isEmpty);
      final one = (await db.listMediaScrollEntries(
        deviceId: _peer.id,
        sharedFolderId: 'camera',
      )).first;
      await expectLater(
        db.readMediaScrollEntries(List.filled(201, one)),
        throwsArgumentError,
      );
    });
  });

  group('album scroll controller', () {
    late TamayuraRepository db;
    late _ScrollRepository repository;
    late AppController model;
    late FakeBridge bridge;
    late Directory temporary;

    setUp(() async {
      db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await db.replacePeerSnapshot(_peer, [
        for (var index = 0; index < 600; index++) _photo(index),
        for (var index = 0; index < 5; index++) _photo(index, folder: 'other'),
      ]);
      repository = _ScrollRepository(db);
      bridge = FakeBridge();
      temporary = await Directory.systemTemp.createTemp(
        'tamayura-album-scroll-',
      );
      final tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => tasks,
        clientFactory: (peer) => StubRpcClient(
          peer,
          onIdentity: () async =>
              throw const SocketException('offline cached device'),
        ),
      );
      model.setForeground(false);
      await model.initialize();
      await model.selectCollection('${_peer.id}/camera');
    });

    tearDown(() async {
      await model.shutdown();
      await bridge.events.close();
      await temporary.delete(recursive: true);
    });

    test(
      'jumping near the end reads only that window and leaves pagination unchanged',
      () async {
        expect(model.mediaScrollEntries, hasLength(600));
        expect(model.media, hasLength(60));
        expect(model.mediaAtScrollIndex(550), isNull);
        await model.ensureMediaScrollRange(540, 570);
        expect(repository.windows.single, hasLength(31));
        expect(
          model.mediaAtScrollIndex(550)?.key,
          model.mediaScrollEntries[550].key,
        );
        expect(model.mediaAtScrollIndex(100), isNull);
        expect(model.media, hasLength(60));
        expect(model.hasMoreMedia, isTrue);
        await model.ensureMediaScrollRange(545, 565);
        expect(repository.windows, hasLength(1));
        expect(model.mediaAtScrollIndex(-1), isNull);
        expect(model.mediaAtScrollIndex(600), isNull);
      },
    );

    test(
      'visited thumbnails are bounded and evicted windows can be reloaded',
      () async {
        for (final start in [100, 200, 300, 400]) {
          await model.ensureMediaScrollRange(start, start + 99);
        }
        final cached = List.generate(
          600,
          model.mediaAtScrollIndex,
        ).whereType<Object>().length;
        expect(cached, lessThanOrEqualTo(300));
        expect(model.mediaAtScrollIndex(100), isNull);
        expect(model.mediaAtScrollIndex(499), isNotNull);
        await model.ensureMediaScrollRange(100, 110);
        expect(model.mediaAtScrollIndex(100), isNotNull);
        expect(model.media, hasLength(60));
      },
    );

    test(
      'dragging coalesces intermediate requests into the newest range',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        repository.beforeWindow = (_) async {
          if (!started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        final first = model.ensureMediaScrollRange(100, 110);
        await started.future;
        final middle = model.ensureMediaScrollRange(200, 210);
        final latest = model.ensureMediaScrollRange(500, 510);
        release.complete();
        await Future.wait([first, middle, latest]);
        expect(repository.windows, hasLength(2));
        expect(
          repository.windows.last.first,
          model.mediaScrollEntries[500].key,
        );
        expect(model.mediaAtScrollIndex(100), isNull);
        expect(model.mediaAtScrollIndex(200), isNull);
        expect(model.mediaAtScrollIndex(500), isNotNull);
      },
    );

    test(
      'returning to an already cached range invalidates an old drag request',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        repository.beforeWindow = (_) async {
          started.complete();
          await release.future;
        };
        final first = model.ensureMediaScrollRange(300, 310);
        await started.future;
        final cached = model.ensureMediaScrollRange(0, 20);
        release.complete();
        await Future.wait([first, cached]);
        expect(model.mediaAtScrollIndex(300), isNull);
        expect(model.mediaAtScrollIndex(0), isNotNull);
      },
    );

    test(
      'failed windows can be retried and successful retry clears its error',
      () async {
        repository.beforeWindow = (_) async =>
            throw StateError('window failed');
        await model.ensureMediaScrollRange(300, 310);
        expect(model.error, isNotNull);
        expect(model.mediaAtScrollIndex(300), isNull);
        repository.beforeWindow = null;
        await model.ensureMediaScrollRange(300, 310);
        expect(model.error, isNull);
        expect(model.mediaAtScrollIndex(300), isNotNull);
        expect(repository.windows, hasLength(2));
      },
    );

    for (final changeCollection in [false, true]) {
      test(
        'an old failed window cannot affect a new ${changeCollection ? 'collection' : 'sort'}',
        () async {
          final started = Completer<void>();
          final release = Completer<void>();
          repository.beforeWindow = (_) async {
            started.complete();
            await release.future;
            throw StateError('obsolete request');
          };
          final old = model.ensureMediaScrollRange(300, 310);
          await started.future;
          if (changeCollection) {
            await model.selectCollection('${_peer.id}/other');
          } else {
            await model.setMediaSortOrder(MediaSortOrder.nameAscending);
          }
          release.complete();
          await old;
          expect(model.error, isNull);
          expect(
            model.mediaAtScrollIndex(0)?.key,
            model.mediaScrollEntries.first.key,
          );
          expect(model.mediaScrollEntries.length, changeCollection ? 5 : 600);
          if (!changeCollection) {
            repository.beforeWindow = null;
            await model.ensureMediaScrollRange(300, 310);
            expect(
              model.mediaAtScrollIndex(300)?.key,
              model.mediaScrollEntries[300].key,
            );
          }
        },
      );
    }

    test(
      'failed index sorting keeps the previous index and window usable',
      () async {
        final previous = model.mediaScrollEntries;
        repository.beforeIndex = () async => throw StateError('index failed');
        await model.setMediaSortOrder(MediaSortOrder.nameAscending);
        expect(identical(model.mediaScrollEntries, previous), isTrue);
        expect(model.mediaSortOrder, MediaSortOrder.dateDescending);
        await model.ensureMediaScrollRange(400, 420);
        expect(model.mediaAtScrollIndex(400)?.key, previous[400].key);
        repository.beforeIndex = null;
        await model.setMediaSortOrder(MediaSortOrder.nameAscending);
        expect(model.mediaSortOrder, MediaSortOrder.nameAscending);
        expect(identical(model.mediaScrollEntries, previous), isFalse);
      },
    );

    test(
      'catalog refresh retains cached thumbnails by identity after positions shift',
      () async {
        await model.ensureMediaScrollRange(300, 310);
        final oldIndex = model.mediaScrollEntries;
        final cachedKey = oldIndex[305].key;
        await db.replacePeerSnapshot(_peer, [
          for (var index = 1; index <= 600; index++) _photo(index),
        ]);
        await model.setForeground(true);
        await model.refresh();
        expect(identical(model.mediaScrollEntries, oldIndex), isFalse);
        final newPosition = model.mediaScrollEntries.indexWhere(
          (entry) => entry.key == cachedKey,
        );
        expect(newPosition, 306);
        expect(model.mediaAtScrollIndex(newPosition)?.key, cachedKey);
        expect(model.mediaScrollEntries.last.id, 'camera-1');
        expect(model.media, hasLength(60));
      },
    );

    test(
      'catalog refresh rejects a pending window from the previous index',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        repository.beforeWindow = (_) async {
          started.complete();
          await release.future;
        };
        final old = model.ensureMediaScrollRange(300, 310);
        await started.future;
        await db.replacePeerSnapshot(_peer, [
          for (var index = 1; index <= 600; index++) _photo(index),
        ]);
        await model.setForeground(true);
        await model.refresh();
        release.complete();
        await old;
        expect(model.mediaAtScrollIndex(300), isNull);
        repository.beforeWindow = null;
        await model.ensureMediaScrollRange(300, 310);
        expect(
          model.mediaAtScrollIndex(300)?.key,
          model.mediaScrollEntries[300].key,
        );
      },
    );

    test(
      'large visible ranges load every tile in bounded database batches',
      () async {
        for (final range in [(-1, -1), (600, 601), (10, 9)]) {
          await model.ensureMediaScrollRange(range.$1, range.$2);
        }
        expect(repository.windows, isEmpty);
        await model.ensureMediaScrollRange(100, 500);
        expect(repository.windows.map((window) => window.length), [
          200,
          200,
          1,
        ]);
        expect(
          List.generate(401, (index) => model.mediaAtScrollIndex(100 + index)),
          everyElement(isNotNull),
        );
        expect(
          List.generate(
            600,
            model.mediaAtScrollIndex,
          ).whereType<Object>().length,
          lessThanOrEqualTo(461),
        );
        // A smaller already-cached viewport also restores the normal budget.
        await model.ensureMediaScrollRange(300, 310);
        expect(repository.windows, hasLength(3));
        expect(model.mediaAtScrollIndex(300), isNotNull);
        expect(
          List.generate(
            600,
            model.mediaAtScrollIndex,
          ).whereType<Object>().length,
          lessThanOrEqualTo(300),
        );
        await model.selectCollection(null);
        expect(model.mediaScrollEntries, isEmpty);
        await model.ensureMediaScrollRange(0, 10);
        expect(repository.windows, hasLength(3));
      },
    );

    test(
      'superseding a large window skips its remaining database batches',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        repository.beforeWindow = (_) async {
          if (!started.isCompleted) {
            started.complete();
            await release.future;
          }
        };
        final large = model.ensureMediaScrollRange(100, 500);
        await started.future;
        final latest = model.ensureMediaScrollRange(550, 560);
        release.complete();
        await Future.wait([large, latest]);
        expect(repository.windows.map((window) => window.length), [200, 11]);
        expect(model.mediaAtScrollIndex(100), isNull);
        expect(model.mediaAtScrollIndex(550), isNotNull);
      },
    );
  });
}
