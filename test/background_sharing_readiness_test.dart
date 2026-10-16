import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/android_bridge.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository;

/// Models the native service's contract: foreground-service acceptance grants a
/// session, but the original enable call waits for Dart's readiness report.
class ReadinessBridge extends FakeBridge {
  SharingStatus status = const SharingStatus(
    enabled: true,
    starting: true,
    running: false,
    batteryExempt: true,
    sessionId: 'restored',
  );
  final changes = StreamController<SharingStatus>.broadcast(sync: true);
  final readyRequests = <String>[];
  final failures = <({String sessionId, String error})>[];
  final pendingStarts = <String, Completer<SharingStatus>>{};
  Future<void> Function()? beforeIdentity;
  Future<void> Function()? beforeScan;
  Future<void> Function()? beforeDiscovery;
  Future<void> Function(String)? beforeReady;
  var nextSession = 0, discoveryStarts = 0;

  @override
  Stream<SharingStatus> get sharingEvents => changes.stream;

  @override
  Future<SharingStatus> sharingStatus() async => status;

  void emit(SharingStatus value) {
    status = value;
    changes.add(value);
  }

  void startSession(String sessionId) {
    emit(
      SharingStatus(
        enabled: true,
        starting: true,
        running: false,
        batteryExempt: true,
        sessionId: sessionId,
      ),
    );
  }

  @override
  Future<SharingStatus> setBackgroundSharing(bool enabled) async {
    if (!enabled) {
      emit(
        const SharingStatus(
          enabled: false,
          running: false,
          batteryExempt: true,
        ),
      );
      for (final pending in pendingStarts.values) {
        if (!pending.isCompleted) pending.complete(status);
      }
      return status;
    }
    final sessionId = 'retry-${++nextSession}';
    final pending = Completer<SharingStatus>();
    pendingStarts[sessionId] = pending;
    startSession(sessionId);
    return pending.future;
  }

  @override
  Future<bool> reportSharingReady(String sessionId) async {
    readyRequests.add(sessionId);
    if (status.sessionId != sessionId || !status.enabled) return false;
    await beforeReady?.call(sessionId);
    if (status.sessionId != sessionId || !status.enabled) return false;
    emit(
      SharingStatus(
        enabled: true,
        running: true,
        batteryExempt: true,
        sessionId: sessionId,
      ),
    );
    final pending = pendingStarts[sessionId];
    if (pending != null && !pending.isCompleted) pending.complete(status);
    return true;
  }

  @override
  Future<bool> reportSharingFailure(String sessionId, String error) async {
    failures.add((sessionId: sessionId, error: error));
    if (status.sessionId != sessionId || !status.enabled) return false;
    emit(
      SharingStatus(
        enabled: true,
        running: false,
        batteryExempt: true,
        error: error,
      ),
    );
    final pending = pendingStarts[sessionId];
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        PlatformException(code: 'SHARING_FAILED', message: error),
      );
    }
    return true;
  }

  @override
  Future<String> deviceId() async {
    await beforeIdentity?.call();
    return super.deviceId();
  }

  @override
  Future<List<Map<String, dynamic>>> scanDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    await beforeScan?.call();
    return super.scanDirectoriesMetadata(directories);
  }

  @override
  Future<void> startDiscovery({
    required String id,
    required String name,
    required int port,
  }) async {
    discoveryStarts++;
    await beforeDiscovery?.call();
    await super.startDiscovery(id: id, name: name, port: port);
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List.fromList([1, 2, 3].sublist(offset, offset + length));
}

class ReadinessRepository extends GatedRepository {
  ReadinessRepository(super.inner);
  Future<void> Function(String)? beforeSettingRead;
  Future<String?> Function(String)? settingRead;
  Future<List<MediaCollection>> Function(String?)? collectionRead;

  @override
  Future<String?> getSetting(String key) async {
    if (settingRead != null) return settingRead!(key);
    await beforeSettingRead?.call(key);
    return super.getSetting(key);
  }

  @override
  Future<List<MediaCollection>> mediaCollections({String? deviceId}) =>
      collectionRead?.call(deviceId) ??
      super.mediaCollections(deviceId: deviceId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late ReadinessBridge bridge;
  late AppController model;
  late ReadinessRepository repository;
  late TransferStore transfers;
  Future<void> Function()? beforeRepository;

  setUp(() async {
    beforeRepository = null;
    bridge = ReadinessBridge();
    repository = ReadinessRepository(
      await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      ),
    );
    transfers = await TransferStore.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    await repository.setSetting(
      'sharedFolders',
      jsonEncode([
        const SharedFolder(
          id: 'photos',
          uri: 'content://photos',
          name: '相册',
        ).toJson(),
      ]),
    );
    model = AppController(
      bridge: bridge,
      preferredPort: 0,
      openRepository: () async {
        await beforeRepository?.call();
        return repository;
      },
      openTransfers: () async => transfers,
    );
    await model.setForeground(false);
  });

  tearDown(() async {
    await model.shutdown();
    await repository.close();
    await transfers.close();
    await bridge.changes.close();
    await bridge.events.close();
  });

  Future<void> until(bool Function() predicate) async {
    if (predicate()) return;
    final done = Completer<void>();
    void changed() {
      if (predicate() && !done.isCompleted) done.complete();
    }

    model.addListener(changed);
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      model.removeListener(changed);
    }
  }

  Future<void> expectUsableCatalog() async {
    expect(model.port, greaterThan(0));
    final client = MediaRpcClient(
      Peer(
        id: FakeBridge.identity,
        name: '手机',
        host: '127.0.0.1',
        port: model.port,
      ),
    );
    try {
      expect((await client.identity()).id, FakeBridge.identity);
      final media = await client.listMedia();
      expect(media.single.id, 'local-photos');
      expect(media.single.sharedFolderName, '相册');
      expect(
        await client
            .readRange(media.single.id, 0, 3)
            .expand((bytes) => bytes)
            .toList(),
        [1, 2, 3],
      );
    } finally {
      await client.close();
    }
  }

  test(
    'restored service remains starting until initialization and scan finish',
    () async {
      final identityEntered = Completer<void>();
      final identityRelease = Completer<void>();
      final scanEntered = Completer<void>();
      final scanRelease = Completer<void>();
      bridge.beforeIdentity = () async {
        identityEntered.complete();
        await identityRelease.future;
      };
      bridge.beforeScan = () async {
        if (!scanEntered.isCompleted) scanEntered.complete();
        await scanRelease.future;
      };
      bridge.beforeReady = (_) async {
        expect(model.backgroundSharingRunning, isFalse);
        await expectUsableCatalog();
      };
      final initializing = model.initialize();
      try {
        await identityEntered.future;
        expect(model.backgroundSharingStarting, isTrue);
        expect(model.backgroundSharingRunning, isFalse);
        expect(bridge.readyRequests, isEmpty);
        expect(model.port, 0);
        identityRelease.complete();
        await scanEntered.future;
        expect(model.backgroundSharingStarting, isTrue);
        expect(model.backgroundSharingRunning, isFalse);
        expect(bridge.readyRequests, isEmpty);
        scanRelease.complete();
        await initializing;
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['restored']);
        expect(bridge.failures, isEmpty);
        expect(model.backgroundSharingStarting, isFalse);
      } finally {
        if (!identityRelease.isCompleted) identityRelease.complete();
        if (!scanRelease.isCompleted) scanRelease.complete();
        await initializing;
      }
    },
  );

  test(
    'identity failure reports the restored session and permits a retry',
    () async {
      bridge.identityFails = true;
      await model.initialize();
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.sessionId, 'restored');
      expect(bridge.failures.single.error, contains('无法读取设备标识'));
      expect(model.backgroundSharingEnabled, isTrue);
      expect(model.backgroundSharingRunning, isFalse);
      expect(model.backgroundSharingStarting, isFalse);
      expect(model.backgroundSharingError, contains('无法读取设备标识'));
      expect(model.port, 0);
      bridge.identityFails = false;
      await model.setBackgroundSharing(true);
      await until(() => model.backgroundSharingRunning);
      expect(bridge.readyRequests, ['retry-1']);
      expect(model.backgroundSharingError, isNull);
      await expectUsableCatalog();
    },
  );

  test(
    'database open failure can recover without restarting the engine',
    () async {
      beforeRepository = () async => throw StateError('数据库暂时不可用');
      await model.initialize();
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.error, contains('数据库暂时不可用'));
      expect(model.backgroundSharingRunning, isFalse);
      beforeRepository = null;
      await model.setBackgroundSharing(true);
      await until(() => model.backgroundSharingRunning);
      expect(bridge.readyRequests, ['retry-1']);
      await expectUsableCatalog();
    },
  );

  test(
    'failure after opening the database replays incomplete initialization',
    () async {
      repository.beforeSettingRead = (key) async {
        if (key == 'sharedFolders') throw StateError('共享目录配置读取失败');
      };
      await model.initialize();
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.error, contains('共享目录配置读取失败'));
      expect(model.port, 0);
      repository.beforeSettingRead = null;
      await model.setBackgroundSharing(true);
      await until(() => model.backgroundSharingRunning);
      expect(bridge.readyRequests, ['retry-1']);
      await expectUsableCatalog();
    },
  );

  test(
    'failed catalog scan is not ready merely because gRPC has bound a port',
    () async {
      bridge.scanFails = true;
      await model.initialize();
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.sessionId, 'restored');
      expect(bridge.failures.single.error, contains('请重新授权共享目录'));
      await until(() => model.port == 0);
      expect(model.backgroundSharingEnabled, isTrue);
      expect(model.backgroundSharingRunning, isFalse);
      expect(model.backgroundSharingError, contains('请重新授权共享目录'));
      bridge.scanFails = false;
      await model.setBackgroundSharing(true);
      await until(() => model.backgroundSharingRunning);
      expect(bridge.readyRequests, ['retry-1']);
      expect(model.backgroundSharingError, isNull);
      await expectUsableCatalog();
    },
  );

  test(
    'a new native session automatically retries an earlier initialization failure',
    () async {
      bridge.identityFails = true;
      await model.initialize();
      expect(bridge.failures.single.sessionId, 'restored');
      bridge.identityFails = false;
      bridge.startSession('resumed');
      await until(() => model.backgroundSharingRunning);
      expect(bridge.readyRequests, ['resumed']);
      await expectUsableCatalog();
    },
  );

  test(
    'foreground retry reinitializes discovery before acknowledging an existing gRPC server',
    () async {
      await model.setForeground(true);
      bridge.beforeDiscovery = () async => throw StateError('mDNS 启动失败');
      await model.initialize();
      expect(model.port, greaterThan(0));
      expect(bridge.discoveryStarts, 1);
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.error, contains('mDNS 启动失败'));
      expect(model.backgroundSharingRunning, isFalse);

      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeDiscovery = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final retrying = model.setBackgroundSharing(true);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        expect(bridge.discoveryStarts, 2);
        expect(bridge.readyRequests, isEmpty);
        expect(model.backgroundSharingStarting, isTrue);
        expect(model.backgroundSharingRunning, isFalse);
        release.complete();
        await retrying;
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['retry-1']);
        expect(model.backgroundSharingError, isNull);
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await retrying;
      }
    },
  );

  test(
    'foreground scan failure is rescanned before retrying an existing listener',
    () async {
      await model.setForeground(true);
      bridge.scanFails = true;
      await model.initialize();
      expect(model.port, greaterThan(0));
      expect(bridge.scans, hasLength(1));
      expect(bridge.readyRequests, isEmpty);
      expect(bridge.failures.single.error, contains('请重新授权共享目录'));
      expect(model.backgroundSharingRunning, isFalse);
      bridge.scanFails = false;

      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeScan = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      bridge.beforeReady = (_) async {
        expect(bridge.scans, hasLength(2));
        expect(bridge.discoveryStarts, 2);
        await expectUsableCatalog();
      };
      final retrying = model.setBackgroundSharing(true);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        expect(bridge.readyRequests, isEmpty);
        expect(model.backgroundSharingStarting, isTrue);
        expect(model.backgroundSharingRunning, isFalse);
        release.complete();
        await retrying;
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['retry-1']);
        expect(model.backgroundSharingError, isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await retrying;
      }
    },
  );

  test(
    'native timeout releases a hung initialization and allows retry before the old call returns',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var identityCalls = 0;
      bridge.beforeIdentity = () async {
        if (++identityCalls != 1) return;
        entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        expect(model.loading, isTrue);
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        expect(model.backgroundSharingError, contains('启动超时'));
        await until(() => !model.loading);
        expect(model.busy, isFalse);
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        await model
            .setBackgroundSharing(true)
            .timeout(const Duration(seconds: 5));
        await until(() => model.backgroundSharingRunning);
        expect(release.isCompleted, isFalse);
        expect(identityCalls, 2);
        expect(bridge.readyRequests, ['retry-1']);
        expect(model.backgroundSharingError, isNull);
        await expectUsableCatalog();

        release.complete();
        await initializing;
        await Future<void>.delayed(Duration.zero);
        expect(bridge.readyRequests, ['retry-1']);
        expect(bridge.failures, isEmpty);
        expect(bridge.status.sessionId, 'retry-1');
        expect(model.backgroundSharingRunning, isTrue);
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'turning off while startup is blocked prevents a late ready report',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeScan = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        final stopping = model.setBackgroundSharing(false);
        await until(() => !model.backgroundSharingEnabled);
        expect(bridge.status.enabled, isFalse);
        release.complete();
        await initializing;
        await stopping;
        expect(model.port, 0);
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        expect(model.backgroundSharingRunning, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'a timed out scan can remain blocked while a new session becomes ready',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var scanCalls = 0;
      bridge.beforeScan = () async {
        if (++scanCalls != 1) return;
        entered.complete();
        await release.future;
        throw StateError('旧扫描迟到失败');
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        await until(() => !model.loading && !model.busy);
        await model
            .setBackgroundSharing(true)
            .timeout(const Duration(seconds: 5));
        await until(() => model.backgroundSharingRunning);
        expect(release.isCompleted, isFalse);
        expect(scanCalls, 2);
        expect(bridge.readyRequests, ['retry-1']);
        final readyPort = model.port;
        await expectUsableCatalog();

        release.complete();
        await initializing;
        await Future<void>.delayed(Duration.zero);
        expect(model.port, readyPort);
        expect(model.backgroundSharingRunning, isTrue);
        expect(model.backgroundSharingError, isNull);
        expect(bridge.readyRequests, ['retry-1']);
        expect(bridge.failures, isEmpty);
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'foreground cancellation continues ordinary initialization without waiting for the old identity call',
    () async {
      await model.setForeground(true);
      final entered = Completer<void>();
      final release = Completer<void>();
      var identityCalls = 0;
      bridge.beforeIdentity = () async {
        if (++identityCalls != 1) return;
        entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        await model.setBackgroundSharing(false);
        await until(() => !model.loading && model.port > 0);
        expect(release.isCompleted, isFalse);
        expect(identityCalls, 2);
        expect(model.backgroundSharingEnabled, isFalse);
        expect(model.backgroundSharingRunning, isFalse);
        expect(model.backgroundSharingStarting, isFalse);
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        await expectUsableCatalog();

        release.complete();
        await initializing;
        await Future<void>.delayed(Duration.zero);
        expect(model.backgroundSharingEnabled, isFalse);
        expect(model.backgroundSharingError, isNull);
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'a timed out settings read cannot overwrite the settings loaded by a retry',
    () async {
      await repository.setSetting('themeMode', 'light');
      final entered = Completer<void>();
      final release = Completer<void>();
      var themeReads = 0;
      repository.settingRead = (key) async {
        final result = await repository.inner.getSetting(key);
        if (key == 'themeMode' && ++themeReads == 1) {
          entered.complete();
          await release.future;
        }
        return result;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        await until(() => !model.loading && !model.busy);
        await repository.setSetting('themeMode', 'dark');
        await model
            .setBackgroundSharing(true)
            .timeout(const Duration(seconds: 5));
        await until(() => model.backgroundSharingRunning);
        expect(release.isCompleted, isFalse);
        expect(model.themeMode, ThemeMode.dark);
        await expectUsableCatalog();

        release.complete();
        await initializing;
        await Future<void>.delayed(Duration.zero);
        expect(model.themeMode, ThemeMode.dark);
        expect(model.backgroundSharingRunning, isTrue);
        expect(model.backgroundSharingError, isNull);
        expect(bridge.readyRequests, ['retry-1']);
        expect(bridge.failures, isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'a timed out cache read cannot replace the media collections loaded by a retry',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var collectionReads = 0;
      repository.collectionRead = (deviceId) async {
        if (++collectionReads == 1) {
          entered.complete();
          await release.future;
          return [
            MediaCollection(
              deviceId: 'stale-device',
              sharedFolderId: 'stale-folder',
              sharedFolderName: '过期读取结果',
              itemCount: 1,
              thumbnail: Uint8List(0),
            ),
          ];
        }
        return repository.inner.mediaCollections(deviceId: deviceId);
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        await until(() => !model.loading && !model.busy);
        await model
            .setBackgroundSharing(true)
            .timeout(const Duration(seconds: 5));
        await until(() => model.backgroundSharingRunning);
        expect(release.isCompleted, isFalse);
        expect(collectionReads, 2);
        expect(model.collections, isEmpty);
        await expectUsableCatalog();

        release.complete();
        await initializing;
        await Future<void>.delayed(Duration.zero);
        expect(model.collections, isEmpty);
        expect(model.backgroundSharingRunning, isTrue);
        expect(model.backgroundSharingError, isNull);
        expect(bridge.readyRequests, ['retry-1']);
        expect(bridge.failures, isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'retry shares a pending database open instead of opening a second connection',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var repositoryOpens = 0;
      beforeRepository = () async {
        repositoryOpens++;
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      Future<void>? retrying;
      try {
        await entered.future;
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        await until(() => !model.loading && !model.busy);
        retrying = model.setBackgroundSharing(true);
        await until(
          () => model.loading && bridge.status.sessionId == 'retry-1',
        );
        await Future<void>.delayed(Duration.zero);
        expect(repositoryOpens, 1);
        expect(bridge.readyRequests, isEmpty);
        release.complete();
        await retrying.timeout(const Duration(seconds: 5));
        await until(() => model.backgroundSharingRunning);
        expect(repositoryOpens, 1);
        expect(bridge.readyRequests, ['retry-1']);
        expect(bridge.failures, isEmpty);
        expect(model.backgroundSharingError, isNull);
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
        await retrying;
      }
    },
  );

  test(
    'a replaced startup session cannot acknowledge its late completion',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeScan = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.startSession('replacement');
        release.complete();
        await initializing;
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['replacement']);
        expect(bridge.failures, isEmpty);
        expect(bridge.status.sessionId, 'replacement');
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'an old initialization failure cannot fail a replacement session',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var identityCalls = 0;
      bridge.beforeIdentity = () async {
        if (++identityCalls != 1) return;
        entered.complete();
        await release.future;
        throw StateError('旧启动已失败');
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.startSession('replacement');
        release.complete();
        await initializing;
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['replacement']);
        expect(bridge.failures, isEmpty);
        expect(model.backgroundSharingError, isNull);
        expect(bridge.status.sessionId, 'replacement');
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  test(
    'native startup timeout prevents a delayed scan from reporting ready',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeScan = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final initializing = model.initialize();
      try {
        await entered.future;
        bridge.emit(
          const SharingStatus(
            enabled: true,
            running: false,
            batteryExempt: true,
            error: '后台共享启动超时，请重试',
          ),
        );
        release.complete();
        await initializing;
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        expect(model.port, 0);
        expect(model.backgroundSharingEnabled, isTrue);
        expect(model.backgroundSharingRunning, isFalse);
        expect(model.backgroundSharingStarting, isFalse);
        expect(model.backgroundSharingError, contains('启动超时'));
        await model.setBackgroundSharing(true);
        await until(() => model.backgroundSharingRunning);
        expect(bridge.readyRequests, ['retry-1']);
        await expectUsableCatalog();
      } finally {
        if (!release.isCompleted) release.complete();
        await initializing;
      }
    },
  );

  for (final starting in [false, true]) {
    test(
      'enabled preference with starting=$starting but no accepted session does not serve headlessly',
      () async {
        bridge.status = SharingStatus(
          enabled: true,
          running: false,
          starting: starting,
          batteryExempt: true,
        );
        await model.initialize();
        expect(model.port, 0);
        expect(bridge.readyRequests, isEmpty);
        expect(bridge.failures, isEmpty);
        expect(model.backgroundSharingRunning, isFalse);
      },
    );
  }
}
