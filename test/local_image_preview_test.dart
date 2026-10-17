import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge;

const _peer = Peer(id: 'source', name: 'Source', host: '192.0.2.5', port: 4000);

MediaItem _media(String id, {bool video = false}) => MediaItem(
  id: id,
  deviceId: _peer.id,
  name: '$id.${video ? 'mp4' : 'jpg'}',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.${video ? 'mp4' : 'jpg'}',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  size: 3,
  modifiedMs: 123,
  thumbnail: Uint8List.fromList([4, 5, 6]),
);

class _PreviewBridge extends FakeBridge {
  final requests = <(String, int)>[];
  final gates = <String, Completer<void>>{};
  final decoded = <String, Completer<void>>{};
  Completer<void> _requestChanged = Completer<void>();
  Object? failure;
  int active = 0, maximumActive = 0;

  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await _requestChanged.future.timeout(const Duration(seconds: 5));
    }
  }

  @override
  Future<Uint8List> readPreview(String uri, {int maxDimension = 2560}) async {
    requests.add((uri, maxDimension));
    final bytesRead = decoded[uri] = Completer<void>();
    _requestChanged.complete();
    _requestChanged = Completer<void>();
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      if (failure != null) throw failure!;
      final file = File.fromUri(Uri.parse(uri));
      if (!await file.exists()) {
        throw PlatformException(code: 'FILE_NOT_FOUND');
      }
      // Preserve bytes read before deletion to exercise a late native response.
      final bytes = await file.readAsBytes();
      bytesRead.complete();
      await gates[uri]?.future;
      return bytes;
    } finally {
      active--;
    }
  }

  @override
  Future<void> deleteDownload(String uri) async {
    final file = File.fromUri(Uri.parse(uri));
    if (await file.exists()) await file.delete();
  }

  void releaseAll() {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory temporary;
  late TamayuraRepository repository;
  late TransferStore tasks;
  late _PreviewBridge bridge;
  late AppController model;

  MediaView photo(String id) =>
      model.media.singleWhere((item) => item.id == id);
  String savedUri(String id) => model.transfers[photo(id).key]!.savedUri!;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tamayura-preview-test-');
    repository = await TamayuraRepository.open(
      path: '${temporary.path}/library.db',
      factory: databaseFactoryFfi,
    );
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    bridge = _PreviewBridge();
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => repository,
      openTransfers: () async => tasks,
    );
    await model.setForeground(false);
    final items = [
      for (var index = 0; index < 4; index++) _media('photo-$index'),
      _media('video', video: true),
      _media('unsaved'),
    ];
    await repository.replacePeerSnapshot(_peer, items);
    for (final item in items.where((item) => item.id != 'unsaved')) {
      final file = await File(
        '${temporary.path}/${item.name}',
      ).writeAsBytes([1, 2, 3]);
      await repository.saveDownload(
        DownloadRecord(
          deviceId: item.deviceId,
          mediaId: item.id,
          uri: file.uri.toString(),
          completedAt: DateTime.utc(2026, 1, 1),
        ),
      );
    }
    await model.initialize();
    expect(model.error, isNull);
  });

  tearDown(() async {
    bridge.releaseAll();
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test(
    'saved image reads forward full-screen and gallery dimensions',
    () async {
      final item = photo('photo-0');
      expect(await model.loadPreview(item), [1, 2, 3]);
      expect(await model.loadPreview(item, maxDimension: 640), [1, 2, 3]);
      expect(bridge.requests, [
        (savedUri(item.id), 2560),
        (savedUri(item.id), 640),
      ]);
    },
  );

  test('unsaved media and saved videos never request image decoding', () async {
    expect(await model.loadPreview(photo('unsaved')), isNull);
    expect(await model.loadPreview(photo('video')), isNull);
    expect(bridge.requests, isEmpty);
  });

  test('missing local image quietly preserves its saved record', () async {
    final item = photo('photo-0');
    final uri = savedUri(item.id);
    await File.fromUri(Uri.parse(uri)).delete();
    var notifications = 0;
    model.addListener(() => notifications++);
    expect(await model.loadPreview(item, maxDimension: 640), isNull);
    expect(model.error, isNull);
    expect(notifications, 0);
    expect(model.transfers[item.key]!.savedUri, uri);
    expect((await repository.getDownload(item.deviceId, item.id))!.uri, uri);
  });

  test(
    'permission or decoding failures quietly preserve saved records',
    () async {
      final item = photo('photo-0');
      final uri = savedUri(item.id);
      var notifications = 0;
      model.addListener(() => notifications++);
      for (final code in ['PERMISSION_LOST', 'PREVIEW_UNAVAILABLE']) {
        bridge.failure = PlatformException(code: code);
        expect(await model.loadPreview(item, maxDimension: 640), isNull);
        expect(model.error, isNull);
        expect(notifications, 0);
        expect(model.transfers[item.key]!.savedUri, uri);
        expect(
          (await repository.getDownload(item.deviceId, item.id))!.uri,
          uri,
        );
      }
      bridge.failure = null;
      expect(await model.loadPreview(item, maxDimension: 640), [1, 2, 3]);
    },
  );

  test('native preview decoding is limited to two concurrent reads', () async {
    final first = photo('photo-0');
    final second = photo('photo-1');
    bridge.gates[savedUri(first.id)] = Completer<void>();
    bridge.gates[savedUri(second.id)] = Completer<void>();
    final pending = [
      for (var index = 0; index < 4; index++)
        model.loadPreview(photo('photo-$index'), maxDimension: 640),
    ];
    await bridge.waitForRequests(2);
    expect(bridge.requests, hasLength(2));
    expect(bridge.maximumActive, 2);
    bridge.gates[savedUri(first.id)]!.complete();
    await bridge.waitForRequests(4);
    bridge.gates[savedUri(second.id)]!.complete();
    expect(await Future.wait(pending), everyElement([1, 2, 3]));
    expect(bridge.maximumActive, 2);
  });

  test('deleting a queued image skips its native read', () async {
    final firstUri = savedUri('photo-0');
    final secondUri = savedUri('photo-1');
    bridge.gates[firstUri] = Completer<void>();
    bridge.gates[secondUri] = Completer<void>();
    final first = model.loadPreview(photo('photo-0'));
    final second = model.loadPreview(photo('photo-1'));
    final queuedItem = photo('photo-2');
    final queued = model.loadPreview(queuedItem);
    await bridge.waitForRequests(2);
    expect(await model.deleteLocalFile(queuedItem), isTrue);
    bridge.releaseAll();
    expect(await first, [1, 2, 3]);
    expect(await second, [1, 2, 3]);
    expect(await queued, isNull);
    expect(bridge.requests, hasLength(2));
  });

  test(
    'superseded queued consumers do not delay current image decoding',
    () async {
      final firstUri = savedUri('photo-0');
      final secondUri = savedUri('photo-1');
      bridge.gates[firstUri] = Completer<void>();
      bridge.gates[secondUri] = Completer<void>();
      final first = model.loadPreview(photo('photo-0'));
      final second = model.loadPreview(photo('photo-1'));
      var current = true;
      final stale = model.loadPreview(
        photo('photo-2'),
        isCurrent: () => current,
      );
      final next = model.loadPreview(photo('photo-3'));
      await bridge.waitForRequests(2);
      current = false;
      bridge.gates[firstUri]!.complete();
      await bridge.waitForRequests(3);
      expect(await stale, isNull);
      expect(await next, [1, 2, 3]);
      expect(bridge.requests.map((request) => request.$1), [
        firstUri,
        secondUri,
        savedUri('photo-3'),
      ]);
      bridge.gates[secondUri]!.complete();
      expect(await first, [1, 2, 3]);
      expect(await second, [1, 2, 3]);
      expect(bridge.maximumActive, 2);
    },
  );

  test('superseded active consumers reject late native image bytes', () async {
    final item = photo('photo-0');
    final uri = savedUri(item.id);
    bridge.gates[uri] = Completer<void>();
    var current = true;
    final pending = model.loadPreview(item, isCurrent: () => current);
    await bridge.waitForRequests(1);
    await bridge.decoded[uri]!.future;
    current = false;
    bridge.gates[uri]!.complete();
    expect(await pending, isNull);
    expect(model.transfers[item.key]!.savedUri, uri);
    expect(await model.loadPreview(item, isCurrent: () => false), isNull);
    expect(bridge.requests, hasLength(1));
  });

  test(
    'deleting an image rejects bytes from an already-running read',
    () async {
      final item = photo('photo-0');
      final uri = savedUri(item.id);
      bridge.gates[uri] = Completer<void>();
      final pending = model.loadPreview(item);
      await bridge.waitForRequests(1);
      await bridge.decoded[uri]!.future;
      expect(await model.deleteLocalFile(item), isTrue);
      bridge.gates[uri]!.complete();
      expect(await pending, isNull);
      expect(model.transfers[item.key], isNull);
    },
  );

  test(
    'shutdown skips queued reads and rejects already-running bytes',
    () async {
      bridge.gates[savedUri('photo-0')] = Completer<void>();
      bridge.gates[savedUri('photo-1')] = Completer<void>();
      final pending = [
        for (var index = 0; index < 3; index++)
          model.loadPreview(photo('photo-$index')),
      ];
      await bridge.waitForRequests(2);
      await model.shutdown();
      bridge.releaseAll();
      expect(await Future.wait(pending), everyElement(isNull));
      expect(bridge.requests, hasLength(2));
    },
  );
}
