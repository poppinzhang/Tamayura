import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/windows_bridge.dart';

const _deadline = Duration(seconds: 5);
const _identity = 'windows-aabbccdd-1234-5678-abcd-123456789abc';
const _photos = SharedFolder(id: 'photos', uri: r'C:\Photos', name: 'Photos');
const _other = SharedFolder(id: 'other', uri: r'D:\Pictures', name: 'Pictures');

Map<String, dynamic> _photo(int index, {SharedFolder folder = _photos}) => {
  'id': '${folder.id}-$index',
  'name': '$index.ARW',
  'mimeType': 'image/x-sony-arw',
  'size': 64 * 1024 * 1024,
  'modifiedMs': 123,
  'sharedFolderId': folder.id,
  'sharedFolderName': folder.name,
  'relativePath': '2026/$index.ARW',
};

class _Scan {
  _Scan(this.folders);
  final List<SharedFolder> folders;
  final result = Completer<List<Map<String, dynamic>>>();
}

/// Controllable native boundary. The catalog generation deliberately models
/// cancellation and immediate revocation on a native scan's admission, while
/// real gRPC and SQLite exercise the controller's startup/lifecycle ordering.
class _WindowsCatalogBridge extends WindowsBridge {
  _WindowsCatalogBridge(this.directory);
  final Directory directory;
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final scanChanges = StreamController<void>.broadcast(sync: true);
  final restoreResult = Completer<List<Map<String, dynamic>>?>();
  final scans = <_Scan>[];
  final restoredFolders = <List<SharedFolder>>[];
  Map<String, Map<String, dynamic>> files = {};
  Map<String, dynamic>? selection;
  Object? pickerError;
  PlatformException? cacheWarning;
  int discoveryStarts = 0, discoveryStops = 0, generation = 0;
  int? advertisedPort;

  @override
  Future<String> deviceId() async => _identity;

  @override
  Future<SharingStatus> sharingStatus() async =>
      const SharingStatus(enabled: false, running: false, batteryExempt: true);

  @override
  Stream<SharingStatus> get sharingEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get discoveryEvents => events.stream;

  @override
  Future<Map<String, dynamic>> localInfo() async => {
    'name': 'Windows source',
    'addresses': ['127.0.0.1'],
  };

  @override
  Future<void> startDiscovery({
    required String id,
    required String name,
    required int port,
  }) async {
    discoveryStarts++;
    advertisedPort = port;
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStops++;
  }

  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<PlatformException?> getLocalCatalogWarning() async => cacheWarning;

  @override
  Future<String> transferDirectory() async => '${directory.path}/staging';

  @override
  Future<Map<String, dynamic>?> pickDirectory() async {
    if (pickerError != null) throw pickerError!;
    return selection;
  }

  @override
  Future<void> validateSharedDirectory(
    String uri,
    List<String> existing,
  ) async {}

  @override
  Future<void> clearSharedDirectory() async {
    generation++;
    files.clear();
  }

  @override
  Future<List<Map<String, dynamic>>?> restoreDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    final expected = ++generation;
    restoredFolders.add(List.of(directories));
    final restored = await restoreResult.future;
    if (expected != generation) {
      throw PlatformException(
        code: 'SCAN_CANCELLED',
        message: 'Superseded restore',
      );
    }
    if (restored != null) {
      files = {for (final item in restored) item['id'] as String: item};
    }
    return restored;
  }

  @override
  Future<List<Map<String, dynamic>>> scanDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    final expected = ++generation;
    final retained = directories.map((folder) => folder.id).toSet();
    files.removeWhere((_, item) => !retained.contains(item['sharedFolderId']));
    final request = _Scan(List.of(directories));
    scans.add(request);
    scanChanges.add(null);
    try {
      final entries = await request.result.future;
      if (expected != generation) {
        throw PlatformException(
          code: 'SCAN_CANCELLED',
          message: 'Superseded scan',
        );
      }
      files = {for (final item in entries) item['id'] as String: item};
      return entries;
    } catch (_) {
      if (expected == generation) files.clear();
      rethrow;
    }
  }

  @override
  Future<Uint8List> thumbnail(String id) async => Uint8List(0);

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async {
    if (!files.containsKey(id)) {
      throw PlatformException(
        code: 'FILE_NOT_FOUND',
        message: 'No longer shared',
      );
    }
    return Uint8List.fromList(
      List.generate(length, (index) => (offset + index) % 251),
    );
  }

  Future<_Scan> scanAt(int index) async {
    while (scans.length <= index) {
      await scanChanges.stream.first.timeout(_deadline);
    }
    return scans[index];
  }

  void releaseAll() {
    if (!restoreResult.isCompleted) restoreResult.complete(null);
    for (final scan in scans) {
      if (!scan.result.isCompleted) scan.result.complete([]);
    }
  }
}

class _RemoteSource implements LocalMediaSource {
  @override
  Future<List<MediaMetadata>> scan() async => [];
  @override
  Future<Uint8List> readThumbnail(String id) async => Uint8List(0);
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List(length);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late _WindowsCatalogBridge bridge;
  late TamayuraRepository repository;
  late TransferStore transfers;
  late AppController model;
  final clients = <MediaRpcClient>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'tamayura-windows-catalog-',
    );
    bridge = _WindowsCatalogBridge(directory);
    repository = await TamayuraRepository.open(
      path: '${directory.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    transfers = await TransferStore.open(
      path: '${directory.path}/transfers.db',
      factory: databaseFactoryFfi,
    );
    await repository.setSetting(
      'sharedFolders',
      jsonEncode([_photos.toJson()]),
    );
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      // Discovery accepts only LAN addresses; route fixture peers to loopback.
      clientFactory: (peer) => MediaRpcClient(peer.copyWith(host: '127.0.0.1')),
      openRepository: () async => repository,
      openTransfers: () async => transfers,
    );
  });

  tearDown(() async {
    bridge.releaseAll();
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    await model.shutdown().timeout(_deadline);
    await bridge.events.close();
    await bridge.scanChanges.close();
    await directory.delete(recursive: true);
  });

  Future<void> until(bool Function() predicate) async {
    if (predicate()) return;
    final done = Completer<void>();
    void changed() {
      if (predicate() && !done.isCompleted) done.complete();
    }

    model.addListener(changed);
    try {
      await done.future.timeout(_deadline);
    } finally {
      model.removeListener(changed);
    }
  }

  MediaRpcClient localClient() {
    final client = MediaRpcClient(
      Peer(id: _identity, name: 'Source', host: '127.0.0.1', port: model.port),
    );
    clients.add(client);
    return client;
  }

  Future<List<int>> read(MediaRpcClient client, String id) => client
      .readRange(id, 0, 3)
      .expand((bytes) => bytes)
      .toList()
      .timeout(_deadline);

  test(
    'slow restore leaves initialization, discovery and settings responsive',
    () async {
      await model.initialize().timeout(_deadline);
      expect(model.loading, isFalse);
      expect(model.busy, isFalse);
      expect(model.localScanning, isTrue);
      expect(model.port, greaterThan(0));
      expect(bridge.advertisedPort, model.port);
      expect((await localClient().identity()).id, _identity);
      expect(bridge.scans, isEmpty);
      bridge.selection = {'uri': r'E:\Received', 'name': 'Received'};
      await model.chooseDownloadFolder().timeout(_deadline);
      expect(model.downloadFolder, 'Received');
      expect(await repository.getSetting('downloadUri'), r'E:\Received');
      expect(model.busy, isFalse);
    },
  );

  test(
    'ten thousand restored ARW entries remain downloadable during a slow scan',
    () async {
      await model.initialize().timeout(_deadline);
      bridge.restoreResult.complete(List.generate(10000, _photo));
      final scan = await bridge.scanAt(0);
      await until(() => model.localMediaCount == 10000);
      expect(scan.result.isCompleted, isFalse);
      expect(model.localScanning, isTrue);
      expect(model.busy, isFalse);
      final client = localClient();
      expect(await read(client, 'photos-9999'), [0, 1, 2]);
      await model.refreshAfterResume().timeout(_deadline);
      await model.refreshAfterResume().timeout(_deadline);
      expect(bridge.scans, hasLength(1));
      scan.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1);
      expect((await client.listMedia()).map((item) => item.id), ['photos-0']);
    },
  );

  test(
    'first scan has no false empty catalog and still discovers online peers',
    () async {
      bridge.restoreResult.complete(null);
      await model.initialize().timeout(_deadline);
      final scan = await bridge.scanAt(0);
      final client = localClient();
      await expectLater(client.listMedia(), throwsA(isA<GrpcError>()));
      const remoteIdentity = Peer(
        id: 'remote-device',
        name: 'Remote',
        host: '127.0.0.1',
        port: 0,
      );
      final remote = MediaRpcServer(
        identity: remoteIdentity,
        source: _RemoteSource(),
      );
      await remote.start();
      addTearDown(remote.stop);
      bridge.events.add({
        'type': 'found',
        'id': remoteIdentity.id,
        'name': remoteIdentity.name,
        'host': '10.0.0.2',
        'port': remote.port,
      });
      await until(
        () => model.devices.any(
          (device) => device.id == remoteIdentity.id && device.online,
        ),
      );
      expect(scan.result.isCompleted, isFalse);
      expect(model.localScanning, isTrue);
      expect(model.busy, isFalse);
      scan.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1);
      expect(await read(client, 'photos-0'), [0, 1, 2]);
    },
  );

  test(
    'removing a root revokes its files before superseding a pending scan',
    () async {
      await repository.setSetting(
        'sharedFolders',
        jsonEncode([_photos.toJson(), _other.toJson()]),
      );
      bridge.restoreResult.complete([_photo(0), _photo(0, folder: _other)]);
      await model.initialize().timeout(_deadline);
      final oldScan = await bridge.scanAt(0);
      await until(() => model.localMediaCount == 2);
      final client = localClient();
      expect(await read(client, 'other-0'), [0, 1, 2]);
      await model.removeSharedFolder(_other.id).timeout(_deadline);
      final newScan = await bridge.scanAt(1);
      expect(newScan.folders.map((folder) => folder.id), [_photos.id]);
      expect(model.busy, isFalse);
      await expectLater(read(client, 'other-0'), throwsA(isA<GrpcError>()));
      expect(await read(client, 'photos-0'), [0, 1, 2]);
      oldScan.result.complete([_photo(0), _photo(0, folder: _other)]);
      newScan.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1 && !model.localScanning);
      expect((await client.listMedia()).map((item) => item.id), ['photos-0']);
      expect(model.error, isNull);
    },
  );

  test(
    'hiding without background sharing stops despite pending restore',
    () async {
      await model.initialize().timeout(_deadline);
      expect(model.port, greaterThan(0));
      await model.setForeground(false).timeout(_deadline);
      expect(model.port, 0);
      bridge.restoreResult.complete([_photo(0)]);
      await Future<void>.delayed(Duration.zero);
      expect(model.port, 0);
      expect(bridge.scans, isEmpty);
      expect(model.localMediaCount, 0);
    },
  );

  test(
    'removing all roots during restore cannot resurrect the cached catalog',
    () async {
      await model.initialize().timeout(_deadline);
      await model.removeSharedFolder(_photos.id).timeout(_deadline);
      await until(() => !model.localScanning);
      expect(model.sharedFolders, isEmpty);
      expect(model.busy, isFalse);
      final client = localClient();
      expect(await client.listMedia(), isEmpty);
      bridge.restoreResult.complete([_photo(0)]);
      await Future<void>.delayed(Duration.zero);
      expect(await client.listMedia(), isEmpty);
      await expectLater(read(client, 'photos-0'), throwsA(isA<GrpcError>()));
      expect(bridge.scans, isEmpty);
      expect(model.error, isNull);
    },
  );

  test(
    'failed cache restoration reports its error and still rebuilds in the background',
    () async {
      await model.initialize().timeout(_deadline);
      bridge.restoreResult.completeError(
        PlatformException(
          code: 'CATALOG_CACHE_INVALID',
          message: 'Invalid local catalog cache',
        ),
      );
      final scan = await bridge.scanAt(0);
      await until(() => model.error != null);
      expect(model.error, contains('Invalid local catalog cache'));
      expect(model.busy, isFalse);
      expect(model.port, greaterThan(0));
      scan.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
    },
  );

  test(
    'old cache diagnostics do not overwrite a newer picker failure but can return after retry',
    () async {
      await model.initialize().timeout(_deadline);
      final cacheError = PlatformException(
        code: 'LOCAL_CATALOG_IO',
        message: 'Native cache diagnostic',
      );
      bridge.restoreResult.completeError(cacheError);
      final first = await bridge.scanAt(0);
      await until(() => model.error == describeError(cacheError));
      bridge.pickerError = PlatformException(
        code: 'PICKER_FAILED',
        message: 'New directory picker failure',
      );
      await model.chooseDownloadFolder().timeout(_deadline);
      expect(model.error, 'New directory picker failure');
      first.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
      expect(model.localMediaCount, 1);
      expect(model.error, 'New directory picker failure');
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);

      model.clearError();
      expect(model.error, isNull);
      bridge.cacheWarning = cacheError;
      await model.refresh().timeout(_deadline);
      final retry = await bridge.scanAt(1);
      retry.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
      expect(model.error, describeError(cacheError));
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
    },
  );

  test(
    'cache write failure keeps the live scan downloadable and clears after recovery',
    () async {
      bridge.restoreResult.complete(null);
      bridge.cacheWarning = PlatformException(
        code: 'LOCAL_CATALOG_IO',
        message: 'Native cache write diagnostic',
      );
      await model.initialize().timeout(_deadline);
      final first = await bridge.scanAt(0);
      first.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1 && !model.localScanning);
      expect(model.error, describeError(bridge.cacheWarning!));
      expect(model.busy, isFalse);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
      bridge.cacheWarning = null;
      await model.refresh().timeout(_deadline);
      final retry = await bridge.scanAt(1);
      retry.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
      expect(model.error, isNull);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
    },
  );

  test(
    'a background scan failure is visible and a manual retry remains usable',
    () async {
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize().timeout(_deadline);
      final first = await bridge.scanAt(0);
      await until(() => model.localMediaCount == 1);
      first.result.completeError(
        PlatformException(
          code: 'PERMISSION_LOST',
          message: 'Shared root unavailable',
        ),
      );
      await until(() => model.error != null);
      expect(model.busy, isFalse);
      expect(model.port, greaterThan(0));
      await expectLater(
        read(localClient(), 'photos-0'),
        throwsA(isA<GrpcError>()),
      );
      await model.refresh().timeout(_deadline);
      final retry = await bridge.scanAt(1);
      expect(model.busy, isFalse);
      retry.result.complete([_photo(0)]);
      await until(() => model.localMediaCount == 1 && !model.localScanning);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
      expect(model.error, isNull);
    },
  );
}
