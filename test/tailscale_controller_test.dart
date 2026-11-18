import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/app_controller.dart';
import 'package:tamayura/app/tailscale_bindings.dart';
import 'package:tamayura/background/transfer_scheduler.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/data/transfer_store.dart';
import 'package:tamayura/network/generated/media.pbgrpc.dart' as wire;
import 'package:tamayura/network/media_rpc.dart';

import 'controller_test.dart' show FakeBridge;
import 'network_test.dart' show MemorySource;

class _FailingScheduler implements TransferScheduler {
  @override
  Future<void> scheduleTransfer(String id) async {}
  @override
  Future<void> cancelTransfer(String id) async {}
  @override
  Future<List<String>> scheduledTransferIds() async => [];
  @override
  Future<void> shutdown() async => throw StateError('shutdown failure');
}

class _FailingDiscoveryCancellation extends FakeBridge {
  final failingEvents = StreamController<Map<String, dynamic>>(
    onCancel: () async => throw StateError('discovery cancel failed'),
  );
  @override
  Stream<Map<String, dynamic>> get discoveryEvents => failingEvents.stream;
}

class _Node implements TailscaleNode {
  final started = Completer<void>();
  int disposals = 0;
  static const signedOut = NodeStatus(
    sessionEpoch: 'session',
    state: NodeState.signedOut,
  );
  @override
  Future<NodeStatus> start() async {
    started.complete();
    return signedOut;
  }

  @override
  Future<NodeStatus> status() async => signedOut;
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records which network a download was scheduled for.
class _SchedulingBridge extends FakeBridge {
  final remote = <String>[];
  @override
  Future<void> scheduleRemoteTransfer(String id) async {
    remote.add(id);
  }
}

class _Lease implements ServiceLease {
  @override
  Future<void> close() async {}
  @override
  Future<void> updatePolicy(Set<PeerRef> peers) async {}
}

class _StatusNode implements TailscaleNode {
  _StatusNode(this.current, {this.target});
  final NodeStatus current;

  /// The local port standing in for the associated node's media service.
  final int? target;
  final started = Completer<void>();
  @override
  Future<NodeStatus> start() async {
    if (!started.isCompleted) started.complete();
    return current;
  }

  @override
  Future<NodeStatus> status() async => current;
  @override
  Future<List<TailscalePeer>> peers() async => const [];
  @override
  Future<ServiceLease> publishTcp({
    required int port,
    required Set<PeerRef> allowedPeers,
    required void Function(BridgeConnection) onConnection,
  }) async => _Lease();
  @override
  Future<BridgeConnection> openTcp(PeerRef peer, {required int port}) async {
    final local = target;
    if (local == null) throw const TailscaleException('peerUnavailable');
    return BridgeConnection.fromSocket(
      await Socket.connect(InternetAddress.loopbackIPv4, local),
    );
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A LAN address at which the device does not answer. Each attempt fails at
/// once, as a refused connection does, and is counted.
class _AwayService extends wire.MediaLibraryServiceBase {
  int attempts = 0;
  static const _away = GrpcError.unavailable('The device is away');
  @override
  Future<wire.DeviceIdentity> getIdentity(
    ServiceCall call,
    wire.Empty request,
  ) async {
    attempts++;
    throw _away;
  }

  @override
  Future<wire.CatalogResponse> listMediaPage(
    ServiceCall call,
    wire.CatalogRequest request,
  ) async => throw _away;
  @override
  Future<wire.ThumbnailResponse> getThumbnail(
    ServiceCall call,
    wire.ThumbnailRequest request,
  ) async => throw _away;
  @override
  Stream<wire.FileChunk> readFile(ServiceCall call, wire.ReadRequest request) =>
      Stream.error(_away);
}

Future<void> _eventually(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('The expected state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // The Android job's network is fixed when it is scheduled. Right after the
  // app starts the node has no registration scope yet, and a download from an
  // associated device was scheduled for Wi-Fi only, with no later upgrade.
  for (final (label, status, remote) in [
    (
      'while the node is still starting',
      const NodeStatus(sessionEpoch: 'session', state: NodeState.connecting),
      true,
    ),
    (
      'once the node registered in the associated scope',
      const NodeStatus(
        sessionEpoch: 'session',
        state: NodeState.connected,
        networkScope: 'scope',
        selfNodeId: 'self',
      ),
      true,
    ),
    (
      'once the node registered outside the associated scope',
      const NodeStatus(
        sessionEpoch: 'session',
        state: NodeState.connected,
        networkScope: 'another-login',
        selfNodeId: 'self',
      ),
      false,
    ),
  ]) {
    test('a download from an associated device is scheduled '
        '${remote ? 'with' : 'without'} mobile data $label', () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final server = MediaRpcServer(
        identity: const Peer(id: 'remote', name: 'Remote', host: '', port: 0),
        source: MemorySource(),
      );
      await server.start();
      await repository.upsertPeer(
        Peer(
          id: 'remote',
          name: 'Remote',
          host: '127.0.0.1',
          port: server.port,
        ),
      );
      await repository.setSetting('downloadUri', 'content://downloads');
      await repository.setSetting('downloadFolder', 'Tamayura');
      await repository.setSetting(TailscaleBindings.enabledKey, 'true');
      await repository.setSetting(
        TailscaleBindings.settingKey,
        TailscaleBindings.encode([
          const TailscaleBinding(
            deviceId: 'remote',
            name: 'Remote',
            ref: PeerRef(networkScope: 'scope', nodeId: 'node'),
          ),
        ]),
      );
      final node = _StatusNode(status);
      final bridge = _SchedulingBridge();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => transfers,
        openTailscaleNode: () async => node,
      );
      addTearDown(() async {
        await model.shutdown();
        await server.stop();
        await bridge.events.close();
      });
      await model.initialize();
      await node.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // An approved remote route does not replace a LAN address that has not
      // been tried yet: the catalog was read over the LAN.
      expect(model.media, hasLength(1));
      expect(model.devices.single.lanOnline, true);
      await model.download(model.media.single);
      expect(model.error, isNull);
      expect(bridge.remote, hasLength(remote ? 1 : 0));
      expect(bridge.scheduled, hasLength(remote ? 0 : 1));
    });
  }

  test(
    'a LAN address is tried once, then the approved remote route is used directly',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final server = MediaRpcServer(
        identity: const Peer(id: 'remote', name: 'Remote', host: '', port: 0),
        source: MemorySource(),
      );
      await server.start();
      // The device is away from its remembered LAN address.
      final away = _AwayService();
      final lan = Server.create(services: [away]);
      await lan.serve(address: InternetAddress.loopbackIPv4, port: 0);
      await repository.upsertPeer(
        Peer(id: 'remote', name: 'Remote', host: '127.0.0.1', port: lan.port!),
      );
      await repository.setSetting(TailscaleBindings.enabledKey, 'true');
      await repository.setSetting(
        TailscaleBindings.settingKey,
        TailscaleBindings.encode([
          const TailscaleBinding(
            deviceId: 'remote',
            name: 'Remote',
            ref: PeerRef(networkScope: 'scope', nodeId: 'node'),
          ),
        ]),
      );
      final node = _StatusNode(
        const NodeStatus(
          sessionEpoch: 'session',
          state: NodeState.connected,
          networkScope: 'scope',
          selfNodeId: 'self',
        ),
        target: server.port,
      );
      final bridge = FakeBridge();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => transfers,
        openTailscaleNode: () async => node,
      );
      addTearDown(() async {
        await model.shutdown();
        await server.stop();
        await lan.shutdown();
        await bridge.events.close();
      });
      // The first synchronization begins while the saved sign-in is still
      // resuming. It tries the LAN address and continues on the remote route.
      await model.initialize();
      expect(model.media, hasLength(1));
      expect(away.attempts, 1);
      await _eventually(() => model.devices.single.tailscaleOnline);
      expect(model.devices.single.lanOnline, false);
      // The remembered LAN address is kept for when the device is back.
      expect((await repository.listPeers()).single.port, lan.port);
      await model.retrySync('remote');
      expect(model.error, isNull);
      expect(away.attempts, 1);
    },
  );

  test(
    'discovery cancellation failure cannot leave the media listener running',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final bridge = _FailingDiscoveryCancellation();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        openRepository: () async => repository,
        openTransfers: () async => transfers,
      );
      await model.initialize();
      expect(model.port, greaterThan(0));
      await model.shutdown();
      expect(model.port, 0);
      await bridge.failingEvents.close();
      await bridge.events.close();
    },
  );
  test(
    'scheduler shutdown failure still releases the Tailscale owner and stores',
    () async {
      final repository = await TamayuraRepository.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      final transfers = await TransferStore.open(
        path: inMemoryDatabasePath,
        factory: databaseFactoryFfi,
      );
      await repository.setSetting('tailscale_enabled_v1', 'true');
      final node = _Node();
      final bridge = FakeBridge();
      final model = AppController(
        bridge: bridge,
        preferredPort: 0,
        transferScheduler: _FailingScheduler(),
        openRepository: () async => repository,
        openTransfers: () async => transfers,
        openTailscaleNode: () async => node,
      );
      addTearDown(() async {
        await model.shutdown();
        await bridge.events.close();
      });
      await model.initialize();
      await node.started.future;
      await model.shutdown();
      expect(node.disposals, 1);
      await model.shutdown();
      expect(node.disposals, 1);
      await expectLater(
        repository.listPeers(),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(transfers.recent(), throwsA(isA<DatabaseException>()));
    },
  );
}
