import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/view_state.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/core/catalog_repository.dart';
import 'package:tamayura/core/transfer_task.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/background/transfer_worker.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/android_bridge.dart';

class FakeBridge extends AndroidBridge {
  static const identity = 'android-0123456789abcdef';
  final events = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic>? selection;
  bool scanFails = false, shareFails = false, identityFails = false;
  bool invalidMetadata = false;
  String? advertisedId, advertisedName;
  int? advertisedPort;
  String deviceName = '测试手机';
  Uint8List? savedBytes;
  List<String>? savedDirectories;
  final List<List<SharedFolder>> scans = [];
  bool overlaps = false;
  Future<void> Function(String)? schedule;
  Future<List<String>> Function()? queryScheduled;
  final Set<String> scheduled = {};
  @override
  Future<SharingStatus> sharingStatus() async =>
      const SharingStatus(enabled: false, running: false, batteryExempt: true);
  @override
  Stream<SharingStatus> get sharingEvents => const Stream.empty();
  @override
  Future<String> deviceId() async {
    if (identityFails) {
      throw PlatformException(
        code: 'DEVICE_ID_UNAVAILABLE',
        message: '无法读取设备标识，请重试',
      );
    }
    return identity;
  }

  @override
  Future<List<String>> scheduledTransferIds() async =>
      queryScheduled == null ? scheduled.toList() : queryScheduled!();
  @override
  Future<void> scheduleTransfer(String id) async {
    scheduled.add(id);
    await schedule?.call(id);
  }

  @override
  Future<void> cancelTransfer(String id) async {
    scheduled.remove(id);
  }

  @override
  Future<Uint8List> thumbnail(String id) async => Uint8List(0);
  @override
  Stream<Map<String, dynamic>> get discoveryEvents => events.stream;
  @override
  Future<Map<String, dynamic>> localInfo() async => {
    'name': deviceName,
    'addresses': ['192.168.1.5'],
  };
  @override
  Future<void> startDiscovery({
    required String id,
    required String name,
    required int port,
  }) async {
    advertisedId = id;
    advertisedName = name;
    advertisedPort = port;
  }

  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> clearSharedDirectory() async {}
  @override
  Future<Map<String, dynamic>?> pickDirectory() async => selection;
  @override
  Future<void> validateSharedDirectory(
    String uri,
    List<String> existingUris,
  ) async {
    if (overlaps) {
      throw PlatformException(code: 'DIR_OVERLAP', message: '共享目录不能重复或包含父子目录');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> scanDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    scans.add(directories);
    if (scanFails) {
      throw PlatformException(code: 'PERMISSION', message: '请重新授权共享目录');
    }
    return [
      for (final folder in directories)
        {
          'id': 'local-${folder.id}',
          'sharedFolderId': folder.id,
          'sharedFolderName': folder.name,
          'relativePath': '旅行/秋天/local.jpg',
          'name': 'local.jpg',
          'mimeType': 'image/jpeg',
          'size': invalidMetadata ? -1 : 3,
          'modifiedMs': 1,
          'thumbnail': Uint8List(0),
        },
    ];
  }

  @override
  Future<String> saveDownload({
    required List<String> sourcePaths,
    required int expectedSize,
    required String directoryUri,
    required String name,
    required String mimeType,
    required List<String> directories,
  }) async {
    savedDirectories = directories;
    final bytes = BytesBuilder();
    for (final path in sourcePaths) {
      bytes.add(await File(path).readAsBytes());
    }
    savedBytes = bytes.takeBytes();
    return 'content://saved/$name';
  }

  @override
  Future<void> share(String uri, String mimeType) async {
    if (shareFails) {
      throw PlatformException(code: 'MISSING', message: '文件已删除，请重新下载');
    }
  }
}

class MemorySource implements LocalMediaSource {
  MemorySource({this.deviceId = 'remote'});
  final String deviceId;
  bool fails = false;
  @override
  Future<List<MediaItem>> scan() async {
    if (fails) throw StateError('permission revoked');
    return [
      MediaItem(
        id: 'photo',
        deviceId: deviceId,
        name: 'photo.jpg',
        sharedFolderId: 'camera',
        sharedFolderName: 'Camera',
        relativePath: '旅行/秋天/photo.jpg',
        mimeType: 'image/jpeg',
        size: 3,
        modifiedMs: 1,
        thumbnail: Uint8List(0),
      ),
    ];
  }

  @override
  Future<Uint8List> readThumbnail(String id) async => Uint8List(0);
  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List.fromList([1, 2, 3].sublist(offset, offset + length));
}

class StubRpcClient extends MediaRpcClient {
  StubRpcClient(super.peer, {required this.onIdentity, this.onSynchronize});
  final Future<Peer> Function() onIdentity;
  final Future<SyncResult> Function()? onSynchronize;
  final closed = Completer<void>();
  int synchronizeCalls = 0, closeCalls = 0;
  @override
  Future<Peer> identity() => onIdentity();
  @override
  Future<SyncResult> synchronize(
    CatalogRepository repository, {
    int pageSize = 200,
    int maxRevisionRetries = 2,
    void Function(SyncProgress)? onProgress,
  }) async {
    ++synchronizeCalls;
    if (onSynchronize != null) return onSynchronize!();
    final peer = await identity();
    final items = await MemorySource(deviceId: peer.id).scan();
    await (repository as TamayuraRepository).replacePeerSnapshot(peer, items);
    return SyncResult(
      peer: peer,
      revision: 'test',
      totalCount: items.length,
      addedCount: 0,
      deletedCount: 0,
      thumbnailRequests: 0,
    );
  }

  @override
  Future<void> close() async {
    ++closeCalls;
    await super.close();
    if (!closed.isCompleted) closed.complete();
  }
}

Future<Peer> localIdentity(AppController model) async {
  final client = MediaRpcClient(
    Peer(id: '', name: '', host: '127.0.0.1', port: model.port),
  );
  try {
    return await client.identity();
  } finally {
    await client.close();
  }
}

/// Delegate to real SQLite while pausing a saved-file lookup during page append.
/// This places filter changes inside the old page's asynchronous work instead
/// of relying on timing between independent database calls.
class GatedRepository implements TamayuraRepository {
  GatedRepository(this.inner);
  final TamayuraRepository inner;
  Future<void> Function(String deviceId, String mediaId)? beforeDownloadRead;
  Future<void> Function(String key, String? value)? beforeSettingWrite;

  @override
  Future<String?> getSetting(String key) => inner.getSetting(key);
  @override
  Future<void> setSetting(String key, String? value) async {
    await beforeSettingWrite?.call(key, value);
    await inner.setSetting(key, value);
  }

  @override
  Future<List<Peer>> listPeers() => inner.listPeers();
  @override
  Future<SnapshotCheckpoint?> findPeerSnapshot(
    Peer peer, {
    bool claim = false,
    String? expectedSessionId,
  }) => inner.findPeerSnapshot(
    peer,
    claim: claim,
    expectedSessionId: expectedSessionId,
  );
  @override
  Future<MediaPage> listMediaPage({
    String? deviceId,
    String? sharedFolderId,
    MediaCursor? after,
    int limit = 60,
  }) => inner.listMediaPage(
    deviceId: deviceId,
    sharedFolderId: sharedFolderId,
    after: after,
    limit: limit,
  );
  @override
  Future<List<MediaCollection>> mediaCollections({String? deviceId}) =>
      inner.mediaCollections(deviceId: deviceId);
  @override
  Future<DownloadRecord?> getDownload(String deviceId, String mediaId) async {
    await beforeDownloadRead?.call(deviceId, mediaId);
    return inner.getDownload(deviceId, mediaId);
  }

  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late TamayuraRepository db;
  late FakeBridge bridge;
  late TransferStore tasks;
  late AppController model;
  late Directory temporary;
  setUp(() async {
    db = await TamayuraRepository.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    bridge = FakeBridge();
    temporary = await Directory.systemTemp.createTemp('tamayura-controller-');
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => db,
      openTransfers: () async => tasks,
    );
  });
  tearDown(() async {
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test('theme follows the system on first launch', () async {
    expect(model.themeMode, ThemeMode.system);
    await model.initialize();
    expect(model.themeMode, ThemeMode.system);
    expect(model.themeModeSaving, isFalse);
    expect(await db.getSetting('themeMode'), isNull);
  });

  for (final mode in ThemeMode.values) {
    test('initialization restores the saved ${mode.name} theme', () async {
      await db.setSetting('themeMode', mode.name);
      await model.initialize();
      expect(model.themeMode, mode);
      expect(model.error, isNull);
    });
  }

  for (final invalid in ['', 'invalid']) {
    test('invalid theme setting "$invalid" follows the system', () async {
      await db.setSetting('themeMode', invalid);
      await model.initialize();
      expect(model.themeMode, ThemeMode.system);
      expect(model.error, isNull);
    });
  }

  test('theme changes persist light, dark, and system selections', () async {
    await model.initialize();
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      await model.setThemeMode(mode);
      expect(model.themeMode, mode);
      expect(await db.getSetting('themeMode'), mode.name);
      expect(model.themeModeSaving, isFalse);
      expect(model.error, isNull);
    }
  });

  test(
    'saved theme survives closing and reopening application stores',
    () async {
      await db.close();
      final path = '${temporary.path}/theme.db';
      db = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      await model.initialize();
      await model.setThemeMode(ThemeMode.dark);
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: path,
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      model = AppController(
        bridge: bridge,
        openRepository: () async => db,
        openTransfers: () async => tasks,
      );
      await model.initialize();
      expect(model.themeMode, ThemeMode.dark);
      expect(model.error, isNull);
    },
  );

  test(
    'theme write failure keeps the saved selection and supports retry',
    () async {
      final gated = GatedRepository(db);
      model = AppController(
        bridge: bridge,
        openRepository: () async => gated,
        openTransfers: () async => tasks,
      );
      await db.setSetting('themeMode', 'light');
      await model.initialize();
      gated.beforeSettingWrite = (key, value) async {
        throw StateError('disk write failed');
      };
      await model.setThemeMode(ThemeMode.dark);
      expect(model.themeMode, ThemeMode.light);
      expect(await db.getSetting('themeMode'), 'light');
      expect(model.themeModeSaving, isFalse);
      expect(model.error, '主题设置保存失败，请重试');
      gated.beforeSettingWrite = null;
      await model.setThemeMode(ThemeMode.dark);
      expect(model.themeMode, ThemeMode.dark);
      expect(await db.getSetting('themeMode'), 'dark');
      expect(model.error, isNull);
    },
  );

  test(
    'pending theme save prevents overlapping writes and notifies listeners',
    () async {
      final gated = GatedRepository(db);
      model = AppController(
        bridge: bridge,
        openRepository: () async => gated,
        openTransfers: () async => tasks,
      );
      await model.initialize();
      model.setForeground(false);
      final entered = Completer<void>();
      final release = Completer<void>();
      final observed = <(ThemeMode, bool)>[];
      var writeCount = 0;
      gated.beforeSettingWrite = (key, value) async {
        writeCount++;
        entered.complete();
        await release.future;
      };
      model.addListener(() {
        observed.add((model.themeMode, model.themeModeSaving));
      });
      final saving = model.setThemeMode(ThemeMode.dark);
      try {
        await entered.future;
        expect(model.themeMode, ThemeMode.system);
        expect(model.themeModeSaving, isTrue);
        expect(model.busy, isFalse);
        await model.setThemeMode(ThemeMode.light);
        expect(writeCount, 1);
      } finally {
        release.complete();
        await saving;
      }
      expect(model.themeMode, ThemeMode.dark);
      expect(await db.getSetting('themeMode'), 'dark');
      expect(
        observed,
        containsAllInOrder([(ThemeMode.system, true), (ThemeMode.dark, false)]),
      );
    },
  );

  test(
    'theme change before initialization reports a recoverable error',
    () async {
      await model.setThemeMode(ThemeMode.dark);
      expect(model.themeMode, ThemeMode.system);
      expect(model.error, '应用尚未完成初始化，请重试后切换主题');
      await model.initialize();
      await model.setThemeMode(ThemeMode.dark);
      expect(model.themeMode, ThemeMode.dark);
      expect(model.error, isNull);
    },
  );

  test(
    'first launch starts serving, cancel picker leaves settings unchanged',
    () async {
      await model.initialize();
      expect(model.loading, false);
      expect(model.error, null);
      expect(model.port, greaterThan(0));
      expect(model.deviceName, '测试手机');
      final identity = await localIdentity(model);
      expect(identity.id, FakeBridge.identity);
      expect(identity.name, '测试手机');
      expect(bridge.advertisedId, identity.id);
      expect(bridge.advertisedName, identity.name);
      expect(bridge.advertisedPort, model.port);
      expect(await db.getSetting('deviceId'), isNull);
      await model.chooseSharedFolder();
      expect(model.sharedFolders, isEmpty);
      expect(model.localMediaCount, 0);
    },
  );

  test(
    'occupied preferred port uses and advertises a working dynamic port',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(occupied.close);
      // Isolate the fixture from an actual Tamayura app using the default port.
      model = AppController(
        bridge: bridge,
        preferredPort: occupied.port,
        openRepository: () async => db,
        openTransfers: () async => tasks,
      );
      await model.initialize();
      expect(model.error, isNull);
      expect(model.port, greaterThan(0));
      expect(model.port, isNot(occupied.port));
      expect(bridge.advertisedPort, model.port);
      expect((await localIdentity(model)).id, FakeBridge.identity);
    },
  );

  test(
    'device identity survives rebuilding all local application stores',
    () async {
      await model.initialize();
      final before = await localIdentity(model);
      bridge.selection = {'uri': 'content://camera', 'name': 'Camera'};
      await model.chooseSharedFolder();
      final client = MediaRpcClient(before);
      try {
        expect((await client.listMedia()).single.deviceId, before.id);
      } finally {
        await client.close();
      }
      await model.shutdown();
      await temporary.delete(recursive: true);
      await temporary.create();
      db = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      model = AppController(
        bridge: bridge,
        openRepository: () async => db,
        openTransfers: () async => tasks,
      );
      await model.initialize();
      expect(model.error, isNull);
      expect((await localIdentity(model)).id, before.id);
      expect(bridge.advertisedId, before.id);
      expect(model.sharedFolders, isEmpty);
      expect(await db.getSetting('deviceId'), isNull);
    },
  );

  test(
    'identity read failure prevents serving and can recover by refreshing',
    () async {
      bridge.identityFails = true;
      await model.initialize();
      expect(model.loading, isFalse);
      expect(model.busy, isFalse);
      expect(model.error, contains('无法读取设备标识'));
      expect(model.port, 0);
      expect(bridge.advertisedId, isNull);
      bridge.identityFails = false;
      await model.refresh();
      expect(model.error, isNull);
      expect((await localIdentity(model)).id, FakeBridge.identity);
      expect(bridge.advertisedId, FakeBridge.identity);
    },
  );

  test(
    'renaming a device updates discovery and RPC without changing identity',
    () async {
      await model.initialize();
      final port = model.port;
      bridge.deviceName = '旅行手机';
      await model.refresh();
      final identity = await localIdentity(model);
      expect(model.port, port);
      expect(model.deviceName, '旅行手机');
      expect(identity.id, FakeBridge.identity);
      expect(identity.name, '旅行手机');
      expect(bridge.advertisedId, identity.id);
      expect(bridge.advertisedName, identity.name);
    },
  );

  test(
    'revoked startup directory does not prevent receiving; choosing a new folder recovers',
    () async {
      await db.setSetting(
        'sharedFolders',
        jsonEncode([
          const SharedFolder(
            id: 'old',
            uri: 'content://old',
            name: 'Camera',
          ).toJson(),
        ]),
      );
      bridge.scanFails = true;
      await model.initialize();
      expect(model.port, greaterThan(0));
      expect(model.error, contains('重新授权'));
      expect(model.localMediaCount, 0);
      bridge.scanFails = false;
      await model.removeSharedFolder('old');
      bridge.selection = {'uri': 'content://new', 'name': '新目录'};
      await model.chooseSharedFolder();
      expect(model.localMediaCount, 1);
      expect(model.error, null);
      expect(model.sharedFolders.single.uri, 'content://new');
      expect(jsonDecode((await db.getSetting('sharedFolders'))!), hasLength(1));
    },
  );

  test(
    'invalid manual connection gives actionable error without losing state',
    () async {
      await model.initialize();
      await model.connect('https://8.8.8.8');
      expect(model.error, contains('局域网'));
      expect(model.busy, false);
      expect(model.devices, isEmpty);
      model.clearError();
      expect(model.error, null);
    },
  );

  test(
    'multiple roots are retained, recursively served and independently removed',
    () async {
      await model.initialize();
      bridge.selection = {'uri': 'content://camera', 'name': 'Camera'};
      await model.chooseSharedFolder();
      final first = model.sharedFolders.single;
      bridge.selection = {'uri': 'content://pictures', 'name': 'Pictures'};
      await model.chooseSharedFolder();
      expect(model.sharedFolders.map((folder) => folder.name), [
        'Camera',
        'Pictures',
      ]);
      expect(model.localMediaCount, 2);
      expect(
        bridge.scans.last.map((folder) => folder.id),
        model.sharedFolders.map((folder) => folder.id),
      );
      final client = MediaRpcClient(
        Peer(id: '', name: '', host: '127.0.0.1', port: model.port),
      );
      addTearDown(client.close);
      final catalog = await client.listMediaPage();
      expect(catalog.items.map((item) => item.sharedFolderName).toSet(), {
        'Camera',
        'Pictures',
      });
      expect(
        catalog.items.every((item) => item.relativePath == '旅行/秋天/local.jpg'),
        isTrue,
      );
      await model.removeSharedFolder(first.id);
      expect(model.sharedFolders.single.name, 'Pictures');
      expect(model.localMediaCount, 1);
      expect(
        (await client.listMediaPage()).items.single.sharedFolderName,
        'Pictures',
      );
      await model.removeSharedFolder(model.sharedFolders.single.id);
      expect(model.localMediaCount, 0);
      expect((await client.listMediaPage()).items, isEmpty);
      expect(jsonDecode((await db.getSetting('sharedFolders'))!), isEmpty);
    },
  );

  test(
    'duplicate and overlapping directories leave the saved sharing set unchanged',
    () async {
      await model.initialize();
      bridge.selection = {'uri': 'content://parent', 'name': 'Parent'};
      await model.chooseSharedFolder();
      final stored = await db.getSetting('sharedFolders');
      final scans = bridge.scans.length;
      await model.chooseSharedFolder();
      expect(model.error, contains('重复'));
      bridge.overlaps = true;
      bridge.selection = {'uri': 'content://parent/child', 'name': 'Child'};
      await model.chooseSharedFolder();
      expect(model.error, contains('父子目录'));
      expect(model.sharedFolders, hasLength(1));
      expect(model.localMediaCount, 1);
      expect(await db.getSetting('sharedFolders'), stored);
      expect(bridge.scans, hasLength(scans));
    },
  );

  test('activation rescans local folders at most once per interval', () async {
    var now = DateTime(2026, 10, 17, 9);
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async => db,
      openTransfers: () async => tasks,
      clock: () => now,
      resumeRescanInterval: const Duration(minutes: 1),
    );
    await model.initialize();
    bridge.selection = {'uri': 'content://album', 'name': 'Album'};
    await model.chooseSharedFolder();
    final scans = bridge.scans.length;

    now = now.add(const Duration(seconds: 30));
    await model.refreshAfterResume();
    expect(bridge.scans, hasLength(scans), reason: 'Recent scan is reused');
    expect(model.error, isNull);

    await model.refresh();
    expect(bridge.scans, hasLength(scans + 1), reason: 'Manual refresh scans');

    now = now.add(const Duration(seconds: 59));
    await model.refreshAfterResume();
    expect(bridge.scans, hasLength(scans + 1));
    now = now.add(const Duration(seconds: 1));
    await model.refreshAfterResume();
    expect(bridge.scans, hasLength(scans + 2));

    // A failed scan is retried on the next activation, however recent.
    bridge.scanFails = true;
    now = now.add(const Duration(minutes: 1));
    await model.refreshAfterResume();
    expect(bridge.scans, hasLength(scans + 3));
    bridge.scanFails = false;
    now = now.add(const Duration(seconds: 1));
    await model.refreshAfterResume();
    expect(bridge.scans, hasLength(scans + 4));
    expect(model.localMediaCount, 1);
  });

  for (final invalidMetadata in [false, true]) {
    test(
      'activation immediately retries a recent ${invalidMetadata ? 'invalid metadata' : 'provider'} scan failure',
      () async {
        var now = DateTime(2026, 10, 17, 9);
        model = AppController(
          bridge: bridge,
          preferredPort: 0,
          openRepository: () async => db,
          openTransfers: () async => tasks,
          clock: () => now,
        );
        await model.initialize();
        bridge.selection = {'uri': 'content://album', 'name': 'Album'};
        await model.chooseSharedFolder();
        final scans = bridge.scans.length;
        final client = MediaRpcClient(
          Peer(id: '', name: '', host: '127.0.0.1', port: model.port),
        );
        addTearDown(client.close);
        expect((await client.listMediaPage()).items, hasLength(1));

        now = now.add(const Duration(seconds: 5));
        bridge.scanFails = !invalidMetadata;
        bridge.invalidMetadata = invalidMetadata;
        await model.refresh();
        expect(bridge.scans, hasLength(scans + 1));
        expect(model.error, isNotNull);
        expect(model.localMediaCount, 0);
        await expectLater(
          client.listMediaPage(),
          throwsA(
            isA<GrpcError>().having(
              (error) => error.code,
              'code',
              StatusCode.failedPrecondition,
            ),
          ),
        );

        bridge.scanFails = false;
        bridge.invalidMetadata = false;
        now = now.add(const Duration(seconds: 1));
        await model.refreshAfterResume();
        expect(bridge.scans, hasLength(scans + 2));
        expect(model.error, isNull);
        expect(model.localMediaCount, 1);
        expect((await client.listMediaPage()).items, hasLength(1));

        now = now.add(const Duration(seconds: 1));
        await model.refreshAfterResume();
        expect(
          bridge.scans,
          hasLength(scans + 2),
          reason: 'A recovered catalog uses the healthy scan interval again',
        );
        expect(model.error, isNull);
        expect(model.localMediaCount, 1);
      },
    );
  }

  test(
    'saved shared roots retain identity and all appear after initialization',
    () async {
      const folders = [
        SharedFolder(id: 'a', uri: 'content://a', name: 'Camera'),
        SharedFolder(id: 'b', uri: 'content://b', name: 'Pictures'),
      ];
      await db.setSetting(
        'sharedFolders',
        jsonEncode(folders.map((folder) => folder.toJson()).toList()),
      );
      await model.initialize();
      expect(model.error, isNull);
      expect(model.sharedFolders.map((folder) => folder.id), ['a', 'b']);
      expect(model.localMediaCount, 2);
    },
  );

  test(
    'remembered peer sync, one-tap download, persisted save and missing-file retry',
    () async {
      final source = MemorySource();
      final server = MediaRpcServer(
        identity: const Peer(id: 'remote', name: 'B手机', host: '', port: 0),
        source: source,
      );
      await server.start();
      addTearDown(server.stop);
      await db.upsertPeer(
        Peer(id: 'remote', name: 'B手机', host: '127.0.0.1', port: server.port),
      );
      await db.setSetting('downloadUri', 'content://downloads');
      await db.setSetting('downloadFolder', 'Tamayura');
      await model.initialize();
      expect(model.media, hasLength(1));
      expect(model.devices.single.online, true);
      final photo = model.media.single;
      bridge.schedule = (id) => TransferRunner(
        store: tasks,
        repository: db,
        bridge: bridge,
        directory: Directory('${temporary.path}/transfers'),
      ).run(id);
      await model.download(photo);
      expect(bridge.savedBytes, [1, 2, 3]);
      expect(bridge.savedDirectories, ['B手机', 'Camera', '旅行', '秋天']);
      expect(model.transfers[photo.key]!.complete, true);
      expect(await db.getDownload('remote', 'photo'), isNotNull);
      expect(
        await Directory('${temporary.path}/transfers').list().toList(),
        isEmpty,
      );
      bridge.shareFails = true;
      await model.share(photo);
      expect(model.transfers[photo.key]!.error, contains('重新下载'));
      expect(await db.getDownload('remote', 'photo'), null);
      expect(model.error, contains('重新下载'));
      source.fails = true;
      await expectLater(server.refresh(), throwsStateError);
      await model.refresh();
      expect(
        model.media,
        hasLength(1),
        reason: 'failed catalog must preserve offline thumbnails',
      );
      expect(
        model.devices.single.online,
        true,
        reason: 'a reachable device remains online when its catalog fails',
      );
    },
  );
  test(
    'remembered Android identity keeps its album when rediscovered at a new IP and name',
    () async {
      const old = Peer(
        id: 'android-fedcba9876543210',
        name: 'B手机',
        host: '192.168.1.8',
        port: 50728,
      );
      await db.replacePeerSnapshot(
        old,
        await MemorySource(deviceId: old.id).scan(),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final attempted = <String>[];
      model = AppController(
        bridge: bridge,
        openTransfers: () async => tasks,
        openRepository: () async => db,
        clientFactory: (peer) {
          attempted.add(peer.host);
          return StubRpcClient(
            peer,
            onIdentity: () async {
              if (peer.host == old.host) {
                entered.complete();
                await release.future;
                throw const SocketException('old address offline');
              }
              return peer;
            },
          );
        },
      );
      final initializing = model.initialize();
      await entered.future;
      expect(model.loading, false);
      expect(model.busy, false);
      expect(model.media, hasLength(1));
      bridge.events.add({
        'type': 'found',
        'id': old.id,
        'name': '旅行手机',
        'host': '192.168.1.9',
        'port': 50728,
      });
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await initializing;
      expect(attempted, ['192.168.1.8', '192.168.1.9']);
      expect(model.devices.single.online, true);
      expect(model.devices.single.id, old.id);
      expect(model.devices.single.name, '旅行手机');
      expect((await db.listPeers()).single.host, '192.168.1.9');
      expect((await db.listPeers()).single.name, '旅行手机');
      expect(model.media.single.deviceId, old.id);
    },
  );

  group('mDNS presence checks', () {
    const remote = Peer(
      id: 'remote',
      name: 'B手机',
      host: '192.168.1.8',
      port: 50728,
    );
    late List<StubRpcClient> clients;
    late Future<Peer> Function(Peer peer, int index) identity;
    Future<SyncResult> Function(Peer peer, int index)? synchronization;
    Object? factoryFailure;

    setUp(() async {
      clients = [];
      synchronization = null;
      factoryFailure = null;
      identity = (peer, _) async =>
          remote.copyWith(host: peer.host, port: peer.port, name: peer.name);
      await db.upsertPeer(remote);
      model = AppController(
        bridge: bridge,
        openRepository: () async => db,
        openTransfers: () async => tasks,
        clientFactory: (peer) {
          if (factoryFailure != null) throw factoryFailure!;
          final index = clients.length;
          final client = StubRpcClient(
            peer,
            onIdentity: () => identity(peer, index),
            onSynchronize: synchronization == null
                ? null
                : () => synchronization!(peer, index),
          );
          clients.add(client);
          return client;
        },
      );
      await model.initialize();
      expect(model.devices.single.online, isTrue);
      expect(clients, hasLength(1));
    });

    Future<void> lost({String id = 'remote'}) async {
      bridge.events.add({
        'type': 'lost',
        'id': id,
        'host': '192.168.1.99',
        'port': 1234,
      });
      await Future<void>.delayed(Duration.zero);
    }

    test(
      'reachable peers retain online state without catalog synchronization',
      () async {
        final response = Completer<Peer>();
        identity = (_, _) => response.future;
        await lost();
        await lost();
        await lost(id: 'unknown');
        await lost(id: FakeBridge.identity);
        expect(
          clients,
          hasLength(2),
          reason: 'duplicate lost events share one probe',
        );
        expect(clients.last.peer.host, remote.host);
        expect(clients.last.peer.port, remote.port);
        expect(
          model.devices.single.online,
          isTrue,
          reason: 'pending is not offline',
        );
        response.complete(remote);
        await clients.last.closed.future;
        expect(model.devices.single.online, isTrue);
        expect(clients.last.synchronizeCalls, 0);
        expect(model.media, hasLength(1));
        expect(model.error, isNull);
      },
    );

    for (final failure in ['connection', 'timeout', 'different device']) {
      test(
        '$failure marks the remembered device offline and retains its cache',
        () async {
          identity = (_, _) async {
            if (failure == 'connection') throw const SocketException('offline');
            if (failure == 'timeout') {
              throw TimeoutException('identity timed out');
            }
            return const Peer(
              id: 'different',
              name: 'C手机',
              host: '192.168.1.8',
              port: 50728,
            );
          };
          await lost();
          await clients.last.closed.future;
          expect(model.devices.single.online, isFalse);
          expect(model.devices.single.id, remote.id);
          expect(model.media.single.deviceId, remote.id);
          expect((await db.listPeers()).single.id, remote.id);
          expect(clients.last.synchronizeCalls, 0);
          expect(model.error, isNull);
        },
      );
    }

    test(
      'a silent identity request is bounded and its client is closed',
      () async {
        final response = Completer<Peer>();
        identity = (_, _) => response.future;
        await lost();
        expect(model.devices.single.online, isTrue);
        await clients.last.closed.future.timeout(const Duration(seconds: 10));
        expect(model.devices.single.online, isFalse);
        expect(clients.last.synchronizeCalls, 0);
        response.complete(remote);
      },
    );

    test(
      'rediscovery invalidates an old failed probe before new sync completes',
      () async {
        final oldProbe = Completer<Peer>();
        final rediscovered = Completer<Peer>();
        identity = (_, index) =>
            index == 1 ? oldProbe.future : rediscovered.future;
        await lost();
        bridge.events.add({
          'type': 'found',
          'id': remote.id,
          'name': '旅行手机',
          'host': '192.168.1.9',
          'port': remote.port,
        });
        await Future<void>.delayed(Duration.zero);
        expect(clients, hasLength(3));
        oldProbe.completeError(const SocketException('old address vanished'));
        await clients[1].closed.future;
        expect(model.devices.single.online, isTrue);
        rediscovered.complete(
          remote.copyWith(host: '192.168.1.9', name: '旅行手机'),
        );
        await clients[2].closed.future;
        expect(model.devices.single.online, isTrue);
        expect(model.devices.single.address, '192.168.1.9:${remote.port}');
      },
    );

    test(
      'an old successful probe cannot revive a newer failed connection',
      () async {
        final oldProbe = Completer<Peer>();
        identity = (_, index) async {
          if (index == 1) return oldProbe.future;
          throw const SocketException('new connection is offline');
        };
        await lost();
        bridge.events.add({
          'type': 'found',
          'id': remote.id,
          'name': remote.name,
          'host': remote.host,
          'port': remote.port,
        });
        await Future<void>.delayed(Duration.zero);
        expect(clients, hasLength(3));
        await clients[2].closed.future;
        expect(model.devices.single.online, isFalse);
        oldProbe.complete(remote);
        await clients[1].closed.future;
        expect(model.devices.single.online, isFalse);
      },
    );

    test(
      'manual connection invalidates an older failed discovery probe',
      () async {
        final oldProbe = Completer<Peer>();
        identity = (peer, index) async {
          if (index == 1) return oldProbe.future;
          return remote.copyWith(host: peer.host);
        };
        await lost();
        await model.connect('192.168.1.9:${remote.port}');
        expect(model.devices.single.address, '192.168.1.9:${remote.port}');
        oldProbe.completeError(const SocketException('old address vanished'));
        await clients[1].closed.future;
        expect(model.devices.single.online, isTrue);
      },
    );

    test(
      'successful catalog sync invalidates an earlier presence probe',
      () async {
        final syncing = Completer<void>();
        final catalog = Completer<Peer>();
        final oldProbe = Completer<Peer>();
        var identityCalls = 0;
        identity = (_, index) async {
          if (index == 2) return oldProbe.future;
          if (++identityCalls == 1) return remote;
          if (!syncing.isCompleted) syncing.complete();
          return catalog.future;
        };
        final refreshing = model.refresh();
        await syncing.future;
        await lost();
        expect(clients, hasLength(3));
        catalog.complete(remote);
        await refreshing;
        oldProbe.completeError(const SocketException('stale probe failed'));
        await clients[2].closed.future;
        expect(model.devices.single.online, isTrue);
      },
    );

    test(
      'catalog transport failure is confirmed by a separate identity probe',
      () async {
        var identityCalls = 0;
        identity = (_, index) async {
          if (index == 1 && ++identityCalls == 1) return remote;
          throw const SocketException('device disconnected during sync');
        };
        await model.refresh();
        expect(clients, hasLength(3));
        expect(clients[2].synchronizeCalls, 0);
        expect(model.devices.single.online, isFalse);
        expect(model.media, hasLength(1));
      },
    );

    test('late probes cannot change state after shutdown', () async {
      final oldProbe = Completer<Peer>();
      identity = (_, _) => oldProbe.future;
      await lost();
      await model.shutdown();
      expect(clients.last.closed.isCompleted, isTrue);
      final online = model.devices.single.online;
      var notifications = 0;
      model.addListener(() => ++notifications);
      oldProbe.complete(remote);
      await clients.last.closed.future;
      await Future<void>.delayed(Duration.zero);
      expect(model.devices.single.online, online);
      expect(notifications, 0);
      expect(clients.last.closeCalls, 1);
    });

    test(
      'late probes cannot restore presence while background sharing is off',
      () async {
        final oldProbe = Completer<Peer>();
        identity = (_, _) => oldProbe.future;
        await lost();
        model.setForeground(false);
        // refresh serializes with the lifecycle reconciliation and is harmless
        // while the network is intentionally suspended.
        await model.refresh();
        expect(model.devices.single.online, isFalse);
        expect(clients.last.closed.isCompleted, isTrue);
        oldProbe.complete(remote);
        await clients.last.closed.future;
        await Future<void>.delayed(Duration.zero);
        expect(model.devices.single.online, isFalse);
        expect(model.port, 0);
        expect(clients.last.closeCalls, 1);
      },
    );

    test(
      'stopping catalog sync closes traffic and old cleanup cannot affect a restart',
      () async {
        final oldSync = Completer<SyncResult>();
        final newSync = Completer<SyncResult>();
        final oldEntered = Completer<void>();
        final newEntered = Completer<void>();
        synchronization = (_, index) {
          if (index == 1) {
            oldEntered.complete();
            return oldSync.future;
          }
          newEntered.complete();
          return newSync.future;
        };
        SyncResult result(String name) => SyncResult(
          peer: remote.copyWith(name: name),
          revision: 'test',
          totalCount: 1,
          addedCount: 0,
          deletedCount: 0,
          thumbnailRequests: 0,
        );
        final oldRefreshing = model.refresh();
        await oldEntered.future;
        model.setForeground(false);
        await model.refresh();
        expect(clients[1].closed.isCompleted, isTrue);
        expect(model.devices.single.online, isFalse);
        expect(model.port, 0);
        model.setForeground(true);
        final newRefreshing = model.refresh();
        await newEntered.future;
        expect(clients, hasLength(3));
        oldSync.complete(result('过期结果'));
        await oldRefreshing;
        expect(clients[1].closeCalls, 1);
        expect(clients[2].closed.isCompleted, isFalse);
        expect(model.devices.single.name, isNot('过期结果'));
        bridge.events.add({
          'type': 'found',
          'id': remote.id,
          'name': remote.name,
          'host': remote.host,
          'port': remote.port,
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          clients,
          hasLength(3),
          reason: 'old cleanup must preserve the new active sync',
        );
        newSync.complete(result('新结果'));
        await newRefreshing;
        expect(model.devices.single.name, '新结果');
        expect(model.devices.single.online, isTrue);
        expect(clients[2].closeCalls, 1);
      },
    );

    test(
      'client construction failure clears connection state for a retry',
      () async {
        factoryFailure = StateError('client construction failed');
        await model.refresh();
        expect(model.devices.single.online, isFalse);
        factoryFailure = null;
        await model.refresh();
        expect(model.devices.single.online, isTrue);
        expect(clients, hasLength(2));
        expect(clients.last.closeCalls, 1);
      },
    );
  });

  test('initial database error can recover by refreshing', () async {
    var attempts = 0;
    model = AppController(
      bridge: bridge,
      openTransfers: () async => tasks,
      openRepository: () async {
        if (attempts++ == 0) throw StateError('temporary database failure');
        return db;
      },
    );
    await model.initialize();
    expect(model.loading, false);
    expect(model.error, isNotNull);
    await model.refresh();
    expect(model.error, null);
    expect(model.port, greaterThan(0));
  });

  test(
    'different Android IDs with the same name remain separate remembered peers',
    () async {
      model = AppController(
        bridge: bridge,
        openTransfers: () async => tasks,
        openRepository: () async => db,
        clientFactory: (peer) => StubRpcClient(
          peer,
          onIdentity: () async => Peer(
            id: peer.host == '192.168.1.8'
                ? 'android-1111111111111111'
                : 'android-2222222222222222',
            name: '家里的手机',
            host: peer.host,
            port: peer.port,
          ),
        ),
      );
      await model.initialize();
      await model.connect('192.168.1.8');
      await model.connect('192.168.1.9:50728');
      expect(model.error, isNull);
      expect(model.devices, hasLength(2));
      expect(model.devices.map((device) => device.name), everyElement('家里的手机'));
      expect(model.devices.map((device) => device.id).toSet(), {
        'android-1111111111111111',
        'android-2222222222222222',
      });
      expect(await db.listPeers(), hasLength(2));
      expect(
        (await db.listPeers()).map((peer) => peer.port),
        everyElement(50728),
      );
      await model.selectDevice('android-2222222222222222');
      expect(model.media.single.deviceId, 'android-2222222222222222');
    },
  );

  test(
    'cached album pages 60/60/1 and ignores old page appends after a device filter changes',
    () async {
      const phoneA = Peer(
        id: 'phone-a',
        name: 'A手机',
        host: '192.168.1.10',
        port: 50728,
      );
      const phoneB = Peer(
        id: 'phone-b',
        name: 'B手机',
        host: '192.168.1.11',
        port: 50728,
      );
      List<MediaItem> photos(String device, int count) => List.generate(
        count,
        (index) => MediaItem(
          id: 'photo-${index.toString().padLeft(3, '0')}',
          deviceId: device,
          name: '$index.jpg',
          sharedFolderId: 'camera',
          sharedFolderName: 'Camera',
          relativePath: '$index.jpg',
          mimeType: 'image/jpeg',
          size: 3,
          modifiedMs: 100000 - index,
          thumbnail: Uint8List.fromList([index % 256]),
        ),
      );
      final photosA = photos(phoneA.id, 121);
      final photosB = photos(phoneB.id, 85);
      await db.replacePeerSnapshot(phoneA, photosA.reversed.toList());
      final gated = GatedRepository(db);
      model = AppController(
        bridge: bridge,
        openTransfers: () async => tasks,
        openRepository: () async => gated,
        clientFactory: (peer) => StubRpcClient(
          peer,
          onIdentity: () async {
            throw const SocketException('offline cached device');
          },
        ),
      );
      model.setForeground(false);
      await model.initialize();
      expect(model.media, hasLength(60));
      expect(model.hasMoreMedia, isTrue);
      await model.loadMoreMedia();
      expect(model.media, hasLength(120));
      expect(model.hasMoreMedia, isTrue);
      await model.loadMoreMedia();
      expect(model.media, hasLength(121));
      expect(model.hasMoreMedia, isFalse);
      expect(model.media.map((item) => item.key).toSet(), hasLength(121));
      expect(
        model.media.map((item) => item.id),
        orderedEquals(photosA.map((item) => item.id)),
      );
      expect(
        model.media.map((item) => item.modified.millisecondsSinceEpoch),
        orderedEquals(photosA.map((item) => item.modifiedMs)),
      );

      await db.replacePeerSnapshot(phoneB, photosB.reversed.toList());
      await model.selectDevice(phoneA.id);
      final oldPageAppending = Completer<void>();
      final releaseOldPage = Completer<void>();
      gated.beforeDownloadRead = (deviceId, mediaId) async {
        if (deviceId == phoneA.id &&
            mediaId == 'photo-060' &&
            !oldPageAppending.isCompleted) {
          oldPageAppending.complete();
          await releaseOldPage.future;
        }
      };
      final oldPage = model.loadMoreMedia();
      try {
        await oldPageAppending.future.timeout(const Duration(seconds: 3));
        expect(model.loadingMoreMedia, isTrue);
        await model.selectDevice(phoneB.id);
        expect(model.media, hasLength(60));
        expect(model.media.every((item) => item.deviceId == phoneB.id), isTrue);
      } finally {
        releaseOldPage.complete();
        await oldPage;
      }
      expect(model.selectedDeviceId, phoneB.id);
      expect(model.media, hasLength(60));
      expect(
        model.media.every((item) => item.deviceId == phoneB.id),
        isTrue,
        reason: 'Completing the old A page must not append into the B album',
      );
      await Future.wait([model.loadMoreMedia(), model.loadMoreMedia()]);
      expect(model.media, hasLength(85));
      expect(model.hasMoreMedia, isFalse);
      expect(model.media.map((item) => item.key).toSet(), hasLength(85));
      expect(
        model.media.map((item) => item.id),
        orderedEquals(photosB.map((item) => item.id)),
      );
      expect(
        model.media.map((item) => item.modified.millisecondsSinceEpoch),
        orderedEquals(photosB.map((item) => item.modifiedMs)),
      );
    },
  );

  test(
    'stale scheduled-job poll cannot fail a download awaiting scheduling',
    () async {
      const peer = Peer(
        id: 'remote',
        name: 'B手机',
        host: '192.168.1.20',
        port: 50728,
      );
      await db.replacePeerSnapshot(peer, await MemorySource().scan());
      await db.setSetting('downloadUri', 'content://downloads');
      await db.setSetting('downloadFolder', 'Tamayura');
      model = AppController(
        bridge: bridge,
        openTransfers: () async => tasks,
        openRepository: () async => db,
        clientFactory: (peer) => StubRpcClient(
          peer,
          onIdentity: () async {
            throw const SocketException('offline cached device');
          },
        ),
      );
      model.setForeground(false);
      await model.initialize();
      final photo = model.media.single;
      final pollEntered = Completer<void>();
      final staleReply = Completer<List<String>>();
      final scheduleEntered = Completer<String>();
      final releaseSchedule = Completer<void>();
      final refreshed = Completer<void>();
      bridge.queryScheduled = () async {
        if (!pollEntered.isCompleted) {
          pollEntered.complete();
          return staleReply.future;
        }
        return bridge.scheduled.toList();
      };
      bridge.schedule = (id) async {
        scheduleEntered.complete(id);
        await releaseSchedule.future;
      };
      void observeRefresh() {
        if (model.transfers.containsKey(photo.key) && !refreshed.isCompleted) {
          refreshed.complete();
        }
      }

      model.addListener(observeRefresh);
      model.setForeground(true);
      await pollEntered.future.timeout(const Duration(seconds: 3));
      model.setForeground(
        false,
      ); // Keep only the explicitly gated poll in flight.
      final downloading = model.download(photo);
      try {
        final taskId = await scheduleEntered.future.timeout(
          const Duration(seconds: 3),
        );
        expect((await tasks.get(taskId))!.state, DownloadState.queued);
        staleReply.complete([]);
        await refreshed.future.timeout(const Duration(seconds: 3));
        expect((await tasks.get(taskId))!.state, DownloadState.queued);
        expect(model.transfers[photo.key]!.status, TransferStatus.queued);
        expect(model.transfers[photo.key]!.error, isNull);
        expect(model.error, isNull);
      } finally {
        if (!staleReply.isCompleted) staleReply.complete([]);
        releaseSchedule.complete();
        await downloading;
        model.removeListener(observeRefresh);
      }
      expect(
        (await tasks.forMedia(photo.deviceId, photo.id))!.state,
        DownloadState.queued,
      );
      expect(model.transfers[photo.key]!.status, TransferStatus.queued);
    },
  );

  test(
    'offline collections include every page and filter by both device and root',
    () async {
      const peer = Peer(
        id: 'remote',
        name: '手机',
        host: '192.168.1.12',
        port: 50728,
      );
      List<MediaItem> photos(String root, int count) => List.generate(
        count,
        (index) => MediaItem(
          id: '$root-$index',
          deviceId: peer.id,
          name: '$index.jpg',
          sharedFolderId: root,
          sharedFolderName: 'Camera',
          relativePath: '层级/$index.jpg',
          mimeType: 'image/jpeg',
          size: 3,
          modifiedMs: 1000 - index,
          thumbnail: Uint8List(0),
        ),
      );
      final first = photos('first', 65), second = photos('second', 3);
      await db.replacePeerSnapshot(peer, [...first, ...second]);
      model = AppController(
        bridge: bridge,
        openRepository: () async => db,
        openTransfers: () async => tasks,
        clientFactory: (peer) => StubRpcClient(
          peer,
          onIdentity: () async {
            throw const SocketException('offline');
          },
        ),
      );
      model.setForeground(false);
      await model.initialize();
      expect(model.collections, hasLength(2));
      expect(
        model.collections.map((collection) => collection.itemCount).toSet(),
        {65, 3},
      );
      await model.selectCollection('remote/first');
      expect(model.totalMediaCount, 65);
      expect(model.media, hasLength(60));
      await model.loadMoreMedia();
      expect(model.media, hasLength(65));
      expect(
        model.media.every((item) => item.sharedFolderId == 'first'),
        isTrue,
      );
      await model.selectCollection('remote/second');
      expect(model.totalMediaCount, 3);
      expect(model.hasMoreMedia, isFalse);
      expect(
        model.media.every((item) => item.sharedFolderId == 'second'),
        isTrue,
      );
      await model.selectDevice(peer.id);
      expect(model.selectedCollectionKey, isNull);
      expect(model.collections, hasLength(2));
      await model.selectCollection('remote/first');
      await db.replacePeerSnapshot(peer, second);
      await model.selectCollection('remote/first');
      expect(model.selectedCollectionKey, isNull);
      expect(model.collections.single.sharedFolderId, 'second');
    },
  );
}
