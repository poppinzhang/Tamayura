import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/media_rpc.dart';

import 'controller_test.dart' show FakeBridge, GatedRepository, StubRpcClient;
import 'network_test.dart' show MemorySource, identity;

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

  Future<void> lose(Peer peer) async {
    final previousCount = clients.length;
    bridge.events.add({
      'type': 'lost',
      'id': peer.id,
      'host': peer.host,
      'port': peer.port,
    });
    await waitForAutoSync(() => clients.length > previousCount);
    await clients.last.closed.future;
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

  test('automatic synchronization defaults to ten minutes', () async {
    expect(model.autoSyncIntervalMinutes, 10);
    await model.initialize();
    expect(model.autoSyncIntervalMinutes, 10);
    expect(model.autoSyncIntervalSaving, isFalse);
    expect(model.error, isNull);
  });

  for (final invalid in ['', 'unknown', '0', '-1', '1.5', '525601']) {
    test('invalid saved interval "$invalid" uses ten minutes', () async {
      await db.setSetting('autoSyncIntervalMinutes', invalid);
      await model.initialize();
      expect(model.autoSyncIntervalMinutes, 10);
      expect(model.error, isNull);
    });
  }

  test(
    'configured interval persists across reopening the application',
    () async {
      await model.initialize();
      for (final minutes in [1, 24, 525600]) {
        await model.setAutoSyncIntervalMinutes(minutes);
        expect(model.autoSyncIntervalMinutes, minutes);
        expect(await db.getSetting('autoSyncIntervalMinutes'), '$minutes');
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
      expect(model.autoSyncIntervalMinutes, 525600);
      expect(model.error, isNull);
    },
  );

  test('invalid configuration keeps the previous saved interval', () async {
    await model.initialize();
    await model.setAutoSyncIntervalMinutes(24);
    for (final invalid in [0, -1, 525601]) {
      await model.setAutoSyncIntervalMinutes(invalid);
      expect(model.autoSyncIntervalMinutes, 24);
      expect(await db.getSetting('autoSyncIntervalMinutes'), '24');
      expect(model.autoSyncIntervalSaving, isFalse);
      expect(model.error, isNotNull);
    }
  });

  test(
    'a failed settings write retains the interval and can be retried',
    () async {
      final gated = GatedRepository(db);
      model = controller(repository: gated);
      await db.setSetting('autoSyncIntervalMinutes', '24');
      await model.initialize();
      gated.beforeSettingWrite = (key, value) async {
        if (key == 'autoSyncIntervalMinutes') throw StateError('write failed');
      };
      await model.setAutoSyncIntervalMinutes(6);
      expect(model.autoSyncIntervalMinutes, 24);
      expect(await db.getSetting('autoSyncIntervalMinutes'), '24');
      expect(model.autoSyncIntervalSaving, isFalse);
      expect(model.error, isNotNull);
      gated.beforeSettingWrite = null;
      await model.setAutoSyncIntervalMinutes(6);
      expect(model.autoSyncIntervalMinutes, 6);
      expect(await db.getSetting('autoSyncIntervalMinutes'), '6');
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
        if (key != 'autoSyncIntervalMinutes') return;
        writes++;
        entered.complete();
        await release.future;
      };
      final saving = model.setAutoSyncIntervalMinutes(6);
      try {
        await entered.future;
        expect(model.autoSyncIntervalMinutes, 10);
        expect(model.autoSyncIntervalSaving, isTrue);
        await model.setAutoSyncIntervalMinutes(24);
        expect(writes, 1);
      } finally {
        release.complete();
        await saving;
      }
      expect(model.autoSyncIntervalMinutes, 6);
      expect(model.autoSyncIntervalSaving, isFalse);
    },
  );

  test(
    'startup and resume wait until the last attempt plus ten minutes',
    () async {
      final previous = now;
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      now = previous.add(
        const Duration(minutes: 10) - const Duration(milliseconds: 1),
      );
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      now = previous.add(const Duration(minutes: 10));
      await model.refreshAfterResume();
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
      expect(model.devices.single.lastSync, now);
      now = now.add(const Duration(seconds: 1));
      await model.refreshAfterResume();
      expect(syncCount(), 1);
    },
  );

  for (final minutes in [1, 24, 525600]) {
    test('a saved $minutes minute interval controls the deadline', () async {
      await db.setSetting('autoSyncIntervalMinutes', '$minutes');
      final previous = now;
      final interval = Duration(minutes: minutes);
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      now = previous.add(interval - const Duration(milliseconds: 1));
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      now = previous.add(interval);
      await model.refreshAfterResume();
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
    });
  }

  test(
    'the ten minute default refreshes a real gRPC catalog when due',
    () async {
      final source = MemorySource();
      final server = MediaRpcServer(identity: identity, source: source);
      await server.start();
      addTearDown(server.stop);
      final previous = now;
      await db.upsertPeer(
        identity.copyWith(port: server.port, lastSync: previous),
      );
      model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => db,
        openTransfers: () async => tasks,
        clock: () => now,
      );
      await model.initialize();
      expect(await db.listMedia(), isEmpty);
      now = previous.add(
        const Duration(minutes: 10) - const Duration(milliseconds: 1),
      );
      await model.refreshAfterResume();
      expect(await db.listMedia(), isEmpty);
      expect(await savedAttempt(identity.id), previous);

      now = previous.add(const Duration(minutes: 10));
      await model.refreshAfterResume();
      expect((await db.listMedia()).map((item) => item.id), ['safe-id']);
      expect(await savedAttempt(identity.id), now);
      expect(model.error, isNull);

      source.ids = ['next-id'];
      await server.refresh();
      now = previous.add(const Duration(minutes: 19, seconds: 59));
      await model.refreshAfterResume();
      expect((await db.listMedia()).map((item) => item.id), ['safe-id']);
      now = previous.add(const Duration(minutes: 20));
      await model.refreshAfterResume();
      expect((await db.listMedia()).map((item) => item.id), ['next-id']);
      expect(await savedAttempt(identity.id), now);
      expect(model.error, isNull);
    },
  );

  test(
    'a newly discovered device waits for approval, then syncs and waits',
    () async {
      await model.initialize();
      await discover(remote);
      expect(syncCount(), 0);
      expect(model.devices.single.id, remote.id);
      expect(model.devices.single.online, isTrue);
      expect(model.devices.single.syncApproval, PeerSyncApproval.pending);
      expect(model.syncApprovalRequests.single.id, remote.id);
      final saved = (await db.listPeers()).single;
      expect(saved.syncApproval, PeerSyncApproval.pending);
      expect(saved.lastSync, isNull);

      // Closing the prompt keeps the device pending and does not ask again.
      model.dismissSyncApproval(remote.id);
      expect(model.syncApprovalRequests, isEmpty);
      await discover(remote, expectConnection: false);
      expect(model.syncApprovalRequests, isEmpty);
      await model.refresh();
      now = now.add(const Duration(minutes: 11));
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), isNull);

      await model.setDeviceSyncEnabled(remote.id, true);
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
      expect(model.devices.single.syncApproval, PeerSyncApproval.approved);
      expect(
        (await db.listPeers()).single.syncApproval,
        PeerSyncApproval.approved,
      );
      now = now.add(const Duration(minutes: 1));
      await discover(remote, expectConnection: false);
      await model.refreshAfterResume();
      expect(syncCount(), 1);
    },
  );

  test(
    'a declined device stays remembered without prompts until enabled',
    () async {
      await model.initialize();
      await discover(remote);
      await model.setDeviceSyncEnabled(remote.id, false);
      expect(syncCount(), 0);
      expect(model.syncApprovalRequests, isEmpty);
      expect(model.devices.single.syncApproval, PeerSyncApproval.declined);

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
      expect(model.devices.single.syncApproval, PeerSyncApproval.declined);
      await discover(remote);
      await model.refresh();
      expect(syncCount(), 0);
      expect(model.syncApprovalRequests, isEmpty);
      expect(model.devices.single.online, isTrue);

      await model.setDeviceSyncEnabled(remote.id, true);
      expect(syncCount(), 1);
      expect(
        (await db.listPeers()).single.syncApproval,
        PeerSyncApproval.approved,
      );
    },
  );

  test('an unknown or incompatible announcement is not remembered', () async {
    await model.initialize();
    identityFailure = const FormatException('对端不是兼容的 Tamayura 设备');
    await discover(remote);
    expect(model.devices, isEmpty);
    expect(await db.listPeers(), isEmpty);
    expect(model.syncApprovalRequests, isEmpty);
    expect(syncCount(), 0);
  });

  test('each device has its own last synchronization deadline', () async {
    final recent = now.subtract(const Duration(minutes: 2));
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
        lastSync: now.subtract(const Duration(minutes: 11)),
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
    now = now.add(const Duration(minutes: 10) - const Duration(seconds: 1));
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
      final previous = now.subtract(const Duration(minutes: 6));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      await model.setAutoSyncIntervalMinutes(6);
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
          .subtract(const Duration(minutes: 10))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      await model.setAutoSyncIntervalMinutes(24);
      now = previous.add(const Duration(minutes: 10));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await model.refreshAfterResume();
      expect(syncCount(), 0);
      expect(await savedAttempt(), previous);
      now = previous.add(const Duration(minutes: 24));
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
        now = now.add(const Duration(minutes: 9));
        await model.refreshAfterResume();
        await model.refreshAfterResume();
        expect(connections.length, attempts);
        expect(await savedAttempt(), attemptedAt);
        identityFailure = catalogFailure = factoryFailure = null;
        now = attemptedAt.add(const Duration(minutes: 10));
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
    now = now.add(const Duration(minutes: 9));
    identityFailure = const SocketException('offline');
    await model.refresh();
    final failedAt = now;
    expect(await savedAttempt(), failedAt);
    expect(model.syncProgress.single.phase, SyncPhase.failed);
    expect(await savedSuccess(), successfulAt);
    expect(model.devices.single.lastSuccessfulSync, successfulAt);
    final attempts = connections.length;
    identityFailure = null;
    now = now.add(const Duration(minutes: 2));
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
      now = now.add(const Duration(minutes: 1));
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
      now = now.add(const Duration(minutes: 1));
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
      now = now.add(const Duration(minutes: 1));
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
      now = now.add(const Duration(minutes: 1));
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
      final previous = now.subtract(const Duration(minutes: 1));
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
    'the first announcement after a failed attempt retries it once',
    () async {
      await db.upsertPeer(remote);
      catalogFailure = StateError('catalog unavailable');
      await model.initialize();
      expect(syncCount(), 1);
      expect((await db.listPeers()).single.lastSyncFailed, isTrue);
      catalogFailure = null;
      now = now.add(const Duration(minutes: 1));
      await discover(remote);
      expect(syncCount(), 2, reason: 'An mDNS rising edge retries the failure');
      expect(await savedAttempt(), now);
      expect(await savedSuccess(), isNotNull);
      expect((await db.listPeers()).single.lastSyncFailed, isFalse);
      expect(model.devices.single.online, isTrue);
      now = now.add(const Duration(minutes: 1));
      await discover(remote, expectConnection: false);
      expect(syncCount(), 2);
    },
  );

  test('a failing device is retried only on a new announcement edge', () async {
    await db.upsertPeer(remote);
    catalogFailure = StateError('catalog unavailable');
    await model.initialize();
    expect(syncCount(), 1);
    await discover(remote);
    expect(syncCount(), 2);
    // Repeated or updated announcements of a present device do not poll it.
    await discover(remote, expectConnection: false);
    final moved = remote.copyWith(host: '10.0.0.20');
    await discover(moved);
    expect(syncCount(), 2, reason: 'An address update only checks identity');
    expect((await db.listPeers()).single.host, moved.host);
    // Lost and found again is a new edge.
    await lose(moved);
    expect(syncCount(), 2);
    catalogFailure = null;
    await discover(moved);
    expect(syncCount(), 3);
    expect(model.syncProgress.single.phase, SyncPhase.completed);
    // A successful last attempt is not retried by a later edge.
    await lose(moved);
    await discover(moved, expectConnection: false);
    expect(syncCount(), 3);
  });

  test(
    'a failed attempt is retried by the first announcement after restart',
    () async {
      await db.upsertPeer(remote);
      identityFailure = const SocketException('offline');
      await model.initialize();
      await model.shutdown();
      db = await TamayuraRepository.open(
        path: '${temporary.path}/catalog.db',
        factory: databaseFactoryFfi,
      );
      tasks = await TransferStore.open(
        path: '${temporary.path}/tasks.db',
        factory: databaseFactoryFfi,
      );
      identityFailure = null;
      now = now.add(const Duration(minutes: 1));
      model = controller();
      await model.initialize();
      expect(syncCount(), 0, reason: 'Startup still waits for the interval');
      await discover(remote);
      expect(syncCount(), 1);
      expect(await savedAttempt(), now);
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
      expect(
        syncCount(),
        2,
        reason: 'The rediscovery edge retries the catalog',
      );
      expect(await savedAttempt(), isNot(failedAt));
      expect((await db.listPeers()).single.host, moved.host);
      expect((await db.listPeers()).single.port, moved.port);

      catalogFailure = null;
      now = now.add(const Duration(minutes: 1));
      await model.retrySync(remote.id);
      expect(connections.last.host, moved.host);
      expect(connections.last.port, moved.port);
      expect(syncCount(), 3);
      expect(await savedAttempt(), now);
      expect(model.syncProgress.single.phase, SyncPhase.completed);
    },
  );

  test(
    'an active application automatically synchronizes when the deadline arrives',
    () async {
      final previous = now
          .subtract(const Duration(minutes: 10))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      expect(syncCount(), 0);
      now = previous.add(const Duration(minutes: 10));
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
          .subtract(const Duration(minutes: 10))
          .add(const Duration(milliseconds: 100));
      await db.upsertPeer(remote.copyWith(lastSync: previous));
      await model.initialize();
      await model.setForeground(false);
      now = previous.add(const Duration(minutes: 10));
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
