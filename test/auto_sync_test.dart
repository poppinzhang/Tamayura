import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository, StubRpcClient;

Future<void> waitForAutoSync(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for synchronization');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _PeerWriteGatedRepository extends GatedRepository {
  _PeerWriteGatedRepository(super.inner);

  Future<void> Function(Peer peer)? beforePeerWrite;

  @override
  Future<void> upsertPeer(Peer peer) async {
    await beforePeerWrite?.call(peer);
    await inner.upsertPeer(peer);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const remote = Peer(
    id: 'remote',
    name: 'Remote',
    host: '10.0.0.10',
    port: 50728,
  );
  late TamayuraRepository db;
  late TransferStore tasks;
  late FakeBridge bridge;
  late AppController model;
  late Directory temporary;
  late DateTime now;
  late List<StubRpcClient> clients;
  late List<Peer> connections;
  Object? identityFailure, catalogFailure, factoryFailure;
  Peer? endpointIdentity;
  Future<void> Function()? beforeIdentity;
  Future<void> Function()? beforeCatalog;

  int syncCount([String? peerId]) => clients
      .where((client) => peerId == null || client.peer.id == peerId)
      .fold(0, (count, client) => count + client.synchronizeCalls);

  AppController controller({TamayuraRepository? repository}) => AppController(
    bridge: bridge,
    preferredPort: 0,
    openRepository: () async => repository ?? db,
    openTransfers: () async => tasks,
    clock: () => now,
    clientFactory: (candidate) {
      connections.add(candidate);
      if (factoryFailure != null) throw factoryFailure!;
      final peer =
          endpointIdentity ??
          (candidate.id.isEmpty
              ? remote.copyWith(host: candidate.host, port: candidate.port)
              : candidate);
      final client = StubRpcClient(
        candidate,
        onIdentity: () async {
          await beforeIdentity?.call();
          if (identityFailure != null) throw identityFailure!;
          if (candidate.id.isNotEmpty && candidate.id != peer.id) {
            throw const FormatException('endpoint identity changed');
          }
          return peer;
        },
        onSynchronize: () async {
          await beforeCatalog?.call();
          if (catalogFailure != null) throw catalogFailure!;
          // A catalog response can contain an old timestamp. The attempt
          // timestamp belongs to the local controller, not the remote catalog.
          await db.replacePeerSnapshot(peer, const []);
          return SyncResult(
            peer: peer,
            revision: 'test',
            totalCount: 0,
            addedCount: 0,
            deletedCount: 0,
            thumbnailRequests: 0,
          );
        },
      );
      clients.add(client);
      return client;
    },
  );

  Future<void> discover(Peer peer, {bool expectConnection = true}) async {
    final previousCount = clients.length;
    bridge.events.add({
      'type': 'found',
      'id': peer.id,
      'name': peer.name,
      'host': peer.host,
      'port': peer.port,
    });
    if (expectConnection) {
      await waitForAutoSync(() => clients.length > previousCount);
      await clients.last.closed.future;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(clients.length, previousCount);
    }
  }

  Future<DateTime?> savedAttempt([String id = 'remote']) async =>
      (await db.listPeers()).singleWhere((peer) => peer.id == id).lastSync;

  Future<DateTime?> savedSuccess([String id = 'remote']) async =>
      (await db.listPeers())
          .singleWhere((peer) => peer.id == id)
          .lastSuccessfulSync;

  setUp(() async {
    now = DateTime(2026, 10, 17, 9);
    clients = [];
    connections = [];
    identityFailure = catalogFailure = factoryFailure = null;
    endpointIdentity = null;
    beforeIdentity = null;
    beforeCatalog = null;
    temporary = await Directory.systemTemp.createTemp('tamayura-auto-sync-');
    db = await TamayuraRepository.open(
      path: '${temporary.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    tasks = await TransferStore.open(
      path: '${temporary.path}/tasks.db',
      factory: databaseFactoryFfi,
    );
    bridge = FakeBridge();
    model = controller();
  });

  tearDown(() async {
    await model.shutdown();
    await bridge.events.close();
    await temporary.delete(recursive: true);
  });

  test('automatic synchronization defaults to twelve hours', () async {
    expect(model.autoSyncIntervalHours, 12);
    await model.initialize();
    expect(model.autoSyncIntervalHours, 12);
    expect(model.autoSyncIntervalSaving, isFalse);
    expect(model.error, isNull);
  });

  for (final invalid in ['', 'unknown', '0', '-1', '8761']) {
    test('invalid saved interval "$invalid" uses twelve hours', () async {
      await db.setSetting('autoSyncIntervalHours', invalid);
      await model.initialize();
      expect(model.autoSyncIntervalHours, 12);
      expect(model.error, isNull);
    });
  }

  test(
    'configured interval persists across reopening the application',
    () async {
      await model.initialize();
      for (final hours in [1, 24, 8760]) {
        await model.setAutoSyncIntervalHours(hours);
        expect(model.autoSyncIntervalHours, hours);
        expect(await db.getSetting('autoSyncIntervalHours'), '$hours');
      }
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: '${temporary.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      model = controller();
      await model.initialize();
      expect(model.autoSyncIntervalHours, 8760);
      expect(model.error, isNull);
    },
  );

  test('invalid configuration keeps the previous saved interval', () async {
    await model.initialize();
    await model.setAutoSyncIntervalHours(24);
    for (final invalid in [0, -1, 8761]) {
      await model.setAutoSyncIntervalHours(invalid);
      expect(model.autoSyncIntervalHours, 24);
      expect(await db.getSetting('autoSyncIntervalHours'), '24');
      expect(model.autoSyncIntervalSaving, isFalse);
      expect(model.error, isNotNull);
    }
  });

  test(
    'a failed settings write retains the interval and can be retried',
    () async {
      final gated = GatedRepository(db);
      model = controller(repository: gated);
      await db.setSetting('autoSyncIntervalHours', '24');
      await model.initialize();
      gated.beforeSettingWrite = (key, value) async {
        if (key == 'autoSyncIntervalHours') throw StateError('write failed');
      };
      await model.setAutoSyncIntervalHours(6);
      expect(model.autoSyncIntervalHours, 24);
      expect(await db.getSetting('autoSyncIntervalHours'), '24');
      expect(model.autoSyncIntervalSaving, isFalse);
      expect(model.error, isNotNull);
      gated.beforeSettingWrite = null;
      await model.setAutoSyncIntervalHours(6);
      expect(model.autoSyncIntervalHours, 6);
      expect(await db.getSetting('autoSyncIntervalHours'), '6');
      expect(model.error, isNull);
    },
  );

  test(
    'a pending settings save exposes its state and avoids duplicate writes',
    () async {
      final gated = GatedRepository(db);
      model = controller(repository: gated);
      await model.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      var writes = 0;
      gated.beforeSettingWrite = (key, value) async {
        if (key != 'autoSyncIntervalHours') return;
        writes++;
        entered.complete();
        await release.future;
      };
      final saving = model.setAutoSyncIntervalHours(6);
      try {
        await entered.future;
        expect(model.autoSyncIntervalHours, 12);
        expect(model.autoSyncIntervalSaving, isTrue);
        await model.setAutoSyncIntervalHours(24);
        expect(writes, 1);
      } finally {
        release.complete();
        await saving;
      }
      expect(model.autoSyncIntervalHours, 6);
      expect(model.autoSyncIntervalSaving, isFalse);
    },
  );

  test(
    'startup and resume wait until the last attempt plus twelve hours',
    () async {
      final previous = now;
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      now = previous.add(
        const Duration(hours: 12) - const Duration(milliseconds: 1),
      );
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      now = previous.add(const Duration(hours: 12));
      await model.refreshAfterResume();
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
      expect(model.devices.single.lastSync, now);
      now = now.add(const Duration(seconds: 1));
      await model.refreshAfterResume();
      expect(syncCount(), 1);
    },
  );

  test('the saved interval controls the automatic deadline', () async {
    await db.setSetting('autoSyncIntervalHours', '24');
    final previous = now.subtract(const Duration(hours: 12));
    await db.upsertPeer(remote.copyWith(lastSync: previous));
    await model.initialize();
    expect(syncCount(), 0);
    now = previous.add(const Duration(hours: 24));
    await model.refreshAfterResume();
    expect(syncCount(), 1);
    expect(await savedAttempt(), now);
  });

  test(
    'newly discovered devices synchronize immediately and then wait',
    () async {
      await model.initialize();
      await discover(remote);
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
      now = now.add(const Duration(minutes: 1));
      await discover(remote, expectConnection: false);
      await model.refreshAfterResume();
      expect(syncCount(), 1);
    },
  );

  test('each device has its own last synchronization deadline', () async {
    final recent = now.subtract(const Duration(hours: 2));
    await db.upsertPeer(remote.copyWith(lastSync: recent));
    await db.upsertPeer(
      const Peer(
        id: 'new-device',
        name: 'New device',
        host: '10.0.0.11',
        port: 50728,
      ),
    );
    await db.upsertPeer(
      Peer(
        id: 'due-device',
        name: 'Due device',
        host: '10.0.0.12',
        port: 50728,
        lastSync: now.subtract(const Duration(hours: 13)),
      ),
    );
    await model.initialize();
    expect(syncCount('remote'), 0);
    expect(syncCount('new-device'), 1);
    expect(syncCount('due-device'), 1);
    expect(await savedAttempt(), recent);
    expect(await savedAttempt('new-device'), now);
    expect(await savedAttempt('due-device'), now);
  });

  test('manual refresh and retry ignore the deadline and reset it', () async {
    await db.upsertPeer(remote.copyWith(lastSync: now));
    await model.initialize();
    now = now.add(const Duration(minutes: 1));
    await model.refresh();
    expect(syncCount(), 1);
    expect(await savedAttempt(), now);
    now = now.add(const Duration(minutes: 1));
    await model.retrySync(remote.id);
    expect(syncCount(), 2);
    expect(await savedAttempt(), now);
    final lastManualAttempt = now;
    now = now.add(const Duration(hours: 12) - const Duration(seconds: 1));
    await model.refreshAfterResume();
    expect(syncCount(), 2);
    expect(await savedAttempt(), lastManualAttempt);
  });

  test(
    'manual connections ignore the deadline and record failed attempts',
    () async {
      await db.upsertPeer(remote.copyWith(lastSync: now));
      await model.initialize();
      now = now.add(const Duration(minutes: 1));
      await model.connect('${remote.host}:${remote.port}');
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
      now = now.add(const Duration(minutes: 1));
      identityFailure = const SocketException('offline');
      await model.connect('${remote.host}:${remote.port}');
      expect(await savedAttempt(), now);
      expect(model.error, isNotNull);
      final attempts = connections.length;
      identityFailure = null;
      await model.refreshAfterResume();
      expect(connections.length, attempts);
    },
  );

  test(
    'a shorter configured interval schedules an already due device',
    () async {
      final previous = now.subtract(const Duration(hours: 6));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      await model.setAutoSyncIntervalHours(6);
      await waitForAutoSync(() => syncCount() == 1);
      await clients.single.closed.future;
      expect(await savedAttempt(), now);
    },
  );

  test(
    'manual connection discovers a new identity at a remembered device address',
    () async {
      await db.upsertPeer(remote.copyWith(lastSync: now));
      await model.initialize();
      now = now.add(const Duration(minutes: 1));
      endpointIdentity = Peer(
        id: 'replacement-device',
        name: 'Replacement device',
        host: remote.host,
        port: remote.port,
      );
      await model.connect('${remote.host}:${remote.port}');
      expect(model.error, isNull);
      expect(syncCount(), 1);
      expect(
        model.devices.map((device) => device.id),
        unorderedEquals([remote.id, endpointIdentity!.id]),
      );
      expect(await savedAttempt(endpointIdentity!.id), now);
      expect(
        model.syncProgress
            .singleWhere((progress) => progress.peerId == endpointIdentity!.id)
            .phase,
        SyncPhase.completed,
      );
      expect(
        (await db.listPeers()).map((peer) => peer.id),
        unorderedEquals([remote.id, endpointIdentity!.id]),
      );
    },
  );

  test(
    'a longer configured interval cancels the earlier automatic deadline',
    () async {
      final previous = now
          .subtract(const Duration(hours: 12))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      await model.setAutoSyncIntervalHours(24);
      now = previous.add(const Duration(hours: 12));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      now = previous.add(const Duration(hours: 24));
      await model.refreshAfterResume();
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
    },
  );

  for (final failure in ['identity', 'catalog', 'factory']) {
    test(
      'failed automatic $failure attempts count toward the deadline',
      () async {
        await db.upsertPeer(remote);
        if (failure == 'identity') {
          identityFailure = const SocketException('offline');
        }
        if (failure == 'catalog') {
          catalogFailure = StateError('catalog unavailable');
        }
        if (failure == 'factory') {
          factoryFailure = StateError('client unavailable');
        }
        final attemptedAt = now;
        await model.initialize();
        expect(await savedAttempt(), attemptedAt);
        expect(model.devices.single.lastSync, attemptedAt);
        expect(await savedSuccess(), isNull);
        expect(model.devices.single.lastSuccessfulSync, isNull);
        expect(model.syncProgress.single.phase, SyncPhase.failed);
        final attempts = connections.length;
        now = now.add(const Duration(hours: 11));
        await model.refreshAfterResume();
        await model.refreshAfterResume();
        expect(connections.length, attempts);
        expect(await savedAttempt(), attemptedAt);
        identityFailure = catalogFailure = factoryFailure = null;
        now = attemptedAt.add(const Duration(hours: 12));
        await model.refreshAfterResume();
        expect(model.syncProgress.single.phase, SyncPhase.completed);
        expect(await savedAttempt(), now);
        expect(await savedSuccess(), isNotNull);
        expect(model.devices.single.lastSuccessfulSync, await savedSuccess());
      },
    );
  }

  test('manual failures postpone the next automatic attempt', () async {
    await db.upsertPeer(remote);
    await model.initialize();
    final successfulAt = await savedSuccess();
    expect(successfulAt, isNotNull);
    expect(model.devices.single.lastSuccessfulSync, successfulAt);
    now = now.add(const Duration(hours: 11));
    identityFailure = const SocketException('offline');
    await model.refresh();
    final failedAt = now;
    expect(await savedAttempt(), failedAt);
    expect(model.syncProgress.single.phase, SyncPhase.failed);
    expect(await savedSuccess(), successfulAt);
    expect(model.devices.single.lastSuccessfulSync, successfulAt);
    final attempts = connections.length;
    identityFailure = null;
    now = now.add(const Duration(hours: 2));
    await model.refreshAfterResume();
    expect(connections.length, attempts);
    expect(await savedAttempt(), failedAt);
    await model.retrySync(remote.id);
    expect(syncCount(), 2);
    expect(await savedAttempt(), now);
    expect(model.devices.single.lastSuccessfulSync, await savedSuccess());
  });

  test(
    'a new attempt keeps the previous success visible until completion',
    () async {
      await db.upsertPeer(remote);
      await model.initialize();
      final successfulAt = await savedSuccess();
      final entered = Completer<void>();
      final release = Completer<void>();
      beforeIdentity = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      now = now.add(const Duration(hours: 1));
      // Discovery/manual identity objects need not carry the saved success time.
      endpointIdentity = remote;
      final syncing = model.connect('${remote.host}:${remote.port}');
      try {
        await entered.future;
        expect(await savedAttempt(), now);
        expect(model.devices.single.lastSuccessfulSync, successfulAt);
        expect(await savedSuccess(), successfulAt);
      } finally {
        release.complete();
        await syncing;
      }
      expect(model.devices.single.lastSuccessfulSync, await savedSuccess());
      expect(model.devices.single.lastSuccessfulSync, isNotNull);
    },
  );

  test(
    'identity address writes preserve a success refreshed during the write',
    () async {
      await db.upsertPeer(remote.copyWith(lastSync: now));
      final gated = _PeerWriteGatedRepository(db);
      model = controller(repository: gated);
      await model.initialize();
      expect(model.devices.single.lastSuccessfulSync, isNull);
      final enteredWrite = Completer<void>();
      final releaseWrite = Completer<void>();
      final enteredCatalog = Completer<void>();
      final releaseCatalog = Completer<void>();
      var writes = 0;
      gated.beforePeerWrite = (_) async {
        // The attempt write precedes identity; the second write saves identity.
        if (++writes == 2) {
          enteredWrite.complete();
          await releaseWrite.future;
        }
      };
      beforeCatalog = () async {
        enteredCatalog.complete();
        await releaseCatalog.future;
      };
      final syncing = model.retrySync(remote.id);
      try {
        await enteredWrite.future.timeout(const Duration(seconds: 5));
        // A preceding lifecycle's sync can finish while this attempt saves its
        // identity. Read that committed time into the current device view.
        await db.markPeerSynced(remote);
        final completedAt = await savedSuccess();
        expect(completedAt, isNotNull);
        await model.selectDevice(remote.id);
        expect(model.devices.single.lastSuccessfulSync, completedAt);
        releaseWrite.complete();
        await enteredCatalog.future.timeout(const Duration(seconds: 5));
        expect(model.devices.single.lastSuccessfulSync, completedAt);
        expect(await savedSuccess(), completedAt);
      } finally {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
        if (!releaseCatalog.isCompleted) releaseCatalog.complete();
        await syncing;
      }
      expect(model.devices.single.lastSuccessfulSync, await savedSuccess());
    },
  );

  test(
    'the last success survives an offline restart after a failed retry',
    () async {
      await db.upsertPeer(remote);
      await model.initialize();
      final successfulAt = await savedSuccess();
      now = now.add(const Duration(hours: 1));
      catalogFailure = StateError('catalog unavailable');
      await model.refresh();
      expect(model.devices.single.lastSuccessfulSync, successfulAt);
      final failedAt = now;
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: '${temporary.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      connections.clear();
      now = now.add(const Duration(hours: 1));
      model = controller();
      await model.initialize();
      expect(connections, isEmpty);
      expect(model.devices.single.online, isFalse);
      expect(model.devices.single.lastSync, failedAt);
      expect(model.devices.single.lastSuccessfulSync, successfulAt);
      expect(await savedSuccess(), successfulAt);
    },
  );

  test('the attempt is persisted before identity work begins', () async {
    await db.upsertPeer(remote);
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeIdentity = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final starting = model.initialize();
    try {
      await entered.future;
      expect(await savedAttempt(), now);
      expect(model.devices.single.lastSync, now);
      now = now.add(const Duration(minutes: 5));
    } finally {
      release.complete();
      await starting;
    }
    expect(await savedAttempt(), now.subtract(const Duration(minutes: 5)));
  });

  test(
    'failed attempt timestamps survive closing and reopening stores',
    () async {
      await db.upsertPeer(remote);
      identityFailure = const SocketException('offline');
      await model.initialize();
      final failedAt = now;
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: '${temporary.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      connections.clear();
      identityFailure = null;
      now = now.add(const Duration(hours: 1));
      model = controller();
      await model.initialize();
      expect(connections, isEmpty);
      expect(await savedAttempt(), failedAt);
      expect(model.devices.single.lastSync, failedAt);
    },
  );

  test(
    'rediscovery updates reachability and address without resetting the deadline',
    () async {
      final previous = now.subtract(const Duration(hours: 1));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await db.markPeerSynced(remote);
      final successfulAt = await savedSuccess();
      await model.initialize();
      final moved = remote.copyWith(host: '10.0.0.20', name: 'Renamed remote');
      await discover(moved);
      expect(syncCount(), 0);
      expect(model.devices.single.online, isTrue);
      expect(model.devices.single.name, moved.name);
      expect(model.devices.single.address, '${moved.host}:${moved.port}');
      expect(await savedAttempt(), previous);
      expect(await savedSuccess(), successfulAt);
      expect(model.devices.single.lastSuccessfulSync, successfulAt);
      expect((await db.listPeers()).single.host, moved.host);
      await discover(moved, expectConnection: false);
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
    },
  );

  test(
    'rediscovery does not retry a failed catalog before the deadline',
    () async {
      await db.upsertPeer(remote);
      catalogFailure = StateError('catalog unavailable');
      await model.initialize();
      final failedAt = now;
      expect(syncCount(), 1);
      catalogFailure = null;
      now = now.add(const Duration(minutes: 1));
      await discover(remote, expectConnection: false);
      await discover(remote, expectConnection: false);
      expect(syncCount(), 1);
      expect(await savedAttempt(), failedAt);
      expect(model.devices.single.online, isTrue);
    },
  );

  test(
    'manual retry after rediscovery uses the newly remembered endpoint',
    () async {
      await db.upsertPeer(remote);
      catalogFailure = StateError('catalog unavailable');
      await model.initialize();
      final failedAt = now;
      expect(syncCount(), 1);
      expect(model.syncProgress.single.phase, SyncPhase.failed);
      final moved = remote.copyWith(host: '10.0.0.20', port: 50729);
      now = now.add(const Duration(minutes: 1));
      await discover(moved);
      expect(syncCount(), 1, reason: 'Rediscovery only checks identity');
      expect(await savedAttempt(), failedAt);
      expect((await db.listPeers()).single.host, moved.host);
      expect((await db.listPeers()).single.port, moved.port);

      catalogFailure = null;
      now = now.add(const Duration(minutes: 1));
      await model.retrySync(remote.id);
      expect(connections.last.host, moved.host);
      expect(connections.last.port, moved.port);
      expect(syncCount(), 2);
      expect(await savedAttempt(), now);
      expect(model.syncProgress.single.phase, SyncPhase.completed);
    },
  );

  test(
    'an active application automatically synchronizes when the deadline arrives',
    () async {
      final previous = now
          .subtract(const Duration(hours: 12))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      now = previous.add(const Duration(hours: 12));
      await waitForAutoSync(() => syncCount() == 1);
      await clients.single.closed.future;
      expect(await savedAttempt(), now);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(syncCount(), 1);
    },
  );

  test(
    'automatic deadlines stop without sharing and resume when active',
    () async {
      final previous = now
          .subtract(const Duration(hours: 12))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      await model.setForeground(false);
      now = previous.add(const Duration(hours: 12));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      await model.setForeground(true);
      await model.refreshAfterResume();
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
    },
  );
}
