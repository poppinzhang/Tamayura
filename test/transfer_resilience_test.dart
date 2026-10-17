import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/background/transfer_worker.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/downloader.dart';
import 'package:tamayura/network/media_rpc.dart';

import 'controller_test.dart' show FakeBridge;

const _source = Peer(id: 'source', name: 'Source', host: '127.0.0.1', port: 0);

MediaItem _media(int size) => MediaItem(
  id: 'video',
  deviceId: _source.id,
  name: 'video.mp4',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: 'video.mp4',
  mimeType: 'video/mp4',
  size: size,
  modifiedMs: 1,
  thumbnail: Uint8List(0),
);

Uint8List _bytes(int size) =>
    Uint8List.fromList(List.generate(size, (index) => index % 251));

/// Serves real bytes slowly enough for a test to interrupt the stream.
class _SlowSource implements LocalMediaSource {
  _SlowSource(this.item, this.bytes, {this.afterFirstChunk});
  final MediaItem item;
  final Uint8List bytes;
  final Future<void>? afterFirstChunk;
  final offsets = <int>[];
  Object? failure;

  @override
  Future<List<MediaMetadata>> scan() async => [item];
  @override
  Future<Uint8List> readThumbnail(String id) async => Uint8List(0);
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    offsets.add(offset);
    if (offset > 0) await afterFirstChunk;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final error = failure;
    if (error != null) throw error;
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

/// Forwards TCP until told to drop everything silently, like a peer that went
/// to sleep or left Wi-Fi without sending a reset.
class _BlackholeProxy {
  _BlackholeProxy._(this._listener, this._target);
  final ServerSocket _listener;
  final int _target;
  final _sockets = <Socket>[];
  bool blackhole = false;
  int get port => _listener.port;

  static Future<_BlackholeProxy> start(int target) async {
    final proxy = _BlackholeProxy._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      target,
    );
    proxy._listener.listen(proxy._forward);
    return proxy;
  }

  Future<void> _forward(Socket inbound) async {
    final upstream = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _target,
    );
    _sockets.addAll([inbound, upstream]);
    inbound.listen((data) {
      if (!blackhole) upstream.add(data);
    }, onError: (Object _) {});
    upstream.listen((data) {
      if (!blackhole) inbound.add(data);
    }, onError: (Object _) {});
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _listener.close();
  }
}

Matcher _grpcCode(int code) =>
    isA<GrpcError>().having((error) => error.code, 'code', code);

class _NativeReadBridge extends FakeBridge {
  String code = 'SCAN_CANCELLED';
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      throw PlatformException(code: code, message: 'native read failed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tamayura-resilience-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'a silent peer is caught over real gRPC and its bytes are kept',
    () async {
      final item = _media(mediaChunkSize * 2);
      final firstChunkPersisted = Completer<void>();
      final server = MediaRpcServer(
        identity: _source,
        source: _SlowSource(
          item,
          _bytes(item.size),
          afterFirstChunk: firstChunkPersisted.future,
        ),
      );
      await server.start();
      addTearDown(server.stop);
      final proxy = await _BlackholeProxy.start(server.port);
      addTearDown(proxy.close);
      addTearDown(() {
        if (!firstChunkPersisted.isCompleted) firstChunkPersisted.complete();
      });
      var received = 0;
      await expectLater(
        // Real TCP/HTTP2 setup, identity verification and the first 2 MiB
        // message need a CI-sized budget. Fast watchdog timing is covered by
        // resumable_download_test; this test checks a real silent connection.
        MediaDownloader(stallTimeout: const Duration(seconds: 5))
            .downloadResumable(
              peer: _source.copyWith(port: proxy.port),
              item: item,
              directory: root,
              taskId: 'silent',
              onProgress: (bytes, _) {
                received = bytes;
                if (bytes > 0 && !firstChunkPersisted.isCompleted) {
                  proxy.blackhole = true;
                  // Do not let the second message get buffered before the
                  // receiver has persisted the first and injected the outage.
                  firstChunkPersisted.complete();
                }
              },
            )
            .timeout(const Duration(seconds: 20)),
        throwsA(isA<TransferStalled>()),
      );
      expect(proxy.blackhole, isTrue);
      expect(received, inExclusiveRange(0, item.size));
      expect(received, mediaChunkSize);
      expect(
        await File(p.join(root.path, 'silent', '0.part')).length(),
        received,
      );
    },
  );

  test(
    'a source that stops sharing is a transient outage and a later run resumes',
    () async {
      // More than one chunk, so the stop lands between two chunks.
      final item = _media(mediaChunkSize * 2);
      final bytes = _bytes(item.size);
      final source = _SlowSource(item, bytes);
      final first = MediaRpcServer(identity: _source, source: source);
      await first.start();
      Object? failure;
      var stopping = false;
      try {
        await MediaDownloader().downloadResumable(
          peer: _source.copyWith(port: first.port),
          item: item,
          directory: root,
          taskId: 'stopped',
          onProgress: (received, _) {
            if (received > 0 && !stopping) {
              stopping = true;
              unawaited(first.stop());
            }
          },
        );
      } catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(isTransientTransferError(failure!), isTrue, reason: '$failure');
      final kept = await File(p.join(root.path, 'stopped', '0.part')).length();
      expect(kept, greaterThan(0));

      final second = MediaRpcServer(identity: _source, source: source);
      await second.start();
      addTearDown(second.stop);
      source.offsets.clear();
      final file = await MediaDownloader().downloadResumable(
        peer: _source.copyWith(port: second.port),
        item: item,
        directory: root,
        taskId: 'stopped',
      );
      expect(source.offsets.first, kept);
      expect(
        await file.openRead().expand((chunk) => chunk).toList(),
        orderedEquals(bytes),
      );
    },
  );

  test(
    'a catalog change mid-read is retryable, a missing file is not',
    () async {
      final item = _media(64);
      final source = _SlowSource(item, _bytes(item.size));
      final server = MediaRpcServer(identity: _source, source: source);
      await server.start();
      addTearDown(server.stop);
      // A fresh connection per call keeps each failed stream independent.
      Future<List<int>> read() async {
        final client = MediaRpcClient(_source.copyWith(port: server.port));
        try {
          return await client
              .readRange(item.id, 0, 16)
              .expand((b) => b)
              .toList();
        } finally {
          await client.close();
        }
      }

      source.failure = const MediaSourceInterrupted();
      await expectLater(read(), throwsA(_grpcCode(StatusCode.unavailable)));
      source.failure = const FileSystemException('deleted');
      await expectLater(read(), throwsA(_grpcCode(StatusCode.notFound)));
      source.failure = null;
      expect(await read(), _bytes(item.size).sublist(0, 16));
    },
  );

  test(
    'native catalog replacement reaches peers as a retryable outage',
    () async {
      final bridge = _NativeReadBridge();
      final db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final tasks = await TransferStore.open(
        path: p.join(root.path, 'tasks.db'),
        factory: databaseFactoryFfi,
      );
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => db,
        openTransfers: () async => tasks,
      );
      addTearDown(() async {
        await model.shutdown();
        await bridge.events.close();
      });
      await model.initialize();
      bridge.selection = {'uri': 'content://album', 'name': 'Album'};
      await model.chooseSharedFolder();
      final peer = Peer(
        id: FakeBridge.identity,
        name: '',
        host: '127.0.0.1',
        port: model.port,
      );
      Future<void> expectRead(int code) async {
        final client = MediaRpcClient(peer);
        try {
          final id = (await client.listMediaPage()).items.single.id;
          await expectLater(
            client.readRange(id, 0, 3).toList(),
            throwsA(_grpcCode(code)),
          );
        } finally {
          await client.close();
        }
      }

      await expectRead(StatusCode.unavailable);
      bridge.code = 'FILE_NOT_FOUND';
      await expectRead(StatusCode.notFound);
    },
  );

  test(
    'the Android worker asks JobScheduler to retry while its peer is away',
    () async {
      databaseFactory = databaseFactoryFfi;
      final databases = p.join(root.path, 'db');
      await databaseFactoryFfi.setDatabasesPath(databases);
      final staging = await Directory(p.join(root.path, 'staging')).create();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const background = MethodChannel('tamayura/background');
      const platform = MethodChannel('tamayura/platform');
      messenger.setMockMethodCallHandler(platform, (call) async {
        if (call.method == 'databaseDirectory') return databases;
        if (call.method == 'transferDirectory') return staging.path;
        if (call.method == 'transferSpace') return <String, Object?>{};
        throw PlatformException(code: 'UNEXPECTED', message: call.method);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(background, null);
        messenger.setMockMethodCallHandler(platform, null);
      });
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unreachable = _source.copyWith(port: closed.port);
      await closed.close();
      final store = await TransferStore.open();
      final task = await store.enqueue(
        unreachable,
        _media(10),
        'content://receive',
      );
      await store.close();
      final completed = Completer<Map<Object?, Object?>>();
      messenger.setMockMethodCallHandler(background, (call) async {
        switch (call.method) {
          case 'ready':
            return {'taskId': task.id};
          case 'complete':
            completed.complete(Map.of(call.arguments as Map));
        }
        return null;
      });
      await runBackgroundTransfer();
      final report = await completed.future.timeout(const Duration(seconds: 1));
      expect(report['success'], isFalse);
      expect(report['cancelled'], isFalse);
      expect(report['retry'], isTrue);
      expect(report['error'], contains('稍后会自动重试'));
      final reopened = await TransferStore.open();
      addTearDown(reopened.close);
      final waiting = (await reopened.get(task.id))!;
      expect(waiting.state, DownloadState.queued);
      expect(waiting.outageSinceMs, isNotNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
