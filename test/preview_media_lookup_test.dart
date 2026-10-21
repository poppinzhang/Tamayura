import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository;

const _peer = Peer(id: 'source', name: 'Source', host: '192.0.2.5', port: 4000);

MediaItem _photo(int index) => MediaItem(
  id: 'photo-$index',
  deviceId: _peer.id,
  name: 'photo-$index.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: 'photo-$index.jpg',
  mimeType: 'image/jpeg',
  size: 3,
  modifiedMs: index,
  thumbnail: Uint8List.fromList([index % 256]),
);

MediaView _view(MediaItem item) => MediaView(
  id: item.id,
  deviceId: item.deviceId,
  name: item.name,
  mimeType: item.mimeType,
  size: item.size,
  modified: DateTime.fromMillisecondsSinceEpoch(item.modifiedMs),
  thumbnail: item.thumbnail,
);

class _Gate {
  final entered = Completer<void>();
  final released = Completer<void>();

  Future<void> wait() async {
    entered.complete();
    await released.future;
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

class _LookupRepository extends GatedRepository {
  _LookupRepository(super.inner);

  _Gate? mediaGate, downloadGate;
  bool failMediaRead = false, failDownloadRead = false;

  @override
  Future<MediaItem?> getMedia(String deviceId, String id) async {
    if (failMediaRead) throw StateError('media unavailable');
    final item = await inner.getMedia(deviceId, id);
    final gate = mediaGate;
    mediaGate = null;
    await gate?.wait();
    return item;
  }

  @override
  Future<DownloadRecord?> getDownload(String deviceId, String mediaId) async {
    if (failDownloadRead) throw StateError('download history unavailable');
    final saved = await inner.getDownload(deviceId, mediaId);
    final gate = downloadGate;
    downloadGate = null;
    await gate?.wait();
    return saved;
  }

  @override
  Future<void> removeDownload(String deviceId, String mediaId) =>
      inner.removeDownload(deviceId, mediaId);
}

class _LookupBridge extends FakeBridge {
  _Gate? deleteGate;

  @override
  Future<void> deleteDownload(String uri) async => await deleteGate?.wait();
}

class _DefaultModel extends TamayuraModel {
  @override
  List<MediaView> media = [];
  @override
  Map<String, TransferView> transfers = {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'default lookup resolves album and download history identities',
    () async {
      final model = _DefaultModel();
      final album = _view(_photo(1));
      final saved = _view(_photo(2));
      model.media = [album];
      model.transfers = {
        saved.key: TransferView(
          progress: 1,
          savedUri: 'file:///saved',
          item: saved,
        ),
      };
      expect(
        await model.resolvePreviewMedia(album.deviceId, album.id),
        same(album),
      );
      expect(
        await model.resolvePreviewMedia(saved.deviceId, saved.id),
        same(saved),
      );
      expect(await model.resolvePreviewMedia('other', album.id), isNull);
      model.dispose();
    },
  );

  group('preview identity lookup', () {
    late Directory temporary;
    late TamayuraRepository db;
    late _LookupRepository repository;
    late TransferStore tasks;
    late _LookupBridge bridge;
    late AppController model;
    final gates = <_Gate>[];

    _Gate gate() {
      final value = _Gate();
      gates.add(value);
      return value;
    }

    Future<void> save(MediaItem item) => db.saveDownload(
      DownloadRecord(
        deviceId: item.deviceId,
        mediaId: item.id,
        uri: 'file:///saved/${item.name}',
        completedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp(
        'tamayura-preview-lookup-',
      );
      db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      repository = _LookupRepository(db);
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      await db.replacePeerSnapshot(_peer, [
        for (var index = 0; index < 130; index++) _photo(index),
      ]);
      await db.setSetting('downloadUri', temporary.uri.toString());
      await save(_photo(0));
      bridge = _LookupBridge();
      model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => tasks,
      );
      await model.setForeground(false);
      await model.initialize();
      await model.selectCollection('${_peer.id}/camera');
      expect(model.error, isNull);
    });

    tearDown(() async {
      for (final value in gates) {
        value.release();
      }
      gates.clear();
      await model.shutdown();
      await bridge.events.close();
      await temporary.delete(recursive: true);
    });

    test(
      'unloaded saved media restores its local state without changing album',
      () async {
        final visible = model.media.map((item) => item.key).toList();
        final entries = model.mediaScrollEntries;
        final collection = model.selectedCollectionKey;
        final sort = model.mediaSortOrder;
        expect(model.mediaAtScrollIndex(129), isNull);
        expect(model.transfers[_photo(0).key], isNull);

        final resolved = await model.resolvePreviewMedia(_peer.id, 'photo-0');

        expect(resolved?.key, _photo(0).key);
        expect(resolved?.thumbnail, [0]);
        expect(
          model.transfers[resolved!.key]?.savedUri,
          'file:///saved/photo-0.jpg',
        );
        expect(model.transfers[resolved.key]?.complete, isTrue);
        expect(model.media.map((item) => item.key), visible);
        expect(model.mediaScrollEntries, same(entries));
        expect(model.mediaAtScrollIndex(129), isNull);
        expect(model.selectedCollectionKey, collection);
        expect(model.mediaSortOrder, sort);
        expect(model.totalMediaCount, 130);
        expect(model.hasMoreMedia, isTrue);

        await model.download(resolved);
        expect(bridge.scheduled, isEmpty);
        expect(await tasks.forMedia(_peer.id, resolved.id), isNull);
      },
    );

    test(
      'visiting uncached identities does not retain their thumbnails',
      () async {
        for (var index = 1; index < 70; index++) {
          expect(
            (await model.resolvePreviewMedia(_peer.id, 'photo-$index'))?.id,
            'photo-$index',
          );
        }
        expect(model.media, hasLength(60));
        expect(model.transfers, isEmpty);
        expect(model.mediaAtScrollIndex(100), isNull);
        expect(model.mediaAtScrollIndex(129), isNull);
      },
    );

    test('missing catalog media can resolve saved transfer history', () async {
      final item = _photo(200);
      final task = await tasks.enqueue(_peer, item, temporary.uri.toString());
      await tasks.update(task.id, {
        'state': 'completed',
        'saved_uri': 'file:///saved/history.jpg',
        'received': item.size,
      });
      final resolved = await model.resolvePreviewMedia(item.deviceId, item.id);
      expect(resolved?.name, item.name);
      expect(model.transfers[item.key]?.savedUri, 'file:///saved/history.jpg');
      expect(model.media.any((entry) => entry.key == item.key), isFalse);
      expect(model.error, isNull);
    });

    test('missing media returns null and errors remain retryable', () async {
      expect(await model.resolvePreviewMedia(_peer.id, 'missing'), isNull);
      repository.failMediaRead = true;
      expect(await model.resolvePreviewMedia(_peer.id, 'photo-0'), isNull);
      expect(model.error, isNotNull);
      repository.failMediaRead = false;
      model.clearError();
      repository.failDownloadRead = true;
      expect(await model.resolvePreviewMedia(_peer.id, 'photo-0'), isNull);
      expect(model.error, isNotNull);
      repository.failDownloadRead = false;
      model.clearError();
      expect(await model.resolvePreviewMedia(_peer.id, 'photo-0'), isNotNull);
      expect(model.error, isNull);
    });

    test(
      'completed deletion cannot be undone by a stale saved-file lookup',
      () async {
        final paused = gate();
        repository.downloadGate = paused;
        final pending = model.resolvePreviewMedia(_peer.id, 'photo-0');
        await paused.entered.future;
        expect(await model.deleteLocalFile(_view(_photo(0))), isTrue);
        paused.release();
        expect(await pending, isNotNull);
        expect(model.transfers[_photo(0).key], isNull);
        expect(await db.getDownload(_peer.id, 'photo-0'), isNull);
      },
    );

    test(
      'lookup during local deletion does not restore a saved state',
      () async {
        final paused = gate();
        bridge.deleteGate = paused;
        final deleting = model.deleteLocalFile(_view(_photo(0)));
        await paused.entered.future;
        expect(await model.resolvePreviewMedia(_peer.id, 'photo-0'), isNull);
        paused.release();
        expect(await deleting, isTrue);
        expect(model.transfers[_photo(0).key], isNull);
      },
    );

    test(
      'shutdown discards in-flight reads and prevents further lookup',
      () async {
        final paused = gate();
        repository.mediaGate = paused;
        final pending = model.resolvePreviewMedia(_peer.id, 'photo-0');
        await paused.entered.future;
        await model.shutdown();
        paused.release();
        expect(await pending, isNull);
        expect(await model.resolvePreviewMedia(_peer.id, 'photo-0'), isNull);
        expect(model.transfers[_photo(0).key], isNull);
        expect(model.error, isNull);
      },
    );
  });
}
