import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';

import 'auto_sync_test.dart' show waitForAutoSync;
import 'controller_test.dart' show FakeBridge, StubRpcClient;

const _remote = Peer(
  id: 'remote',
  name: 'Remote',
  host: '10.0.0.10',
  port: 50728,
);
const _other = Peer(id: 'other', name: 'Other', host: '10.0.0.11', port: 50728);

MediaItem _photo(String id, String deviceId) => MediaItem(
  id: id,
  deviceId: deviceId,
  name: '$id.jpg',
  sharedFolderId: 'camera',
  sharedFolderName: 'Camera',
  relativePath: '$id.jpg',
  mimeType: 'image/jpeg',
  size: 123,
  modifiedMs: 1,
  thumbnail: Uint8List.fromList([1, 2, 3]),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory temporary;
  late TamayuraRepository db;
  late TransferStore tasks;
  late FakeBridge bridge;
  late AppController model;
  late List<StubRpcClient> clients;
  late DateTime now;
  // Holds a catalog until its client is closed, like a real stalled RPC.
  Completer<void>? catalogEntered;

  int syncCount([String? id]) => clients
      .where((client) => id == null || client.peer.id == id)
      .fold(0, (count, client) => count + client.synchronizeCalls);

  AppController controller() => AppController(
    bridge: bridge,
    preferredPort: 0,
    openRepository: () async => db,
    openTransfers: () async => tasks,
    clock: () => now,
    clientFactory: (candidate) {
      final identity = candidate.id.isEmpty
          ? _remote.copyWith(host: candidate.host, port: candidate.port)
          : candidate;
      late final StubRpcClient client;
      client = StubRpcClient(
        candidate,
        onIdentity: () async => identity,
        onSynchronize: () async {
          final entered = catalogEntered;
          if (entered != null && !entered.isCompleted) {
            entered.complete();
            await client.closed.future;
            throw const GrpcError.unavailable('connection closed');
          }
          await db.replacePeerSnapshot(identity, [
            _photo('synced', identity.id),
          ]);
          return SyncResult(
            peer: identity,
            revision: 'test',
            totalCount: 1,
            addedCount: 1,
            deletedCount: 0,
            thumbnailRequests: 0,
          );
        },
      );
      clients.add(client);
      return client;
    },
  );

  Future<void> announce(Peer peer, {String type = 'found'}) async {
    final previous = clients.length;
    bridge.events.add({
      'type': type,
      'id': peer.id,
      'name': peer.name,
      'host': peer.host,
      'port': peer.port,
    });
    await waitForAutoSync(() => clients.length > previous);
    await clients.last.closed.future;
  }

  setUp(() async {
    now = DateTime(2026, 10, 17, 9);
    clients = [];
    catalogEntered = null;
    temporary = await Directory.systemTemp.createTemp('tamayura-forget-');
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

  Future<void> rememberSynced(Peer peer) async {
    await db.replacePeerSnapshot(peer, [_photo('${peer.id}-photo', peer.id)]);
    // Not due, so startup does not synchronize it again.
    await db.upsertPeer(peer.copyWith(lastSync: now));
    await db.markPeerSynced(peer);
  }

  test(
    'forgetting removes the device, its album and order but keeps downloads',
    () async {
      await rememberSynced(_remote);
      await rememberSynced(_other);
      await db.saveDownload(
        DownloadRecord(
          deviceId: _remote.id,
          mediaId: 'remote-photo',
          uri: 'content://saved/remote-photo.jpg',
          completedAt: now,
        ),
      );
      await model.initialize();
      expect(syncCount(), 0);
      expect(await model.reorderDevices([_remote.id, _other.id]), isTrue);
      await model.selectDevice(_remote.id);
      expect(model.media.single.deviceId, _remote.id);

      final forgetting = model.forgetDevice(_remote.id);
      expect(model.forgettingDeviceIds, {_remote.id});
      expect(await model.forgetDevice(_remote.id), isFalse);
      expect(await forgetting, isTrue);

      expect(model.forgettingDeviceIds, isEmpty);
      expect(model.devices.map((device) => device.id), [_other.id]);
      expect(model.selectedDeviceId, isNull);
      expect(model.media.map((item) => item.deviceId), [_other.id]);
      expect(model.collections.map((item) => item.deviceId), [_other.id]);
      expect((await db.listPeers()).map((peer) => peer.id), [_other.id]);
      expect(await db.countMedia(deviceId: _remote.id), 0);
      expect(jsonDecode((await db.getSetting('deviceOrder'))!), [_other.id]);
      expect(
        (await db.getDownload(_remote.id, 'remote-photo'))?.uri,
        'content://saved/remote-photo.jpg',
      );
      expect(model.error, isNull);
      expect(await model.forgetDevice(_remote.id), isFalse);
      expect(await model.forgetDevice('missing'), isFalse);
    },
  );

  test(
    'forgetting stops an in-flight sync that cannot recreate the device',
    () async {
      await db.upsertPeer(_remote);
      catalogEntered = Completer<void>();
      final starting = model.initialize();
      await catalogEntered!.future.timeout(const Duration(seconds: 5));
      expect(model.devices.single.id, _remote.id);

      expect(await model.forgetDevice(_remote.id), isTrue);
      await starting.timeout(const Duration(seconds: 5));
      expect(clients.first.closeCalls, greaterThan(0));
      expect(model.devices, isEmpty);
      expect(model.syncProgress, isEmpty);
      expect(await db.listPeers(), isEmpty);
      expect(await db.countMedia(), 0);
      expect(model.error, isNull);

      // A refresh or a repeated announcement does not bring it back.
      await model.refresh();
      expect(await db.listPeers(), isEmpty);
    },
  );

  test(
    'a forgotten device discovered again is offered as a new device',
    () async {
      await model.initialize();
      await announce(_remote);
      expect(model.syncApprovalRequests.single.id, _remote.id);
      await model.setDeviceSyncEnabled(_remote.id, true);
      expect(syncCount(_remote.id), 1);
      expect(model.syncApprovalRequests, isEmpty);

      expect(await model.forgetDevice(_remote.id), isTrue);
      expect(model.devices, isEmpty);
      // Still announced: repeated records are not a new discovery edge.
      expect(await db.listPeers(), isEmpty);

      // Losing a forgotten device needs no presence probe.
      final probes = clients.length;
      bridge.events.add({'type': 'lost', 'id': _remote.id});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(clients.length, probes);
      await announce(_remote);
      expect(model.devices.single.syncApproval, PeerSyncApproval.pending);
      expect(model.syncApprovalRequests.single.id, _remote.id);
      expect(syncCount(), 1, reason: 'It waits for approval again');
      expect(await db.countMedia(), 0);
    },
  );

  test('a manual connection approves a pending device and syncs it', () async {
    await model.initialize();
    await announce(_remote);
    expect(model.devices.single.syncApproval, PeerSyncApproval.pending);
    await model.retrySync(_remote.id);
    expect(syncCount(), 0, reason: 'A pending device is not retried');

    await model.connect('${_remote.host}:${_remote.port}');
    expect(syncCount(), 1);
    expect(model.devices.single.syncApproval, PeerSyncApproval.approved);
    expect(model.syncApprovalRequests, isEmpty);
    expect(
      (await db.listPeers()).single.syncApproval,
      PeerSyncApproval.approved,
    );
    expect(model.media.single.deviceId, _remote.id);
  });

  test('a manually connected new device is approved immediately', () async {
    await model.initialize();
    await model.connect('${_remote.host}:${_remote.port}');
    expect(syncCount(), 1);
    expect(model.devices.single.syncApproval, PeerSyncApproval.approved);
    expect(model.syncApprovalRequests, isEmpty);
    expect(
      (await db.listPeers()).single.syncApproval,
      PeerSyncApproval.approved,
    );
  });
}
