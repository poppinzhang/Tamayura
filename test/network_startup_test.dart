import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/network/media_rpc.dart';

const _identity = Peer(
  id: 'startup-source',
  name: 'Startup source',
  host: '127.0.0.1',
  port: 0,
);

MediaMetadata _photo(String id) => MediaMetadata(
  id: id,
  deviceId: _identity.id,
  name: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 3,
  modifiedMs: 123,
  sharedFolderId: 'photos',
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

void main() {
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
