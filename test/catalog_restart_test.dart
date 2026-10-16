import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/network/media_rpc.dart';

const _sourcePeer = Peer(
  id: 'persistent-source',
  name: 'Source album',
  host: '127.0.0.1',
  port: 0,
);
const _deadline = Duration(seconds: 5);

class _BlockedThumbnail {
  final requested = Completer<void>();
  final release = Completer<void>();

  void unblock() {
    if (!release.isCompleted) release.complete();
  }
}

class _RestartSource implements LocalMediaSource {
  List<String> ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
  final modified = <String, int>{};
  final requestedThumbnails = <String>[];
  final blocked = <String, _BlockedThumbnail>{};

  @override
  Future<List<MediaMetadata>> scan() async => ids
      .map(
        (id) => MediaMetadata(
          id: id,
          deviceId: _sourcePeer.id,
          name: '$id.jpg',
          mimeType: 'image/jpeg',
          size: 100,
          modifiedMs: modified[id] ?? 1,
          sharedFolderId: 'camera',
          sharedFolderName: 'Camera',
          relativePath: '2026/$id.jpg',
        ),
      )
      .toList();

  @override
  Future<Uint8List> readThumbnail(String id) async {
    requestedThumbnails.add(id);
    final gate = blocked[id];
    if (gate != null) {
      if (!gate.requested.isCompleted) gate.requested.complete();
      await gate.release.future;
    }
    return Uint8List.fromList([id.codeUnitAt(0), modified[id] ?? 1]);
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List(length);
}

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late TamayuraRepository repository;
  late _RestartSource source;
  late MediaRpcServer server;
  late MediaRpcClient client;

  Future<TamayuraRepository> openRepository() => TamayuraRepository.open(
    path: '${directory.path}/catalog.db',
    factory: databaseFactoryFfi,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('catalog-restart-');
    repository = await openRepository();
    source = _RestartSource();
    server = MediaRpcServer(identity: _sourcePeer, source: source);
    await server.start();
    client = MediaRpcClient(_sourcePeer.copyWith(port: server.port));
  });

  tearDown(() async {
    for (final gate in source.blocked.values) {
      gate.unblock();
    }
    await client.close();
    await server.stop();
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<void> interruptAfterFirstThumbnail({int pageSize = 2}) async {
    final gate = source.blocked['b'] = _BlockedThumbnail();
    final firstReady = Completer<void>();
    final syncing = client.synchronize(
      repository,
      pageSize: pageSize,
      onProgress: (progress) {
        if (progress.readyCount == 1 && !firstReady.isCompleted) {
          firstReady.complete();
        }
      },
    );
    final interrupted = expectLater(syncing, throwsA(isA<GrpcError>()));
    try {
      await firstReady.future.timeout(_deadline);
      await gate.requested.future.timeout(_deadline);
      // Terminate the actual transport with a thumbnail response still pending.
      await client.close();
      await interrupted.timeout(_deadline);
    } finally {
      gate.unblock();
      source.blocked.remove('b');
    }
  }

  Future<void> reopenReceiver() async {
    await client.close();
    await repository.close();
    repository = await openRepository();
    client = MediaRpcClient(_sourcePeer.copyWith(port: server.port));
  }

  Future<void> restartSource() async {
    await client.close();
    await server.stop();
    server = MediaRpcServer(identity: _sourcePeer, source: source);
    await server.start();
    client = MediaRpcClient(_sourcePeer.copyWith(port: server.port));
  }

  test(
    'receiver reopens its file database and resumes a partly received page',
    () async {
      await interruptAfterFirstThumbnail();
      expect((await repository.listMedia()).map((item) => item.id), ['a']);
      expect(await repository.peerRevision(_sourcePeer.id), isNull);

      await reopenReceiver();
      expect((await repository.listMedia()).map((item) => item.id), ['a']);
      expect((await repository.mediaCollections()).single.itemCount, 1);
      expect((await repository.getMedia(_sourcePeer.id, 'a'))!.thumbnail, [
        'a'.codeUnitAt(0),
        1,
      ]);
      source.requestedThumbnails.clear();

      final resumed = await client.synchronize(repository, pageSize: 3);
      expect(resumed.thumbnailRequests, 6);
      expect(source.requestedThumbnails, unorderedEquals(source.ids.skip(1)));
      expect(await repository.countMedia(), 7);
      expect(await repository.peerRevision(_sourcePeer.id), server.revision);
    },
  );

  test(
    'both endpoints restart and reuse thumbnails saved before transport loss',
    () async {
      final revision = server.revision;
      await interruptAfterFirstThumbnail(pageSize: 1);
      await reopenReceiver();
      await restartSource();
      expect(server.revision, revision);
      expect((await repository.listMedia()).map((item) => item.id), ['a']);
      source.requestedThumbnails.clear();

      final resumed = await client.synchronize(repository, pageSize: 2);
      expect(resumed.thumbnailRequests, 6);
      expect(source.requestedThumbnails, unorderedEquals(source.ids.skip(1)));
      expect((await repository.listMedia()).map((item) => item.id).toSet(), {
        ...source.ids,
      });
      source.requestedThumbnails.clear();
      expect((await client.synchronize(repository)).thumbnailRequests, 0);
      expect(source.requestedThumbnails, isEmpty);
    },
  );

  test(
    'changed source after both restarts reuses matching partial cache and defers deletion',
    () async {
      source.ids = ['old'];
      await server.refresh();
      await client.synchronize(repository);
      final committedRevision = await repository.peerRevision(_sourcePeer.id);
      source.ids = ['a', 'b', 'c'];
      await server.refresh();
      await interruptAfterFirstThumbnail();
      await reopenReceiver();
      expect((await repository.listMedia()).map((item) => item.id).toSet(), {
        'a',
        'old',
      });
      expect(await repository.peerRevision(_sourcePeer.id), committedRevision);

      source.ids = ['a', 'b', 'd'];
      await restartSource();
      source.requestedThumbnails.clear();
      final gate = source.blocked['d'] = _BlockedThumbnail();
      final syncing = client.synchronize(repository, pageSize: 1);
      try {
        await gate.requested.future.timeout(_deadline);
        expect(await repository.getMedia(_sourcePeer.id, 'old'), isNotNull);
        expect(
          await repository.peerRevision(_sourcePeer.id),
          committedRevision,
        );
      } finally {
        gate.unblock();
      }
      final resumed = await syncing;
      expect(resumed.thumbnailRequests, 2);
      expect(source.requestedThumbnails, unorderedEquals(['b', 'd']));
      expect(await repository.getMedia(_sourcePeer.id, 'old'), isNull);
      expect(await repository.getMedia(_sourcePeer.id, 'c'), isNull);
      expect((await repository.listMedia()).map((item) => item.id).toSet(), {
        'a',
        'b',
        'd',
      });
    },
  );

  test(
    'restarted source with changed metadata replaces its partial thumbnail',
    () async {
      source.ids = ['a', 'b'];
      await server.refresh();
      await interruptAfterFirstThumbnail();
      await reopenReceiver();
      source.modified['a'] = 2;
      await restartSource();
      source.requestedThumbnails.clear();

      final resumed = await client.synchronize(repository, pageSize: 1);
      expect(resumed.thumbnailRequests, 2);
      expect(source.requestedThumbnails, unorderedEquals(['a', 'b']));
      final changed = await repository.getMedia(_sourcePeer.id, 'a');
      expect(changed!.modifiedMs, 2);
      expect(changed.thumbnail, ['a'.codeUnitAt(0), 2]);
    },
  );

  test(
    'expired response from an old owner cannot reclaim a newer synchronization',
    () async {
      source.ids = ['a', 'b', 'c'];
      await server.refresh();
      final oldGate = source.blocked['b'] = _BlockedThumbnail();
      final oldSync = client.synchronize(repository, pageSize: 1);
      final oldStopped = expectLater(
        oldSync,
        throwsA(isA<SnapshotConflictException>()),
      );
      await oldGate.requested.future.timeout(_deadline);

      source.ids.add('d');
      await server.refresh();
      final newGate = source.blocked['b'] = _BlockedThumbnail();
      final newClient = MediaRpcClient(_sourcePeer.copyWith(port: server.port));
      final newSync = newClient.synchronize(repository, pageSize: 1);
      // Observe an eventual error immediately even while waiting for oldSync.
      final newResult = newSync.then<Object>(
        (result) => result,
        onError: (Object error) => error,
      );
      try {
        await newGate.requested.future.timeout(_deadline);
        // The previous RPC now sees the expired revision. Its retry must first
        // notice that the stage belongs to the newer synchronization.
        oldGate.unblock();
        await oldStopped.timeout(_deadline);
        newGate.unblock();
        expect(await newResult.timeout(_deadline), isA<SyncResult>());
        expect(await repository.countMedia(), 4);
        expect(await repository.peerRevision(_sourcePeer.id), server.revision);
      } finally {
        oldGate.unblock();
        newGate.unblock();
        await newClient.close();
        await newResult.timeout(_deadline);
      }
    },
  );
}
