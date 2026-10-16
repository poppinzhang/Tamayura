import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/network/generated/media.pbgrpc.dart' as wire;

const identity = Peer(
  id: 'source-phone',
  name: 'Source phone',
  host: '127.0.0.1',
  port: 0,
);

class MemorySource implements LocalMediaSource {
  Uint8List bytes = Uint8List.fromList(
    List.generate(mediaChunkSize + 20, (index) => index % 251),
  );
  bool failScan = false;
  bool shortRead = false;
  bool empty = false;
  final List<String> requestedIds = [];
  List<String> ids = ['safe-id'];
  final List<String> thumbnailRequests = [];
  Future<void> Function(String)? beforeThumbnail;
  Future<void> Function(int)? beforeRead;
  bool oversizedThumbnail = false;
  String sharedFolderName = 'Camera';
  String pathPrefix = '2026/Trip';

  @override
  Future<List<MediaMetadata>> scan() async {
    if (failScan) throw const FileSystemException('Access revoked');
    if (empty) return [];
    return ids
        .map(
          (id) => MediaMetadata(
            id: id,
            deviceId: identity.id,
            name: '$id.jpg',
            sharedFolderId: 'camera',
            sharedFolderName: sharedFolderName,
            relativePath: '$pathPrefix/$id.jpg',
            mimeType: 'image/jpeg',
            size: bytes.length,
            modifiedMs: 123,
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> readThumbnail(String id) async {
    thumbnailRequests.add(id);
    await beforeThumbnail?.call(id);
    return oversizedThumbnail
        ? Uint8List(maxThumbnailBytes + 1)
        : Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    requestedIds.add(id);
    await beforeRead?.call(offset);
    if (shortRead) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

class RecordingCatalogClient extends MediaRpcClient {
  RecordingCatalogClient(super.peer);
  final pageTokens = <String?>[];

  @override
  Future<CatalogPage> listMediaPage({
    String? revision,
    String? pageToken,
    int pageSize = 200,
    String? knownRevision,
  }) {
    pageTokens.add(pageToken);
    return super.listMediaPage(
      revision: revision,
      pageToken: pageToken,
      pageSize: pageSize,
      knownRevision: knownRevision,
    );
  }
}

Matcher grpcCode(int code) =>
    isA<GrpcError>().having((error) => error.code, 'code', code);

void main() {
  sqfliteFfiInit();
  group('real localhost protobuf gRPC server and client', () {
    late MemorySource source;
    late MediaRpcServer server;
    late MediaRpcClient client;
    late TamayuraRepository repository;

    setUp(() async {
      repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      source = MemorySource();
      server = MediaRpcServer(identity: identity, source: source);
      await server.start();
      client = MediaRpcClient(identity.copyWith(port: server.port));
    });
    tearDown(() async {
      await client.close();
      await server.stop();
      await repository.close();
    });

    test(
      'metadata pagination supports more than 2000 items without generating thumbnails',
      () async {
        source.ids = List.generate(
          2507,
          (index) => 'photo-${index.toString().padLeft(5, '0')}',
        );
        await server.refresh();
        var page = await client.listMediaPage(pageSize: 500);
        final revision = page.revision;
        final ids = <String>[];
        while (true) {
          expect(page.items.length, lessThanOrEqualTo(500));
          expect(page.totalCount, 2507);
          expect(page.items.any((item) => item is MediaItem), false);
          ids.addAll(page.items.map((item) => item.id));
          if (page.nextPageToken == null) break;
          page = await client.listMediaPage(
            revision: revision,
            pageToken: page.nextPageToken,
            pageSize: 500,
          );
        }
        expect(ids, source.ids);
        expect(source.thumbnailRequests, isEmpty);
        await expectLater(
          client.listMediaPage(pageSize: 501),
          throwsArgumentError,
        );
      },
    );

    test(
      'sync progress exposes each ready thumbnail before its page is complete',
      () async {
        source.ids = ['a', 'b', 'c'];
        await server.refresh();
        final waiting = Completer<void>();
        final firstReady = Completer<void>();
        final progress = <SyncProgress>[];
        Future<String?>? completedRevision;
        source.beforeThumbnail = (id) async {
          if (id == 'b') await waiting.future;
        };
        final sync = client.synchronize(
          repository,
          pageSize: 2,
          onProgress: (event) {
            progress.add(event);
            if (event.readyCount == 1 && !firstReady.isCompleted) {
              firstReady.complete();
            }
            if (event.phase == SyncPhase.completed) {
              completedRevision = repository.peerRevision(identity.id);
            }
          },
        );
        try {
          await firstReady.future.timeout(const Duration(seconds: 5));
          expect((await repository.listMediaPage()).items.single.id, 'a');
          expect((await repository.mediaCollections()).single.itemCount, 1);
          expect(await repository.peerRevision(identity.id), isNull);
          expect(progress.first.phase, SyncPhase.connecting);
          expect(progress.first.totalCount, isNull);
          expect(progress.last.receivedCount, 2);
          expect(progress.last.readyCount, 1);
          expect(progress.last.totalCount, 3);
        } finally {
          waiting.complete();
        }
        await sync;
        expect(progress.every((event) => event.peerId == identity.id), true);
        expect(
          progress.every((event) => event.peerName == identity.name),
          true,
        );
        expect(progress.map((event) => event.readyCount), [
          0,
          0,
          1,
          2,
          2,
          3,
          3,
          3,
        ]);
        expect(progress[progress.length - 2].phase, SyncPhase.committing);
        expect(progress.last.phase, SyncPhase.completed);
        expect(progress.last.receivedCount, 3);
        expect(await completedRevision, server.revision);
      },
    );

    test(
      'incremental failure preserves ready previews and the previous library',
      () async {
        await client.synchronize(repository);
        final oldRevision = await repository.peerRevision(identity.id);
        source.ids = ['a', 'z'];
        await server.refresh();
        final waiting = Completer<void>();
        final firstReady = Completer<void>();
        final progress = <SyncProgress>[];
        source.beforeThumbnail = (id) async {
          if (id == 'z') {
            await waiting.future;
            throw const FileSystemException('Thumbnail is unavailable');
          }
        };
        final sync = client.synchronize(
          repository,
          pageSize: 1,
          onProgress: (event) {
            progress.add(event);
            if (event.readyCount == 1 && !firstReady.isCompleted) {
              firstReady.complete();
            }
          },
        );
        final fails = expectLater(sync, throwsA(isA<GrpcError>()));
        try {
          await firstReady.future.timeout(const Duration(seconds: 5));
          expect(
            (await repository.listMedia()).map((item) => item.id).toSet(),
            {'safe-id', 'a'},
          );
          expect(await repository.peerRevision(identity.id), oldRevision);
        } finally {
          waiting.complete();
        }
        await fails;
        expect((await repository.listMedia()).map((item) => item.id).toSet(), {
          'safe-id',
          'a',
        });
        expect(await repository.peerRevision(identity.id), oldRevision);
        expect(
          progress.any((event) => event.phase == SyncPhase.completed),
          false,
        );
      },
    );

    test(
      'resume finishes missing thumbnails then requests the saved next page',
      () async {
        source.ids = ['a', 'b', 'c', 'd', 'e', 'f'];
        await server.refresh();
        await client.close();
        final recording = RecordingCatalogClient(
          identity.copyWith(port: server.port),
        );
        client = recording;
        source.beforeThumbnail = (id) async {
          if (id == 'c') throw const FileSystemException('Interrupted');
        };
        await expectLater(
          client.synchronize(repository, pageSize: 2),
          throwsA(isA<GrpcError>()),
        );
        final paused = (await repository.findPeerSnapshot(identity))!;
        expect(paused.receivedCount, 4);
        expect(paused.readyCount, 3);
        expect(paused.nextPageToken, '${server.revision}:4');
        expect(recording.pageTokens, [null, '${server.revision}:2']);
        recording.pageTokens.clear();
        source.thumbnailRequests.clear();
        source.beforeThumbnail = null;
        final events = <SyncProgress>[];
        final result = await client.synchronize(
          repository,
          pageSize: 1,
          onProgress: events.add,
        );
        expect(result.thumbnailRequests, 3);
        expect(source.thumbnailRequests, ['c', 'e', 'f']);
        expect(recording.pageTokens, [
          null,
          '${server.revision}:4',
          '${server.revision}:5',
        ]);
        expect(events.first.readyCount, 3);
        expect(events.first.receivedCount, 4);
        expect(await repository.countMedia(), 6);
        expect(await repository.findPeerSnapshot(identity), isNull);
      },
    );

    test(
      'progress accounts for cached thumbnails, unchanged catalogs and empty catalogs',
      () async {
        final events = <SyncProgress>[];
        await client.synchronize(repository);
        await client.synchronize(repository, onProgress: events.add);
        expect(events.map((event) => event.phase), [
          SyncPhase.connecting,
          SyncPhase.completed,
        ]);
        expect(events.last.totalCount, 1);
        expect(events.last.receivedCount, 1);
        expect(events.last.readyCount, 1);
        source.ids.add('new');
        await server.refresh();
        events.clear();
        final incremental = await client.synchronize(
          repository,
          onProgress: events.add,
        );
        expect(incremental.thumbnailRequests, 1);
        final staged = events.firstWhere(
          (event) => event.phase == SyncPhase.receiving,
        );
        expect(staged.receivedCount, 2);
        expect(staged.readyCount, 1);
        expect(events.last.readyCount, 2);
        source.ids.clear();
        await server.refresh();
        events.clear();
        await client.synchronize(repository, onProgress: events.add);
        expect(events.last.phase, SyncPhase.completed);
        expect(events.last.totalCount, 0);
        expect(events.last.receivedCount, 0);
        expect(events.last.readyCount, 0);
        expect(await repository.countMedia(), 0);
      },
    );

    test(
      'large staged sync fetches new thumbnails once, then applies only additions and deletions',
      () async {
        source.ids = List.generate(
          2101,
          (index) => 'photo-${index.toString().padLeft(5, '0')}',
        );
        await server.refresh();
        final first = await client.synchronize(repository, pageSize: 100);
        expect(first.totalCount, 2101);
        expect(first.addedCount, 2101);
        expect(first.thumbnailRequests, 2101);
        expect(await repository.countMedia(), 2101);
        source.thumbnailRequests.clear();
        final unchangedRevision = server.revision;
        await server.refresh();
        expect(server.revision, unchangedRevision);
        final second = await client.synchronize(repository, pageSize: 100);
        expect(second.thumbnailRequests, 0);
        expect(source.thumbnailRequests, isEmpty);
        // A process restart retains the catalog revision and cached bytes.
        await server.stop();
        server = MediaRpcServer(identity: identity, source: source);
        await server.start();
        await client.close();
        client = MediaRpcClient(identity.copyWith(port: server.port));
        expect(server.revision, unchangedRevision);
        final restarted = await client.synchronize(repository, pageSize: 100);
        expect(restarted.thumbnailRequests, 0);
        expect(source.thumbnailRequests, isEmpty);
        source.ids.removeAt(0);
        source.ids.add('new-photo');
        await server.refresh();
        final delta = await client.synchronize(repository, pageSize: 100);
        expect(delta.addedCount, 1);
        expect(delta.deletedCount, 1);
        expect(delta.thumbnailRequests, 1);
        expect(source.thumbnailRequests, ['new-photo']);
        expect(await repository.getMedia(identity.id, 'photo-00000'), null);
        expect(
          (await repository.getMedia(identity.id, 'new-photo'))!.thumbnail,
          [1, 2, 3],
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'revision changes reject old page tokens and retry a staged sync atomically',
      () async {
        source.ids = ['a', 'b', 'c'];
        await server.refresh();
        final firstPage = await client.listMediaPage(pageSize: 1);
        source.ids.add('d');
        await server.refresh();
        await expectLater(
          client.listMediaPage(
            revision: firstPage.revision,
            pageToken: firstPage.nextPageToken,
            pageSize: 1,
          ),
          throwsA(grpcCode(StatusCode.aborted)),
        );
        var changed = false;
        source.beforeThumbnail = (id) async {
          if (id == 'b' && !changed) {
            changed = true;
            source.ids = ['e', 'f'];
            await server.refresh();
          }
        };
        final events = <SyncProgress>[];
        Future<int>? retryCount;
        final result = await client.synchronize(
          repository,
          pageSize: 1,
          onProgress: (event) {
            events.add(event);
            if (event.phase == SyncPhase.connecting && event.attempt == 1) {
              retryCount = repository.countMedia();
            }
          },
        );
        expect(await retryCount, 1);
        final firstAttempt = events
            .where((event) => event.attempt == 0)
            .toList();
        expect(firstAttempt.any((event) => event.readyCount == 1), true);
        expect(
          firstAttempt.any((event) => event.phase == SyncPhase.completed),
          false,
        );
        final retry = events.where((event) => event.attempt == 1).toList();
        expect(retry.first.phase, SyncPhase.connecting);
        expect(retry.first.readyCount, 1);
        expect(retry.first.receivedCount, 2);
        expect(retry.first.totalCount, 4);
        expect(retry.last.phase, SyncPhase.completed);
        expect(retry.last.readyCount, 2);
        expect(result.totalCount, 2);
        expect(
          (await repository.listMediaPage()).items.map((item) => item.id),
          ['e', 'f'],
        );
        expect(await repository.peerRevision(identity.id), server.revision);
      },
    );

    test(
      'thumbnail limits and scan failures leave the committed library intact',
      () async {
        await client.synchronize(repository);
        final originalRevision = await repository.peerRevision(identity.id);
        source.ids.add('too-big');
        source.oversizedThumbnail = true;
        await server.refresh();
        await expectLater(
          client.synchronize(repository),
          throwsA(grpcCode(StatusCode.resourceExhausted)),
        );
        expect(await repository.countMedia(), 1);
        expect(await repository.peerRevision(identity.id), originalRevision);
        source.failScan = true;
        await expectLater(
          server.refresh(),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          client.synchronize(repository),
          throwsA(grpcCode(StatusCode.failedPrecondition)),
        );
        expect(await repository.countMedia(), 1);
      },
    );

    test(
      'server limits concurrent thumbnail generation to four requests',
      () async {
        var active = 0;
        var peak = 0;
        source.beforeThumbnail = (_) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
        };
        final page = await client.listMediaPage();
        await Future.wait(
          List.generate(
            12,
            (_) => client.thumbnail('safe-id', revision: page.revision),
          ),
        );
        expect(peak, 4);
        expect(active, 0);
      },
    );

    test('identity and thumbnails round-trip through protobuf', () async {
      expect(server.port, greaterThan(0));
      final device = await client.identity();
      expect(device.id, identity.id);
      expect(device.name, identity.name);
      final item = (await client.listMedia()).single;
      expect(item.id, 'safe-id');
      expect(item.deviceId, identity.id);
      expect(item.size, source.bytes.length);
      expect(item.modifiedMs, 123);
      expect(item.thumbnail, [1, 2, 3]);
      expect(item.sharedFolderId, 'camera');
      expect(item.sharedFolderName, 'Camera');
      expect(item.relativePath, '2026/Trip/safe-id.jpg');
    });

    test(
      'folder renames and relative moves change revisions and offline metadata',
      () async {
        await client.synchronize(repository);
        final previous = server.revision;
        source.sharedFolderName = '旅行照片';
        source.pathPrefix = '2026/October/Trip';
        await server.refresh();
        expect(server.revision, isNot(previous));
        final sync = await client.synchronize(repository);
        expect(sync.thumbnailRequests, 1);
        final cached = (await repository.listMediaPage()).items.single;
        expect(cached.sharedFolderName, '旅行照片');
        expect(cached.relativePath, '2026/October/Trip/safe-id.jpg');
        expect(
          (await repository.mediaCollections()).single.sharedFolderName,
          '旅行照片',
        );
      },
    );

    test(
      'unsafe source paths revoke the catalog rather than exposing a partial scan',
      () async {
        await client.synchronize(repository);
        source.pathPrefix = '../private';
        await expectLater(server.refresh(), throwsFormatException);
        await expectLater(
          client.synchronize(repository),
          throwsA(grpcCode(StatusCode.failedPrecondition)),
        );
        expect(await repository.countMedia(), 1);
      },
    );

    test('full files and nonzero-offset ranges preserve every byte', () async {
      final full = await client
          .readRange('safe-id', 0, source.bytes.length)
          .toList();
      expect(full.length, 2);
      expect(full.expand((chunk) => chunk).toList(), source.bytes);
      final slice = await client.readRange('safe-id', 7, 321).toList();
      expect(
        slice.expand((chunk) => chunk).toList(),
        source.bytes.sublist(7, 328),
      );
      expect(
        await client.readRange('safe-id', source.bytes.length, 0).toList(),
        isEmpty,
      );
    });

    test(
      'stop interrupts an active download without waiting for the provider and can restart',
      () async {
        final reading = Completer<void>();
        final release = Completer<void>();
        source.beforeRead = (offset) async {
          if (offset == mediaChunkSize) {
            reading.complete();
            await release.future;
          }
        };
        final received = <Uint8List>[];
        final firstChunk = Completer<void>();
        final download = Completer<void>();
        final subscription = client
            .readRange('safe-id', 0, source.bytes.length)
            .listen(
              (chunk) {
                received.add(chunk);
                if (!firstChunk.isCompleted) firstChunk.complete();
              },
              onError: download.completeError,
              onDone: () {
                if (!download.isCompleted) download.complete();
              },
            );
        final interrupted = expectLater(
          download.future,
          throwsA(isA<GrpcError>()),
        );
        try {
          await reading.future.timeout(const Duration(seconds: 3));
          await firstChunk.future.timeout(const Duration(seconds: 3));
          await server.stop().timeout(const Duration(seconds: 3));
          await interrupted.timeout(const Duration(seconds: 3));
          expect(server.port, 0);
          expect(received, hasLength(1));
          expect(received.single.length, mediaChunkSize);
          expect(release.isCompleted, isFalse);

          // Resume on the same object while the old document read is blocked.
          await server.start().timeout(const Duration(seconds: 3));
          final restarted = MediaRpcClient(
            identity.copyWith(port: server.port),
          );
          try {
            expect((await restarted.identity()).id, identity.id);
            final slice = await restarted.readRange('safe-id', 0, 20).toList();
            expect(slice.single, source.bytes.sublist(0, 20));
          } finally {
            await restarted.close();
          }
          release.complete();
          await Future<void>.delayed(Duration.zero);
          expect(received, hasLength(1));
        } finally {
          if (!release.isCompleted) release.complete();
          await subscription.cancel();
        }
      },
    );

    test('stop does not wait for a paused download client', () async {
      source.bytes = Uint8List(mediaChunkSize * 40);
      await server.refresh();
      final firstChunk = Completer<void>();
      final completed = Completer<void>();
      late StreamSubscription<Uint8List> subscription;
      subscription = client
          .readRange('safe-id', 0, source.bytes.length)
          .listen(
            (_) {
              if (!firstChunk.isCompleted) {
                subscription.pause();
                firstChunk.complete();
              }
            },
            onError: completed.completeError,
            onDone: () {
              if (!completed.isCompleted) completed.complete();
            },
          );
      final interrupted = expectLater(
        completed.future,
        throwsA(isA<GrpcError>()),
      );
      try {
        await firstChunk.future.timeout(const Duration(seconds: 3));
        await server.stop().timeout(const Duration(seconds: 3));
        expect(server.port, 0);
        subscription.resume();
        await interrupted.timeout(const Duration(seconds: 3));
      } finally {
        subscription.resume();
        await client.close();
        await subscription.cancel();
      }
    });

    test('stop closes blocked and queued thumbnail RPCs immediately', () async {
      final reading = Completer<void>();
      final release = Completer<void>();
      var active = 0;
      source.beforeThumbnail = (_) async {
        if (++active == 4) reading.complete();
        await release.future;
      };
      final revision = (await client.listMediaPage()).revision;
      final requests = List.generate(
        8,
        (_) => expectLater(
          client.thumbnail('safe-id', revision: revision),
          throwsA(isA<GrpcError>()),
        ),
      );
      try {
        await reading.future.timeout(const Duration(seconds: 3));
        // Allow the other calls to queue behind the four active provider reads.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await server.stop().timeout(const Duration(seconds: 3));
        await Future.wait(requests).timeout(const Duration(seconds: 3));
        expect(source.thumbnailRequests, hasLength(4));
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(source.thumbnailRequests, hasLength(4));
      } finally {
        if (!release.isCompleted) release.complete();
      }
    });

    test('unshared paths never reach the local provider', () async {
      await expectLater(
        client.readRange('../../private.txt', 0, 1).toList(),
        throwsA(grpcCode(StatusCode.notFound)),
      );
      expect(source.requestedIds, isEmpty);
    });

    test('out-of-bounds and negative ranges are rejected', () async {
      await expectLater(
        client.readRange('safe-id', source.bytes.length, 1).toList(),
        throwsA(grpcCode(StatusCode.outOfRange)),
      );
      await expectLater(
        client.readRange('safe-id', -1, 1).toList(),
        throwsArgumentError,
      );
      expect(source.requestedIds, isEmpty);
    });

    test(
      'source truncation fails instead of claiming a complete file',
      () async {
        source.shortRead = true;
        await expectLater(
          client.readRange('safe-id', 0, 20).toList(),
          throwsA(grpcCode(StatusCode.dataLoss)),
        );
      },
    );

    test('successful refresh publishes deletions', () async {
      expect(await client.listMedia(), hasLength(1));
      source.empty = true;
      await server.refresh();
      expect(await client.listMedia(), isEmpty);
      await expectLater(
        client.readRange('safe-id', 0, 1).toList(),
        throwsA(grpcCode(StatusCode.notFound)),
      );
    });

    test(
      'revoked folder blocks snapshots and downloads until a successful scan',
      () async {
        source.failScan = true;
        await expectLater(
          server.refresh(),
          throwsA(isA<FileSystemException>()),
        );
        expect(server.scanError, isA<FileSystemException>());
        expect(server.localMedia, isEmpty);
        await expectLater(
          client.listMedia(),
          throwsA(grpcCode(StatusCode.failedPrecondition)),
        );
        await expectLater(
          client.readRange('safe-id', 0, 1).toList(),
          throwsA(grpcCode(StatusCode.notFound)),
        );
        source.failScan = false;
        await server.refresh();
        expect(server.scanError, isNull);
        expect(await client.listMedia(), hasLength(1));
      },
    );

    test(
      'startup with a revoked folder still permits identity and reception',
      () async {
        await server.stop();
        source.failScan = true;
        await server.start();
        final restarted = MediaRpcClient(identity.copyWith(port: server.port));
        try {
          expect(server.scanError, isA<FileSystemException>());
          expect((await restarted.identity()).id, identity.id);
          await expectLater(
            restarted.listMedia(),
            throwsA(grpcCode(StatusCode.failedPrecondition)),
          );
        } finally {
          await restarted.close();
        }
      },
    );

    test(
      'unknown device can be identified but reused addresses do not impersonate remembered peers',
      () async {
        final unknown = MediaRpcClient(
          Peer(id: '', name: '', host: '127.0.0.1', port: server.port),
        );
        final mismatch = MediaRpcClient(
          Peer(
            id: 'someone-else',
            name: '',
            host: '127.0.0.1',
            port: server.port,
          ),
        );
        try {
          expect((await unknown.identity()).id, identity.id);
          await expectLater(mismatch.identity(), throwsFormatException);
        } finally {
          await unknown.close();
          await mismatch.close();
        }
      },
    );
  });

  group('malformed and interrupted peer responses', () {
    late BrokenService service;
    late Server server;
    late MediaRpcClient client;
    setUp(() async {
      service = BrokenService();
      server = Server.create(services: [service]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      client = MediaRpcClient(identity.copyWith(port: server.port!));
    });
    tearDown(() async {
      await client.close();
      await server.shutdown();
    });

    test(
      'a failed second page preserves its durable cursor and completed previews',
      () async {
        final repository = await TamayuraRepository.open(
          path: inMemoryDatabasePath,
          factory: databaseFactoryFfi,
        );
        try {
          await repository.replacePeerSnapshot(identity, [
            MediaItem(
              id: 'original',
              deviceId: identity.id,
              name: 'original.jpg',
              sharedFolderId: 'camera',
              sharedFolderName: 'Camera',
              relativePath: 'original.jpg',
              mimeType: 'image/jpeg',
              size: 1,
              modifiedMs: 1,
              thumbnail: Uint8List.fromList([8]),
            ),
          ]);
          service.breakMetadata = true;
          await expectLater(
            client.synchronize(repository, pageSize: 1),
            throwsA(grpcCode(StatusCode.unavailable)),
          );
          final cached = (await repository.listMediaPage()).items;
          expect(cached.map((item) => item.id).toSet(), {
            'original',
            'safe-id',
          });
          expect(cached.firstWhere((item) => item.id == 'original').thumbnail, [
            8,
          ]);
          final checkpoint = (await repository.findPeerSnapshot(identity))!;
          expect(checkpoint.receivedCount, 1);
          expect(checkpoint.readyCount, 1);
          expect(checkpoint.nextPageToken, 'second-page');
          expect(checkpoint.metadataComplete, false);
          expect(await repository.peerRevision(identity.id), isNull);
        } finally {
          await repository.close();
        }
      },
    );

    test(
      'interrupted metadata stream never returns a partial snapshot',
      () async {
        service.breakMetadata = true;
        await expectLater(
          client.listMedia(),
          throwsA(grpcCode(StatusCode.unavailable)),
        );
      },
    );

    test('malicious or incomplete directory metadata is rejected', () async {
      for (final path in [
        '',
        '../photo.jpg',
        '/photo.jpg',
        'a//photo.jpg',
        'a/./photo.jpg',
        r'a\photo.jpg',
        'C:/photo.jpg',
        'a/\u0000photo.jpg',
        'a/other.jpg',
      ]) {
        service.relativePath = path;
        await expectLater(
          client.listMediaPage(),
          throwsFormatException,
          reason: 'Invalid path: $path',
        );
      }
      service.relativePath = '2026/photo.jpg';
      service.sharedFolderId = '';
      await expectLater(client.listMediaPage(), throwsFormatException);
      service.sharedFolderId = 'camera';
      service.sharedFolderName = '../Camera';
      await expectLater(client.listMediaPage(), throwsFormatException);
    });

    test('duplicate media identifiers reject the entire snapshot', () async {
      service.duplicateMetadata = true;
      await expectLater(client.listMedia(), throwsFormatException);
    });

    test(
      'incorrect byte offsets and premature normal EOF reject a range',
      () async {
        service.wrongOffset = true;
        await expectLater(
          client.readRange('safe-id', 0, 10).toList(),
          throwsFormatException,
        );
        service.wrongOffset = false;
        await expectLater(
          client.readRange('safe-id', 0, 10).toList(),
          throwsFormatException,
        );
      },
    );

    test(
      'unsupported protocol versions fail before importing metadata',
      () async {
        service.protocolVersion = 99;
        await expectLater(client.listMedia(), throwsFormatException);
      },
    );
  });
}

class BrokenService extends wire.MediaLibraryServiceBase {
  bool breakMetadata = false;
  bool duplicateMetadata = false;
  bool wrongOffset = false;
  int protocolVersion = mediaProtocolVersion;
  String sharedFolderId = 'camera';
  String sharedFolderName = 'Camera';
  String relativePath = '2026/photo.jpg';
  @override
  Future<wire.DeviceIdentity> getIdentity(
    ServiceCall call,
    wire.Empty request,
  ) async => wire.DeviceIdentity(
    id: identity.id,
    name: identity.name,
    protocolVersion: protocolVersion,
  );
  @override
  Future<wire.CatalogResponse> listMediaPage(
    ServiceCall call,
    wire.CatalogRequest request,
  ) async {
    if (breakMetadata && request.pageToken.isNotEmpty) {
      throw const GrpcError.unavailable('Connection was interrupted');
    }
    final item = wire.MediaEntry(
      id: 'safe-id',
      name: 'photo.jpg',
      sharedFolderId: sharedFolderId,
      sharedFolderName: sharedFolderName,
      relativePath: relativePath,
      mimeType: 'image/jpeg',
      size: Int64(10),
    );
    return wire.CatalogResponse(
      revision: 'broken-revision',
      totalCount: breakMetadata || duplicateMetadata ? 2 : 1,
      items: [item, if (duplicateMetadata) item],
      nextPageToken: breakMetadata ? 'second-page' : '',
    );
  }

  @override
  Future<wire.ThumbnailResponse> getThumbnail(
    ServiceCall call,
    wire.ThumbnailRequest request,
  ) async => wire.ThumbnailResponse(
    id: request.id,
    revision: request.revision,
    data: [1],
  );

  @override
  Stream<wire.FileChunk> readFile(
    ServiceCall call,
    wire.ReadRequest request,
  ) async* {
    yield wire.FileChunk(offset: Int64(wrongOffset ? 5 : 0), data: [1]);
  }
}
