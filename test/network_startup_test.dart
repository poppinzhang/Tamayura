import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/network/generated/media.pbgrpc.dart' as wire;
import 'package:tamayura/network/media_rpc.dart';

const _identity = Peer(
  id: 'startup-source',
  name: 'Startup source',
  host: '127.0.0.1',
  port: 0,
);

MediaMetadata _photo(String id, {String folder = 'photos'}) => MediaMetadata(
  id: id,
  deviceId: _identity.id,
  name: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 3,
  modifiedMs: 123,
  sharedFolderId: folder,
  sharedFolderName: 'Photos',
  relativePath: '$id.jpg',
);

class _ControlledSource implements LocalMediaSource {
  final scans = <Completer<List<MediaMetadata>>>[];

  @override
  Future<List<MediaMetadata>> scan() {
    final result = Completer<List<MediaMetadata>>();
    scans.add(result);
    return result.future;
  }

  @override
  Future<Uint8List> readThumbnail(String id) async => Uint8List.fromList([1]);

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List.fromList([1, 2, 3].sublist(offset, offset + length));
}

class _RestorableSource extends _ControlledSource
    implements RestorableLocalMediaSource {
  final restores = <Completer<List<MediaMetadata>?>>[];
  final _scanEvents = StreamController<int>.broadcast();

  @override
  Future<List<MediaMetadata>?> restore() {
    final result = Completer<List<MediaMetadata>?>();
    restores.add(result);
    return result.future;
  }

  @override
  Future<List<MediaMetadata>> scan() {
    final result = super.scan();
    _scanEvents.add(scans.length);
    return result;
  }

  Future<void> waitForScans(int count) async {
    if (scans.length >= count) return;
    await _scanEvents.stream
        .firstWhere((value) => value >= count)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() => _scanEvents.close();
}

Matcher _grpcCode(int code) =>
    isA<GrpcError>().having((error) => error.code, 'code', code);

void main() {
  sqfliteFfiInit();
  late _ControlledSource source;
  late MediaRpcServer server;

  setUp(() {
    source = _ControlledSource();
    server = MediaRpcServer(identity: _identity, source: source);
  });

  tearDown(() async {
    await server.stop();
  });

  Future<void> startWith(String id) async {
    final starting = server.start();
    source.scans.last.complete([_photo(id)]);
    await starting.timeout(const Duration(seconds: 5));
  }

  Future<void> expectServing(String id) async {
    final client = MediaRpcClient(_identity.copyWith(port: server.port));
    try {
      expect((await client.identity()).id, _identity.id);
      expect((await client.listMedia()).map((item) => item.id), [id]);
      expect(
        await client.readRange(id, 0, 3).expand((bytes) => bytes).toList(),
        [1, 2, 3],
      );
    } finally {
      await client.close();
    }
  }

  _RestorableSource restorable({void Function()? onChanged}) {
    final result = _RestorableSource();
    source = result;
    server = MediaRpcServer(
      identity: _identity,
      source: source,
      onCatalogChanged: onChanged,
    );
    addTearDown(result.close);
    return result;
  }

  MediaRpcClient connect() {
    final client = MediaRpcClient(_identity.copyWith(port: server.port));
    addTearDown(client.close);
    return client;
  }

  test(
    'background cold start serves identity and preserves a receiver until a real empty scan completes',
    () async {
      final cached = _photo('old').withThumbnail(Uint8List.fromList([9]));
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(repository.close);
      await repository.replacePeerSnapshot(_identity, [cached]);
      final local = restorable();
      await server
          .start(backgroundScan: true)
          .timeout(const Duration(seconds: 5));
      final client = connect();
      expect(server.port, isNonZero);
      expect(server.scanning, isTrue);
      expect((await client.identity()).id, _identity.id);
      await expectLater(
        client.synchronize(repository),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      expect((await repository.listMedia()).single.id, 'old');
      expect((await repository.getMedia(_identity.id, 'old'))!.thumbnail, [9]);
      await expectLater(
        client.thumbnail('old', revision: 'old-revision'),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      await expectLater(
        client.readRange('old', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );

      local.restores.single.complete(null);
      await local.waitForScans(1);
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      local.scans.single.complete([]);
      await server.catalogReady.timeout(const Duration(seconds: 5));
      expect(server.scanning, isFalse);
      expect(server.revision, isNotEmpty);
      final synced = await client.synchronize(repository);
      expect(synced.deletedCount, 1);
      expect(await repository.listMedia(), isEmpty);
    },
  );

  test(
    'restored catalog serves original files during its scan with the existing v4 wire revision',
    () async {
      final changes = <(bool, int)>[];
      final local = restorable(
        onChanged: () =>
            changes.add((server.scanning, server.localMedia.length)),
      );
      await server.start(backgroundScan: true);
      local.restores.single.complete([_photo('cached')]);
      await local.waitForScans(1);
      expect(server.scanning, isTrue);
      await expectServing('cached');

      // Fixture from the released v4 canonical encoding, before background
      // catalog preparation was introduced. Wire fields/protocol are unchanged.
      const priorRevision =
          '39e50255972b3b688b341244a116d396017f96cdd7773fbebd8c3111311a95d6';
      expect(server.revision, priorRevision);
      final channel = ClientChannel(
        '127.0.0.1',
        port: server.port,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      addTearDown(channel.terminate);
      final oldClient = wire.MediaLibraryClient(channel);
      expect((await oldClient.getIdentity(wire.Empty())).protocolVersion, 4);
      final unchanged = await oldClient.listMediaPage(
        wire.CatalogRequest(knownRevision: priorRevision),
      );
      expect(unchanged.notModified, isTrue);
      expect(unchanged.totalCount, 1);
      final bytes = await oldClient
          .readFile(
            wire.ReadRequest(
              id: 'cached',
              offset: Int64.ZERO,
              length: Int64(3),
            ),
          )
          .expand((chunk) => chunk.data)
          .toList();
      expect(bytes, [1, 2, 3]);

      local.scans.single.complete([_photo('fresh')]);
      await server.catalogReady.timeout(const Duration(seconds: 5));
      expect(server.scanning, isFalse);
      await expectServing('fresh');
      expect(changes, contains((true, 1)));
      expect(changes.last, (false, 1));
    },
  );

  test(
    'background start without a restorable adapter still scans asynchronously',
    () async {
      await server.start(backgroundScan: true);
      expect(server.scanning, isTrue);
      final client = connect();
      expect((await client.identity()).id, _identity.id);
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      source.scans.single.complete([_photo('fresh')]);
      await server.catalogReady.timeout(const Duration(seconds: 5));
      await expectServing('fresh');
    },
  );

  test(
    'restore failure is reported and survives a successful full scan',
    () async {
      final cacheError = StateError('Unsupported local cache version');
      final errors = <Object?>[];
      final local = restorable(
        onChanged: () => errors.add(server.restoreError),
      );
      await server.start(backgroundScan: true);
      local.restores.single.completeError(cacheError);
      await local.waitForScans(1);
      expect(server.restoreError, same(cacheError));
      expect(errors, contains(same(cacheError)));
      local.scans.single.complete([_photo('fresh')]);
      await server.catalogReady.timeout(const Duration(seconds: 5));
      expect(server.restoreError, same(cacheError));
      expect(server.scanError, isNull);
      await expectServing('fresh');
      final retry = server.refresh();
      local.scans.last.complete([_photo('fresh')]);
      await retry;
      expect(server.restoreError, isNull);
    },
  );

  test(
    'failed background scan revokes restored files and reports a retryable catalog error',
    () async {
      final local = restorable();
      await server.start(backgroundScan: true);
      local.restores.single.complete([_photo('cached')]);
      await local.waitForScans(1);
      await expectServing('cached');
      final failed = const FileSystemException('Shared folder unavailable');
      local.scans.single.completeError(failed);
      await server.catalogReady.timeout(const Duration(seconds: 5));
      expect(server.scanError, same(failed));
      expect(server.scanning, isFalse);
      final client = connect();
      expect((await client.identity()).id, _identity.id);
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.failedPrecondition)),
      );
      await expectLater(
        client.readRange('cached', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.failedPrecondition)),
      );
      final retry = server.refresh();
      local.scans.last.complete([_photo('recovered')]);
      await retry;
      expect(server.scanError, isNull);
      await expectServing('recovered');
    },
  );

  for (final invalid in [false, true]) {
    test(
      'a ${invalid ? 'malformed' : 'duplicate'} cache never publishes a partial restored catalog',
      () async {
        final local = restorable();
        await server.start(backgroundScan: true);
        local.restores.single.complete([
          _photo('cached'),
          _photo(invalid ? '' : 'cached'),
        ]);
        await local.waitForScans(1);
        expect(server.restoreError, isNotNull);
        expect(server.localMedia, isEmpty);
        final client = connect();
        await expectLater(
          client.listMedia(),
          throwsA(_grpcCode(StatusCode.unavailable)),
        );
        local.scans.single.complete([_photo('fresh')]);
        await server.catalogReady;
        await expectServing('fresh');
      },
    );
  }

  for (final lateFailure in [false, true]) {
    test(
      'stop and restart discard a late restore ${lateFailure ? 'failure' : 'success'} without callbacks',
      () async {
        var callbacks = 0;
        final local = restorable(onChanged: () => callbacks++);
        await server.start(backgroundScan: true);
        final oldReady = server.catalogReady;
        final oldRestore = local.restores.single;
        await server.stop().timeout(const Duration(seconds: 1));
        await oldReady.timeout(const Duration(seconds: 1));
        expect(server.scanning, isFalse);
        await server.start(backgroundScan: true);
        local.restores.last.complete([_photo('new')]);
        await local.waitForScans(1);
        final count = callbacks;
        if (lateFailure) {
          oldRestore.completeError(StateError('Old restore failed'));
        } else {
          oldRestore.complete([_photo('old')]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(callbacks, count);
        expect(server.restoreError, isNull);
        expect(local.scans, hasLength(1));
        await expectServing('new');
        local.scans.single.complete([_photo('new')]);
        await server.catalogReady.timeout(const Duration(seconds: 5));
      },
    );

    test(
      'manual refresh supersedes a late restore ${lateFailure ? 'failure' : 'success'}',
      () async {
        var callbacks = 0;
        final local = restorable(onChanged: () => callbacks++);
        await server.start(backgroundScan: true);
        final oldReady = server.catalogReady;
        final refreshing = server.refresh();
        await oldReady.timeout(const Duration(seconds: 1));
        local.scans.single.complete([_photo('manual')]);
        await refreshing;
        final count = callbacks;
        if (lateFailure) {
          local.restores.single.completeError(StateError('Old restore failed'));
        } else {
          local.restores.single.complete([_photo('old')]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(callbacks, count);
        expect(server.restoreError, isNull);
        expect(local.scans, hasLength(1));
        await expectServing('manual');
      },
    );

    test(
      'manual refresh supersedes a late background scan ${lateFailure ? 'failure' : 'success'}',
      () async {
        var callbacks = 0;
        final local = restorable(onChanged: () => callbacks++);
        await server.start(backgroundScan: true);
        local.restores.single.complete([_photo('cached')]);
        await local.waitForScans(1);
        final oldScan = local.scans.single;
        final oldReady = server.catalogReady;
        final refreshing = server.refresh();
        await oldReady.timeout(const Duration(seconds: 1));
        local.scans.last.complete([_photo('manual')]);
        await refreshing;
        final count = callbacks;
        if (lateFailure) {
          oldScan.completeError(StateError('Old scan failed'));
        } else {
          oldScan.complete([_photo('old')]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(callbacks, count);
        expect(server.scanError, isNull);
        await expectServing('manual');
      },
    );
  }

  test(
    'folder revocation cancels a pending restore and never advertises an empty snapshot',
    () async {
      final local = restorable();
      await server.start(backgroundScan: true);
      final ready = server.catalogReady;
      server.invalidateCatalog();
      await ready.timeout(const Duration(seconds: 1));
      expect(server.scanning, isFalse);
      local.restores.single.complete([_photo('revoked')]);
      await Future<void>.delayed(Duration.zero);
      expect(local.scans, isEmpty);
      final client = connect();
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      await expectLater(
        client.readRange('revoked', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
    },
  );

  test(
    'folder revocation keeps retained original reads while replacing the catalog',
    () async {
      final local = restorable();
      await server.start(backgroundScan: true);
      local.restores.single.complete([
        _photo('keep'),
        _photo('remove', folder: 'removed-root'),
      ]);
      await local.waitForScans(1);
      final oldScan = local.scans.single;
      final oldRevision = server.revision;
      server.invalidateCatalog(retainSharedFolderIds: {'photos'});
      final refreshing = server.refresh();
      final client = connect();
      expect(
        await client.readRange('keep', 0, 3).expand((bytes) => bytes).toList(),
        [1, 2, 3],
      );
      await expectLater(
        client.readRange('remove', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.notFound)),
      );
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      await expectLater(
        client.thumbnail('keep', revision: oldRevision),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      oldScan.complete([_photo('remove', folder: 'removed-root')]);
      await Future<void>.delayed(Duration.zero);
      expect(server.localMedia.map((item) => item.id), ['keep']);
      local.scans.last.complete([_photo('keep')]);
      await refreshing;
      await expectServing('keep');
    },
  );

  test(
    'background restart does not expose an old catalog before native restore revalidates access',
    () async {
      final local = restorable();
      await server.start(backgroundScan: true);
      local.restores.single.complete([_photo('old')]);
      await local.waitForScans(1);
      local.scans.single.complete([_photo('old')]);
      await server.catalogReady;
      await expectServing('old');
      await server.stop();
      await server.start(backgroundScan: true);
      final client = connect();
      expect((await client.identity()).id, _identity.id);
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      await expectLater(
        client.readRange('old', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      // A folder edit while native restoration is pending must not make the
      // previous session's unvalidated identifiers readable again.
      server.invalidateCatalog(retainSharedFolderIds: {'photos'});
      await expectLater(
        client.readRange('old', 0, 3).toList(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      local.restores.last.complete(null);
      final refreshing = server.refresh();
      await local.waitForScans(2);
      await expectLater(
        client.listMedia(),
        throwsA(_grpcCode(StatusCode.unavailable)),
      );
      local.scans.last.complete([_photo('current')]);
      await refreshing;
      await expectServing('current');
    },
  );

  test(
    'a failed background socket bind leaves no catalog task running',
    () async {
      final local = restorable();
      final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(occupied.close);
      await expectLater(
        server.start(port: occupied.port, backgroundScan: true),
        throwsA(isA<SocketException>()),
      );
      await server.catalogReady.timeout(const Duration(seconds: 1));
      expect(server.scanning, isFalse);
      expect(local.restores, isEmpty);
      expect(local.scans, isEmpty);
      await server.start(backgroundScan: true);
      local.restores.single.complete([_photo('recovered')]);
      await local.waitForScans(1);
      await expectServing('recovered');
      local.scans.single.complete([_photo('recovered')]);
      await server.catalogReady;
    },
  );

  test(
    'stopping a background socket bind prevents a late restore from starting',
    () async {
      final local = restorable();
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      final binding = Completer<ServerSocket>();
      final requested = Completer<void>();
      final starting = IOOverrides.runZoned(
        () => server.start(backgroundScan: true),
        serverSocketBind:
            (
              address,
              port, {
              int backlog = 0,
              bool v6Only = false,
              bool shared = false,
            }) {
              requested.complete();
              return binding.future;
            },
      );
      await requested.future.timeout(const Duration(seconds: 5));
      final ready = server.catalogReady;
      await server.stop().timeout(const Duration(seconds: 1));
      await ready.timeout(const Duration(seconds: 1));
      binding.complete(socket);
      await starting;
      expect(server.scanning, isFalse);
      expect(server.port, 0);
      expect(local.restores, isEmpty);
      expect(local.scans, isEmpty);
    },
  );

  test(
    'stop cancels a pending startup scan without waiting for its provider',
    () async {
      final starting = server.start();
      expect(source.scans, hasLength(1));
      await server.stop().timeout(const Duration(seconds: 1));
      source.scans.single.complete([_photo('late')]);
      await starting.timeout(const Duration(seconds: 5));
      expect(server.port, 0);
      expect(server.localMedia, isEmpty);
      expect(server.revision, isEmpty);
      expect(server.scanError, isNull);
      await startWith('recovered');
      await expectServing('recovered');
    },
  );

  test(
    'an old startup scan cannot replace a newer listener or catalog',
    () async {
      final oldStart = server.start();
      final oldScan = source.scans.single;
      await server.stop();
      await startWith('new');
      final newPort = server.port;
      final newRevision = server.revision;
      await expectServing('new');
      oldScan.complete([_photo('old')]);
      await oldStart.timeout(const Duration(seconds: 5));
      expect(server.port, newPort);
      expect(server.revision, newRevision);
      expect(server.localMedia.map((item) => item.id), ['new']);
      await expectServing('new');
    },
  );

  test(
    'stop invalidates a pending refresh even before the next startup scan',
    () async {
      await startWith('original');
      final originalRevision = server.revision;
      final refreshing = server.refresh();
      final lateScan = source.scans.last;
      await server.stop().timeout(const Duration(seconds: 1));
      lateScan.complete([_photo('late')]);
      await refreshing;
      expect(server.port, 0);
      expect(server.revision, originalRevision);
      expect(server.localMedia.map((item) => item.id), ['original']);
      await startWith('recovered');
      await expectServing('recovered');
    },
  );

  test(
    'a cancelled refresh failure cannot revoke a restarted catalog',
    () async {
      await startWith('original');
      final refreshing = server.refresh();
      final lateScan = source.scans.last;
      await server.stop();
      await startWith('recovered');
      final newRevision = server.revision;
      lateScan.completeError(const FileSystemException('Old provider failed'));
      await refreshing.timeout(const Duration(seconds: 5));
      expect(server.scanError, isNull);
      expect(server.revision, newRevision);
      await expectServing('recovered');
    },
  );

  test(
    'a socket that finishes binding after stop is closed without replacing a restart',
    () async {
      final oldSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final oldPort = oldSocket.port;
      final binding = Completer<ServerSocket>();
      final requested = Completer<void>();
      addTearDown(oldSocket.close);
      final oldStart = IOOverrides.runZoned(
        () => server.start(port: oldPort),
        serverSocketBind:
            (
              address,
              port, {
              int backlog = 0,
              bool v6Only = false,
              bool shared = false,
            }) {
              requested.complete();
              return binding.future;
            },
      );
      source.scans.single.complete([_photo('old')]);
      await requested.future.timeout(const Duration(seconds: 5));
      await server.stop().timeout(const Duration(seconds: 1));
      await startWith('recovered');
      final newPort = server.port;
      binding.complete(oldSocket);
      await oldStart.timeout(const Duration(seconds: 5));
      expect(server.port, newPort);
      await expectServing('recovered');
      // Prove that the obsolete real socket has released its listening port.
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        oldPort,
      );
      await rebound.close();
    },
  );

  test(
    'a cancelled socket bind failure cannot fail the restarted server',
    () async {
      final binding = Completer<ServerSocket>();
      final requested = Completer<void>();
      final oldStart = IOOverrides.runZoned(
        () => server.start(),
        serverSocketBind:
            (
              address,
              port, {
              int backlog = 0,
              bool v6Only = false,
              bool shared = false,
            }) {
              requested.complete();
              return binding.future;
            },
      );
      source.scans.single.complete([_photo('old')]);
      await requested.future.timeout(const Duration(seconds: 5));
      await server.stop();
      await startWith('recovered');
      final newPort = server.port;
      binding.completeError(const SocketException('Old bind failed'));
      await oldStart.timeout(const Duration(seconds: 5));
      expect(server.port, newPort);
      expect(server.scanError, isNull);
      await expectServing('recovered');
    },
  );
}
