import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart'
    show FakeBridge, GatedRepository, MemorySource, StubRpcClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // Synthetic endpoints are handled by StubRpcClient; no remote device is used.
  const first = Peer(
    id: 'device-a',
    name: 'A phone',
    host: '192.168.0.10',
    port: 51001,
  );
  const second = Peer(
    id: 'device-b',
    name: 'A phone',
    host: '192.168.0.10',
    port: 51002,
  );
  const third = Peer(
    id: 'device-c',
    name: 'C tablet',
    host: '192.168.0.10',
    port: 51003,
  );
  const defaultOrder = ['device-a', 'device-b', 'device-c'];
  const customOrder = ['device-c', 'device-a', 'device-b'];

  late Directory temporary;
  late TamayuraRepository db;
  late GatedRepository gated;
  late TransferStore tasks;
  late FakeBridge bridge;
  late AppController model;

  AppController controller() => AppController(
    bridge: bridge,
    preferredPort: 0,
    openRepository: () async => gated,
    openTransfers: () async => tasks,
  );

  List<String> deviceIds() => model.devices.map((device) => device.id).toList();

  Future<void> seedPeers() async {
    // Insert the equal-name peers in reverse order to exercise the ID tie break.
    for (final peer in [third, second, first]) {
      await db.replacePeerSnapshot(
        peer,
        await MemorySource(deviceId: peer.id).scan(),
      );
    }
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tamayura-device-order-');
    db = await TamayuraRepository.open(
      path: '${temporary.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    gated = GatedRepository(db);
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    bridge = FakeBridge();
    model = controller();
    await model.setForeground(false);
    await seedPeers();
  });

  tearDown(() async {
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test(
    'default device order uses names and stable IDs for equal names',
    () async {
      await model.initialize();

      expect(deviceIds(), defaultOrder);
      expect(model.deviceOrderSaving, isFalse);
      expect(model.error, isNull);
      expect(await db.getSetting('deviceOrder'), isNull);
    },
  );

  test('saved order ignores stale IDs and repeated IDs', () async {
    await db.setSetting(
      'deviceOrder',
      jsonEncode(['device-c', 'removed-device', 'device-a', 'device-c']),
    );
    await model.initialize();

    expect(deviceIds(), customOrder);
    expect(model.error, isNull);
  });

  for (final invalid in [
    '',
    'invalid-json',
    '{}',
    'null',
    '"device-c"',
    '["device-c", 42]',
    '["device-c", null]',
    '["device-c", ""]',
  ]) {
    test('invalid device order $invalid keeps initialization usable', () async {
      await db.setSetting('deviceOrder', invalid);
      await model.initialize();

      expect(model.loading, isFalse);
      expect(model.error, isNull);
      expect(deviceIds(), defaultOrder);
      expect(await model.reorderDevices(customOrder), isTrue);
      expect(deviceIds(), customOrder);
    });
  }

  test(
    'saving normalizes IDs and preserves the active album selection',
    () async {
      await model.initialize();
      await model.selectDevice(first.id);
      await model.selectCollection('${first.id}/camera');
      final mediaKeys = model.media.map((item) => item.key).toList();

      expect(
        await model.reorderDevices([
          third.id,
          'removed-device',
          third.id,
          first.id,
        ]),
        isTrue,
      );

      expect(deviceIds(), customOrder);
      expect(jsonDecode((await db.getSetting('deviceOrder'))!), customOrder);
      expect(model.selectedDeviceId, first.id);
      expect(model.selectedCollectionKey, '${first.id}/camera');
      expect(model.media.map((item) => item.key), mediaKeys);
      expect(model.deviceOrderSaving, isFalse);
      expect(model.error, isNull);
    },
  );

  test('saved order survives closing and reopening both stores', () async {
    await model.initialize();
    expect(await model.reorderDevices(customOrder), isTrue);
    await model.shutdown();

    db = await TamayuraRepository.open(
      path: '${temporary.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    gated = GatedRepository(db);
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    model = controller();
    await model.setForeground(false);
    await model.initialize();

    expect(deviceIds(), customOrder);
    expect(model.error, isNull);
  });

  test('write failure retains the saved order and allows a retry', () async {
    await db.setSetting('deviceOrder', jsonEncode(customOrder));
    await model.initialize();
    gated.beforeSettingWrite = (key, value) async {
      if (key == 'deviceOrder') throw StateError('disk write failed');
    };

    expect(await model.reorderDevices(defaultOrder), isFalse);
    expect(deviceIds(), customOrder);
    expect(jsonDecode((await db.getSetting('deviceOrder'))!), customOrder);
    expect(model.deviceOrderSaving, isFalse);
    expect(model.error, '设备顺序保存失败，请重试');

    gated.beforeSettingWrite = null;
    expect(await model.reorderDevices(defaultOrder), isTrue);
    expect(deviceIds(), defaultOrder);
    expect(jsonDecode((await db.getSetting('deviceOrder'))!), defaultOrder);
    expect(model.error, isNull);
  });

  test(
    'pending save publishes only durable order and rejects overlap',
    () async {
      await model.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      final observed = <(List<String>, bool)>[];
      var writes = 0;
      gated.beforeSettingWrite = (key, value) async {
        if (key != 'deviceOrder') return;
        writes++;
        entered.complete();
        await release.future;
      };
      model.addListener(() {
        observed.add((deviceIds(), model.deviceOrderSaving));
      });

      final saving = model.reorderDevices(customOrder);
      try {
        await entered.future;
        expect(deviceIds(), defaultOrder);
        expect(await db.getSetting('deviceOrder'), isNull);
        expect(model.deviceOrderSaving, isTrue);
        expect(model.busy, isFalse);
        expect(await model.reorderDevices(['device-b', 'device-a']), isFalse);
        expect(writes, 1);
      } finally {
        release.complete();
        expect(await saving, isTrue);
      }

      expect(deviceIds(), customOrder);
      expect(jsonDecode((await db.getSetting('deviceOrder'))!), customOrder);
      expect(model.deviceOrderSaving, isFalse);
      expect(
        observed.any((state) => state.$2 && state.$1.first == 'device-a'),
        isTrue,
      );
      expect(observed.last.$1, customOrder);
      expect(observed.last.$2, isFalse);
    },
  );

  test('saving before initialization fails clearly and can recover', () async {
    expect(await model.reorderDevices(customOrder), isFalse);
    expect(model.error, contains('尚未完成初始化'));
    expect(model.deviceOrderSaving, isFalse);
    expect(await db.getSetting('deviceOrder'), isNull);

    await model.initialize();
    expect(await model.reorderDevices(customOrder), isTrue);
    expect(deviceIds(), customOrder);
    expect(model.error, isNull);
  });

  test(
    'a late save completion after shutdown does not publish state',
    () async {
      await model.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      var notifications = 0;
      model.addListener(() => notifications++);
      gated.beforeSettingWrite = (key, value) async {
        if (key != 'deviceOrder') return;
        entered.complete();
        await release.future;
      };

      final saving = model.reorderDevices(customOrder);
      try {
        await entered.future;
        await model.shutdown();
        final countAtShutdown = notifications;
        release.complete();

        expect(await saving, isFalse);
        expect(deviceIds(), defaultOrder);
        expect(model.deviceOrderSaving, isFalse);
        expect(model.error, isNull);
        expect(notifications, countAtShutdown);
        expect(await model.reorderDevices(customOrder), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await saving;
      }
    },
  );

  test(
    'renaming, reconnecting and discovering devices preserve custom order',
    () async {
      final identities = <int, Peer>{
        first.port: first,
        second.port: second,
        third.port: third,
      };
      Completer<StubRpcClient>? nextClient;
      model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => db,
        openTransfers: () async => tasks,
        clientFactory: (candidate) {
          final client = StubRpcClient(
            candidate,
            onIdentity: () async => identities[candidate.port]!,
          );
          final waiting = nextClient;
          if (waiting != null && !waiting.isCompleted) waiting.complete(client);
          return client;
        },
      );
      await model.initialize();
      expect(await model.reorderDevices(customOrder), isTrue);

      identities[first.port] = first.copyWith(name: 'Z renamed phone');
      await model.connect('${first.host}:${first.port}');
      expect(deviceIds(), customOrder);
      expect(model.devices[1].name, 'Z renamed phone');
      await model.connect('${third.host}:${third.port}');
      expect(deviceIds(), customOrder);

      const discovered = Peer(
        id: 'device-d',
        name: '0 newly discovered phone',
        host: '192.168.0.10',
        port: 51004,
      );
      identities[discovered.port] = discovered;
      nextClient = Completer<StubRpcClient>();
      bridge.events.add({
        'type': 'found',
        'id': discovered.id,
        'name': discovered.name,
        'host': discovered.host,
        'port': discovered.port,
      });
      final discoveryClient = await nextClient.future.timeout(
        const Duration(seconds: 5),
      );
      await discoveryClient.closed.future.timeout(const Duration(seconds: 5));

      expect(deviceIds(), [...customOrder, discovered.id]);
      // A dialog opened before discovery still includes the new device on save.
      expect(
        await model.reorderDevices(['device-b', 'device-c', 'device-a']),
        isTrue,
      );
      expect(deviceIds(), ['device-b', 'device-c', 'device-a', discovered.id]);
      expect(jsonDecode((await db.getSetting('deviceOrder'))!), [
        'device-b',
        'device-c',
        'device-a',
        discovered.id,
      ]);
      expect(model.error, isNull);
    },
  );
}
