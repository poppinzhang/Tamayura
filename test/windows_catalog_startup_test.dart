import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/local_catalog_maintenance.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/windows_bridge.dart';

import 'controller_test.dart' show GatedRepository;

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
  final watchEvents = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  int watchGeneration = 0, watchStarts = 0, watchStops = 0;
  bool watchFails = false;
  Completer<void>? watchStartWait;
  Object? partialError;
  final partialRequests = <List<LocalCatalogChange>>[];
  final partialResults = <Completer<List<Map<String, dynamic>>>>[];
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
  Stream<Map<String, dynamic>> get catalogEvents => watchEvents.stream;

  @override
  Future<void> startWatchingDirectories(
    List<SharedFolder> directories, {
    required int generation,
  }) async {
    watchGeneration = generation;
    watchStarts++;
    await watchStartWait?.future;
    if (watchFails) throw PlatformException(code: 'CATALOG_WATCH_UNAVAILABLE');
  }

  @override
  Future<void> stopWatchingDirectories() async {
    watchStops++;
  }

  @override
  Future<List<Map<String, dynamic>>> scanChangedDirectoriesMetadata(
    List<SharedFolder> directories,
    List<LocalCatalogChange> changes,
  ) async {
    final expected = ++generation;
    partialRequests.add(changes);
    if (partialError != null) throw partialError!;
    final result = Completer<List<Map<String, dynamic>>>();
    partialResults.add(result);
    final entries = await result.future;
    if (expected != generation) throw PlatformException(code: 'SCAN_CANCELLED');
    files = {for (final item in entries) item['id'] as String: item};
    return entries;
  }

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
    if (watchStartWait != null && !watchStartWait!.isCompleted) {
      watchStartWait!.complete();
    }
    if (!restoreResult.isCompleted) restoreResult.complete(null);
    for (final scan in scans) {
      if (!scan.result.isCompleted) scan.result.complete([]);
    }
    for (final result in partialResults) {
      if (!result.isCompleted) result.complete([]);
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
  late DateTime now;
  final clients = <MediaRpcClient>[];

  AppController controller({TamayuraRepository? store}) => AppController(
    clock: () => now,
    bridge: bridge,
    preferredPort: 0,
    clientFactory: (peer) => MediaRpcClient(peer.copyWith(host: '127.0.0.1')),
    openRepository: () async => store ?? repository,
    openTransfers: () async => transfers,
  );

  setUp(() async {
    now = DateTime.utc(2026, 11, 14, 12);
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
      clock: () => now,
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
    await bridge.watchEvents.close();
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

  Future<void> checkpoint({Duration age = Duration.zero}) =>
      repository.setSetting(
        LocalCatalogMaintenance.checkpointKey,
        jsonEncode({
          'version': 1,
          'roots': jsonEncode([_photos.toJson()]),
          'completedMs': now.subtract(age).millisecondsSinceEpoch,
        }),
      );

  test(
    'recent persisted full check restores without disk scan or foreground rescan',
    () async {
      await checkpoint(age: const Duration(hours: 2));
      await repository.setSetting('localScanIntervalHours', '48');
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      expect(model.supportsLocalCatalogScheduling, isTrue);
      expect(model.localScanIntervalHours, 48);
      expect(bridge.watchStarts, 1);
      expect(bridge.scans, isEmpty);
      now = now.add(const Duration(hours: 1));
      await model.refreshAfterResume();
      expect(bridge.scans, isEmpty);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
    },
  );

  test(
    'manual refresh overrides a fresh checkpoint and persists successful completion',
    () async {
      await checkpoint();
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      now = now.add(const Duration(minutes: 5));
      await model.refresh();
      final scan = await bridge.scanAt(0);
      scan.result.complete([_photo(1)]);
      await until(() => !model.localScanning);
      expect(await read(localClient(), 'photos-1'), [0, 1, 2]);
      // A database read queued after publication follows the checkpoint write.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final saved =
          jsonDecode(
                (await repository.getSetting(
                  LocalCatalogMaintenance.checkpointKey,
                ))!,
              )
              as Map;
      expect(saved['completedMs'], now.millisecondsSinceEpoch);
    },
  );

  test(
    'missing native cache forces full scan even when a checkpoint is recent',
    () async {
      await checkpoint();
      bridge.restoreResult.complete(null);
      await model.initialize();
      final scan = await bridge.scanAt(0);
      expect(model.localScanning, isTrue);
      scan.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
    },
  );

  test(
    'hour settings validate, persist and shorter interval triggers overdue full check',
    () async {
      await checkpoint(age: const Duration(hours: 3));
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      for (final hours in [0, -1, 8761]) {
        await model.setLocalScanIntervalHours(hours);
        expect(model.localScanIntervalHours, 24);
        expect(model.error, isNotNull);
      }
      await model.setLocalScanIntervalHours(8760);
      expect(await repository.getSetting('localScanIntervalHours'), '8760');
      expect(bridge.scans, isEmpty);
      await model.setLocalScanIntervalHours(1);
      final scan = await bridge.scanAt(0);
      expect(await repository.getSetting('localScanIntervalHours'), '1');
      scan.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
    },
  );

  test(
    'watcher overflow forces a full check without discarding the current catalog first',
    () async {
      await checkpoint();
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      bridge.watchEvents.add({
        'type': 'overflow',
        'generation': bridge.watchGeneration,
      });
      final scan = await bridge.scanAt(0);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
      scan.result.complete([_photo(1)]);
      await until(() => !model.localScanning);
    },
  );

  test(
    'watcher startup failure is visible and a fresh cache is still fully checked',
    () async {
      await checkpoint();
      bridge.watchFails = true;
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      final scan = await bridge.scanAt(0);
      expect(
        model.error,
        describeError(PlatformException(code: 'CATALOG_WATCH_UNAVAILABLE')),
      );
      scan.result.complete([_photo(0)]);
      await until(() => !model.localScanning);
    },
  );

  test(
    'a batch of imports uses the incremental path and leaves the full-check deadline unchanged',
    () async {
      await checkpoint(age: const Duration(hours: 2));
      final before = await repository.getSetting(
        LocalCatalogMaintenance.checkpointKey,
      );
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      for (var i = 0; i < 20; i++) {
        bridge.watchEvents.add({
          'type': 'changed',
          'generation': bridge.watchGeneration,
          'changes': [
            {'sharedFolderId': 'photos', 'relativePath': '2026/${i % 2}.ARW'},
          ],
        });
      }
      await until(() => model.localScanning);
      expect(bridge.scans, isEmpty);
      expect(bridge.partialRequests.single, hasLength(2));
      bridge.partialResults.single.complete([_photo(0), _photo(1)]);
      await until(() => !model.localScanning);
      expect(model.localMediaCount, 2);
      expect(await read(localClient(), 'photos-1'), [0, 1, 2]);
      expect(
        await repository.getSetting(LocalCatalogMaintenance.checkpointKey),
        before,
      );
    },
  );

  test(
    'a slow HDD watcher setup does not delay identity, discovery or settings',
    () async {
      await checkpoint();
      bridge.watchStartWait = Completer<void>();
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize().timeout(_deadline);
      expect(model.loading, isFalse);
      expect(model.busy, isFalse);
      expect(model.port, greaterThan(0));
      expect(bridge.discoveryStarts, 1);
      expect(bridge.restoredFolders, isEmpty);
      expect((await localClient().identity()).id, _identity);
      await model.setLocalScanIntervalHours(72);
      expect(model.localScanIntervalHours, 72);
      bridge.watchStartWait!.complete();
      await until(() => !model.localScanning);
      expect(bridge.scans, isEmpty);
      expect(await read(localClient(), 'photos-0'), [0, 1, 2]);
    },
  );

  test('manual full refresh supersedes a pending partial check', () async {
    await checkpoint();
    bridge.restoreResult.complete([_photo(0)]);
    await model.initialize();
    await until(() => !model.localScanning);
    bridge.watchEvents.add({
      'type': 'changed',
      'generation': bridge.watchGeneration,
      'changes': [
        {'sharedFolderId': 'photos', 'relativePath': '2026/1.ARW'},
      ],
    });
    await until(() => model.localScanning);
    expect(bridge.partialResults, hasLength(1));
    await model.refresh();
    final full = await bridge.scanAt(0);
    full.result.complete([_photo(2)]);
    await until(() => !model.localScanning);
    bridge.partialResults.single.complete([_photo(1)]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await read(localClient(), 'photos-2'), [0, 1, 2]);
    expect(model.error, isNull);
  });

  test(
    'native lost-baseline signal transparently falls back to a full check',
    () async {
      await checkpoint();
      bridge.partialError = PlatformException(
        code: 'LOCAL_CATALOG_UNAVAILABLE',
      );
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      bridge.watchEvents.add({
        'type': 'changed',
        'generation': bridge.watchGeneration,
        'changes': [
          {'sharedFolderId': 'photos', 'relativePath': '2026/1.ARW'},
        ],
      });
      final full = await bridge.scanAt(0);
      full.result.complete([_photo(1)]);
      await until(() => !model.localScanning);
      expect(bridge.partialRequests, hasLength(1));
      expect(model.error, isNull);
      expect(await read(localClient(), 'photos-1'), [0, 1, 2]);
    },
  );

  test(
    'failed setting writes retain the saved hours and permit retry',
    () async {
      final gated = GatedRepository(repository);
      model = controller(store: gated);
      await checkpoint();
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      gated.beforeSettingWrite = (key, _) async {
        if (key == 'localScanIntervalHours') {
          throw StateError('write unavailable');
        }
      };
      await model.setLocalScanIntervalHours(72);
      expect(model.localScanIntervalHours, 24);
      expect(model.localScanIntervalSaving, isFalse);
      expect(model.error, isNotNull);
      expect(await repository.getSetting('localScanIntervalHours'), isNull);
      gated.beforeSettingWrite = null;
      await model.setLocalScanIntervalHours(72);
      expect(model.localScanIntervalHours, 72);
      expect(await repository.getSetting('localScanIntervalHours'), '72');
    },
  );

  test(
    'a setting write in progress cannot be replaced by a second write',
    () async {
      final gated = GatedRepository(repository);
      model = controller(store: gated);
      await checkpoint();
      bridge.restoreResult.complete([_photo(0)]);
      await model.initialize();
      await until(() => !model.localScanning);
      final gate = Completer<void>();
      gated.beforeSettingWrite = (key, _) async {
        if (key == 'localScanIntervalHours') await gate.future;
      };
      final saving = model.setLocalScanIntervalHours(72);
      expect(model.localScanIntervalSaving, isTrue);
      await model.setLocalScanIntervalHours(96);
      expect(model.localScanIntervalHours, 24);
      gate.complete();
      await saving;
      expect(model.localScanIntervalHours, 72);
      expect(await repository.getSetting('localScanIntervalHours'), '72');
    },
  );

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
