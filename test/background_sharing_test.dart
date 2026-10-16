import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/platform/android_bridge.dart';

import 'controller_test.dart' show FakeBridge;

class SharingBridge extends FakeBridge {
  SharingStatus status = const SharingStatus(
    enabled: false,
    running: false,
    batteryExempt: true,
  );
  final changes = StreamController<SharingStatus>.broadcast(sync: true);
  Future<void> Function()? beforeInfo;
  Future<void> Function()? beforeToggle;
  Future<SharingStatus> Function()? readStatus;
  bool rejectToggle = false;
  bool rejectSettings = false;
  int toggles = 0, batterySettingsOpened = 0, advertisements = 0, stops = 0;

  @override
  Stream<SharingStatus> get sharingEvents => changes.stream;
  @override
  Future<SharingStatus> sharingStatus() async =>
      readStatus == null ? status : readStatus!();
  @override
  Future<SharingStatus> setBackgroundSharing(bool enabled) async {
    toggles++;
    await beforeToggle?.call();
    if (rejectToggle) {
      throw PlatformException(code: 'SHARING_FAILED', message: '后台共享启动失败');
    }
    emit(enabled, enabled);
    return status;
  }

  void emit(bool enabled, bool running, {bool batteryExempt = true}) {
    status = SharingStatus(
      enabled: enabled,
      running: running,
      batteryExempt: batteryExempt,
    );
    changes.add(status);
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {
    if (rejectSettings) {
      throw PlatformException(code: 'SETTINGS_FAILED', message: '无法打开电池设置');
    }
    batterySettingsOpened++;
  }

  @override
  Future<Map<String, dynamic>> localInfo() async {
    await beforeInfo?.call();
    return super.localInfo();
  }

  @override
  Future<void> startDiscovery({
    required String id,
    required String name,
    required int port,
  }) async {
    advertisements++;
    await super.startDiscovery(id: id, name: name, port: port);
  }

  @override
  Future<void> stopDiscovery() async {
    stops++;
  }

  @override
  Future<Uint8List> readRange(String id, int offset, int length) async =>
      Uint8List.fromList([1, 2, 3].sublist(offset, offset + length));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late SharingBridge bridge;
  late AppController model;
  late TamayuraRepository repository;
  late TransferStore transfers;

  setUp(() async {
    bridge = SharingBridge();
    repository = await TamayuraRepository.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
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
      openRepository: () async => repository,
      openTransfers: () async => transfers,
    );
  });

  tearDown(() async {
    await model.shutdown();
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
      await done.future.timeout(const Duration(seconds: 3));
    } finally {
      model.removeListener(changed);
    }
  }

  MediaRpcClient client() => MediaRpcClient(
    Peer(
      id: FakeBridge.identity,
      name: 'A',
      host: '127.0.0.1',
      port: model.port,
    ),
  );

  test(
    'disabled sharing closes the actual listener in background and restores it on resume',
    () async {
      await model.initialize();
      final originalPort = model.port;
      expect(originalPort, greaterThan(0));
      await model.setForeground(false);
      expect(model.port, 0);
      expect(bridge.stops, greaterThan(0));
      await expectLater(
        Socket.connect(
          '127.0.0.1',
          originalPort,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );
      await model.setForeground(true);
      final peer = client();
      try {
        expect((await peer.identity()).id, FakeBridge.identity);
      } finally {
        await peer.close();
      }
    },
  );

  test(
    'enabled sharing serves the same media catalog after the UI is backgrounded',
    () async {
      await model.initialize();
      await model.setBackgroundSharing(true);
      final servingPort = model.port;
      await model.setForeground(false);
      expect(model.backgroundSharingEnabled, isTrue);
      expect(model.backgroundSharingRunning, isTrue);
      expect(model.port, servingPort);
      final peer = client();
      try {
        expect((await peer.identity()).id, FakeBridge.identity);
        final media = await peer.listMedia();
        expect(media.single.id, 'local-photos');
        expect(media.single.sharedFolderName, '相册');
        expect(
          await peer
              .readRange(media.single.id, 0, 3)
              .expand((bytes) => bytes)
              .toList(),
          [1, 2, 3],
        );
      } finally {
        await peer.close();
      }
      await model.setBackgroundSharing(false);
      expect(model.port, 0);
      expect(model.backgroundSharingRunning, isFalse);
    },
  );

  test(
    'turning off sharing while visible preserves foreground sharing',
    () async {
      await model.initialize();
      await model.setBackgroundSharing(true);
      final servingPort = model.port;
      await model.setBackgroundSharing(false);
      expect(model.port, servingPort);
      expect(model.backgroundSharingEnabled, isFalse);
      await model.setForeground(false);
      expect(model.port, 0);
    },
  );

  test(
    'notification stop removes the listener without opening the activity',
    () async {
      await model.initialize();
      await model.setBackgroundSharing(true);
      await model.setForeground(false);
      bridge.emit(false, false);
      await until(() => model.port == 0);
      expect(model.backgroundSharingEnabled, isFalse);
      expect(bridge.stops, greaterThan(0));
    },
  );

  test(
    'a restored running service can share without a visible activity',
    () async {
      bridge.status = const SharingStatus(
        enabled: true,
        running: true,
        batteryExempt: true,
      );
      await model.setForeground(false);
      await model.initialize();
      expect(model.port, greaterThan(0));
      final peer = client();
      try {
        expect((await peer.listMedia()).single.id, 'local-photos');
      } finally {
        await peer.close();
      }
    },
  );

  test(
    'a background engine never serves merely because the preference is enabled',
    () async {
      bridge.status = const SharingStatus(
        enabled: true,
        running: false,
        batteryExempt: true,
      );
      await model.setForeground(false);
      await model.initialize();
      expect(model.port, 0);
      expect(bridge.advertisements, 0);
      bridge.emit(true, true);
      await until(() => model.port != 0);
    },
  );

  test('failed starts remain disabled and can be retried', () async {
    await model.initialize();
    bridge.rejectToggle = true;
    await model.setBackgroundSharing(true);
    expect(model.backgroundSharingEnabled, isFalse);
    expect(model.backgroundSharingSaving, isFalse);
    expect(model.error, contains('后台共享启动失败'));
    await model.setForeground(false);
    expect(model.port, 0);
    await model.setForeground(true);
    bridge.rejectToggle = false;
    await model.setBackgroundSharing(true);
    expect(model.backgroundSharingRunning, isTrue);
    expect(model.error, isNull);
  });

  test('a pending toggle prevents overlapping native commands', () async {
    await model.initialize();
    final gate = Completer<void>();
    bridge.beforeToggle = () => gate.future;
    final enabling = model.setBackgroundSharing(true);
    expect(model.backgroundSharingSaving, isTrue);
    await model.setBackgroundSharing(false);
    expect(bridge.toggles, 1);
    gate.complete();
    await enabling;
    expect(model.backgroundSharingEnabled, isTrue);
    expect(model.backgroundSharingSaving, isFalse);
  });

  test(
    'a late network start cannot reopen a listener after backgrounding',
    () async {
      await model.initialize();
      await model.setForeground(false);
      final entered = Completer<void>();
      final release = Completer<void>();
      bridge.beforeInfo = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      final resuming = model.setForeground(true);
      await entered.future;
      final backgrounding = model.setForeground(false);
      release.complete();
      await Future.wait([resuming, backgrounding]);
      expect(model.port, 0);
    },
  );

  test(
    'stale status reads cannot overwrite a notification stop event',
    () async {
      await model.initialize();
      await model.setBackgroundSharing(true);
      await model.setForeground(false);
      final oldStatus = bridge.status;
      final reply = Completer<SharingStatus>();
      final entered = Completer<void>();
      bridge.readStatus = () {
        if (!entered.isCompleted) entered.complete();
        return reply.future;
      };
      final resume = model.setForeground(true);
      await entered.future;
      bridge.emit(false, false);
      reply.complete(oldStatus);
      await resume;
      expect(model.backgroundSharingEnabled, isFalse);
      await model.setForeground(false);
      expect(model.port, 0);
    },
  );

  test(
    'battery status is refreshed after returning from settings and failures are visible',
    () async {
      bridge.status = const SharingStatus(
        enabled: false,
        running: false,
        batteryExempt: false,
      );
      await model.initialize();
      expect(model.batteryOptimizationExempt, isFalse);
      await model.openBatteryOptimizationSettings();
      expect(bridge.batterySettingsOpened, 1);
      await model.setForeground(false);
      bridge.status = const SharingStatus(
        enabled: false,
        running: false,
        batteryExempt: true,
      );
      await model.setForeground(true);
      expect(model.batteryOptimizationExempt, isTrue);
      bridge.rejectSettings = true;
      await model.openBatteryOptimizationSettings();
      expect(model.error, contains('无法打开电池设置'));
    },
  );

  test(
    'unavailable sharing state does not prevent foreground initialization',
    () async {
      bridge.readStatus = () async =>
          throw PlatformException(code: 'SHARING_FAILED', message: '共享状态不可用');
      await model.initialize();
      expect(model.loading, isFalse);
      expect(model.port, greaterThan(0));
      expect(model.error, contains('共享状态不可用'));
    },
  );
}
