import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamayura/app/tailscale_bindings.dart';
import 'package:tamayura/app/tailscale_service.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/data/repository.dart';
import 'package:tamayura/network/generated/media.pbgrpc.dart' as wire;
import 'package:tamayura/network/media_rpc.dart';
import 'package:tamayura/network/downloader.dart';

import 'network_test.dart' show MemorySource;

const _ref = PeerRef(networkScope: 'test-network', nodeId: 'stable-node');
const _peer = Peer(
  id: 'source-phone',
  name: 'Source phone',
  host: '192.168.1.9',
  port: 50728,
);

class _Node implements TailscaleNode {
  NodeStatus current = const NodeStatus(
    sessionEpoch: 'session-one',
    state: NodeState.connected,
    networkScope: 'test-network',
    selfNodeId: 'local-node',
  );
  List<TailscalePeer> visible = [
    const TailscalePeer(
      ref: _ref,
      name: 'Remote',
      addresses: ['100.64.0.1'],
      online: false,
    ),
  ];
  final Map<int, int> targets = {};
  final List<int> dialedPorts = [];
  int starts = 0, logouts = 0, disposed = 0;
  bool startBroken = false;
  TailscaleException? connectionFailure;
  Completer<NodeStatus>? statusGate;
  Completer<void>? publishGate;
  final publishStarted = Completer<void>();
  final List<_Lease> publications = [];

  @override
  Future<NodeStatus> start() async {
    starts++;
    if (startBroken) throw const TailscaleException('runtimeStopped');
    return current;
  }

  @override
  Future<NodeStatus> login() async => current;
  @override
  Future<NodeStatus> status() async =>
      statusGate == null ? current : statusGate!.future;
  @override
  Future<List<TailscalePeer>> peers() async => visible;
  @override
  Future<NodeStatus> logout() async {
    logouts++;
    return current = const NodeStatus(
      sessionEpoch: 'session-two',
      state: NodeState.signedOut,
    );
  }

  @override
  Future<void> dispose() async {
    disposed++;
  }

  @override
  Future<ServiceLease> publishTcp({
    required int port,
    required Set<PeerRef> allowedPeers,
    required void Function(BridgeConnection) onConnection,
  }) async {
    if (!publishStarted.isCompleted) publishStarted.complete();
    await publishGate?.future;
    final lease = _Lease(port, allowedPeers);
    publications.add(lease);
    return lease;
  }

  @override
  Future<BridgeConnection> openTcp(PeerRef ref, {required int port}) async {
    final failure = connectionFailure;
    if (failure != null) throw failure;
    if (ref != _ref || ref.networkScope != current.networkScope) {
      throw const TailscaleException('peerUnavailable');
    }
    dialedPorts.add(port);
    final target = targets[port];
    if (target == null) throw const SocketException('No test service');
    return BridgeConnection.fromSocket(
      await Socket.connect(InternetAddress.loopbackIPv4, target),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lease implements ServiceLease {
  _Lease(this.port, this.allowed);
  final int port;
  Set<PeerRef> allowed;
  int closes = 0;
  bool failPolicy = false;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> updatePolicy(Set<PeerRef> peers) async {
    if (failPolicy) throw const TailscaleException('unavailable');
    allowed = peers;
  }
}

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late TamayuraRepository repository;
  late _Node node;
  late TamayuraTailscaleService service;
  late MediaRpcServer media;
  late Server discovery;
  late List<(Peer, bool)> observations;
  var opens = 0;
  var sharingAvailable = false;
  var lanReachable = false;
  Completer<void>? peerGate;
  late Completer<void> peerNotified;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tamayura-tailscale-');
    repository = await TamayuraRepository.open(
      path: '${directory.path}/catalog.db',
      factory: databaseFactoryFfi,
    );
    node = _Node();
    observations = [];
    opens = 0;
    sharingAvailable = false;
    lanReachable = false;
    peerGate = null;
    peerNotified = Completer<void>();
    media = MediaRpcServer(identity: _peer, source: MemorySource());
    await media.start();
    discovery = media.createTransportServer(identityOnly: true);
    await discovery.serve(address: InternetAddress.loopbackIPv4, port: 0);
    node.targets[tailscaleIdentityPort] = discovery.port!;
    node.targets[tailscaleMediaPort] = media.port;
    service = TamayuraTailscaleService(
      repository: repository,
      openNode: () async {
        opens++;
        return node;
      },
      identity: () => const Peer(id: 'local', name: 'Local', host: '', port: 0),
      server: () => sharingAvailable ? media : null,
      lanOnline: (_) => lanReachable,
      onPeer: (peer, online) async {
        observations.add((peer, online));
        if (!peerNotified.isCompleted) peerNotified.complete();
        await peerGate?.future;
      },
      onChanged: () {},
      pollInterval: const Duration(hours: 1),
    );
  });
  tearDown(() async {
    await service.shutdown();
    await discovery.shutdown();
    await media.stop();
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'optional login never starts a node or affects the LAN client',
    () async {
      await service.initialize();
      expect(opens, 0);
      expect(service.enabled, false);
      final client = service.createClient(
        _peer.copyWith(host: '127.0.0.1', port: media.port),
      );
      expect((await client.identity()).id, _peer.id);
      expect(client.usesTailscale, false);
      await client.close();
    },
  );

  test(
    'future configuration is retained and does not start Tailscale',
    () async {
      const future = '{"version":2,"bindings":[]}';
      await repository.setSetting(TailscaleBindings.settingKey, future);
      await service.initialize();
      expect(service.error, isA<TailscaleException>());
      expect(opens, 0);
      await expectLater(service.login(), throwsA(isA<TailscaleException>()));
      expect(await repository.getSetting(TailscaleBindings.settingKey), future);
    },
  );

  test(
    'retry replaces a failed helper and resumes without a new login',
    () async {
      await service.login();
      await service.refresh();
      final failed = node;
      failed.startBroken = true;
      node = _Node();
      await service.retry();
      expect(opens, 2);
      expect(failed.disposed, 1);
      expect(node.starts, 1);
      expect(service.enabled, true);
      expect(service.status?.state, NodeState.connected);
    },
  );

  test(
    'discovery is identity-only; a control-offline node still requires explicit association',
    () async {
      await repository.upsertPeer(_peer);
      await service.login();
      await service.refresh();
      expect(service.candidates, hasLength(1));
      expect(service.candidates.single.existingDevice, true);
      expect(service.bindings, isEmpty);
      expect(service.onlineDeviceIds, isEmpty);
      expect(observations, isEmpty);
      expect(node.dialedPorts, everyElement(tailscaleIdentityPort));

      await service.confirmCandidate(service.candidates.single.key);
      await Future<void>.delayed(Duration.zero);
      await service.refresh();
      expect(service.bindings.single.deviceId, _peer.id);
      expect(observations.first.$2, false);
      expect(service.onlineDeviceIds, contains(_peer.id));
      expect(node.dialedPorts, contains(tailscaleMediaPort));
      final client = service.createClient(_peer);
      final identity = await client.identity();
      expect(identity.host, _peer.host);
      expect(client.usesTailscale, true);
      expect((await client.listMediaPage()).items, isNotEmpty);
      await client.close();
      expect((await repository.listPeers()).single.host, _peer.host);
    },
  );

  test('discovery RPC endpoint rejects every media method', () async {
    final channel = ClientChannel(
      '127.0.0.1',
      port: discovery.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final client = wire.MediaLibraryClient(channel);
    expect((await client.getIdentity(wire.Empty())).id, _peer.id);
    final denied = isA<GrpcError>().having(
      (error) => error.code,
      'status',
      StatusCode.permissionDenied,
    );
    await expectLater(
      client.listMediaPage(wire.CatalogRequest()),
      throwsA(denied),
    );
    await expectLater(
      client.getThumbnail(wire.ThumbnailRequest(id: 'safe-id')),
      throwsA(denied),
    );
    await expectLater(
      client.readFile(wire.ReadRequest(id: 'safe-id')).toList(),
      throwsA(denied),
    );
    await channel.terminate();
  });

  test(
    'transient LAN failure selects fallback once and keeps the canonical identity',
    () async {
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      var fallbacks = 0;
      final peer = _peer.copyWith(host: '127.0.0.1', port: port);
      final client = MediaRpcClient(
        peer,
        fallbackChannel: () {
          fallbacks++;
          return ClientChannel(
            '127.0.0.1',
            port: media.port,
            options: const ChannelOptions(
              credentials: ChannelCredentials.insecure(),
            ),
          );
        },
      );
      expect((await client.identity()).port, port);
      expect(client.usesTailscale, true);
      expect((await client.listMediaPage()).items, isNotEmpty);
      expect(fallbacks, 1);
      await client.close();
    },
  );

  test(
    'identity conflict is never hidden by switching to another path',
    () async {
      var fallbacks = 0;
      final client = MediaRpcClient(
        Peer(
          id: 'different-device',
          name: 'Different',
          host: '127.0.0.1',
          port: media.port,
        ),
        fallbackChannel: () {
          fallbacks++;
          return ClientChannel('127.0.0.1', port: media.port);
        },
      );
      await expectLater(client.identity(), throwsFormatException);
      expect(fallbacks, 0);
      expect(client.usesTailscale, false);
      await client.close();
    },
  );

  test(
    'verified bridge identity rejection is permanent rather than a network retry',
    () async {
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      await service.refresh();
      node.connectionFailure = const TailscaleException('identityRejected');
      final client = service.createClient(_peer);
      await expectLater(
        client.identity(),
        throwsA(
          isA<GrpcError>()
              .having(
                (error) => error.code,
                'status',
                StatusCode.permissionDenied,
              )
              .having(isTransientTransferError, 'retryable', false),
        ),
      );
      await client.close();
    },
  );

  test(
    'logout retains settings, peers and associations but removes all usable remote routes',
    () async {
      await repository.upsertPeer(_peer);
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      lanReachable = true;
      final lan = service.createClient(
        _peer.copyWith(host: '127.0.0.1', port: media.port),
      );
      expect((await lan.identity()).id, _peer.id);
      expect(lan.usesTailscale, false);
      await service.logout();
      expect(node.logouts, 1);
      expect(service.onlineDeviceIds, isEmpty);
      expect(service.candidates, isEmpty);
      expect(service.bindings, hasLength(1));
      expect(await repository.listPeers(), hasLength(1));
      expect((await lan.listMediaPage()).items, isNotEmpty);
      await lan.close();
      expect(
        await repository.getSetting(TailscaleBindings.enabledKey),
        'false',
      );
      final client = service.createClient(_peer);
      expect(client.usesTailscale, false);
      await client.close();
      expect(
        () => service.createClient(_peer.copyWith(host: '')),
        throwsA(isA<GrpcError>()),
      );
    },
  );

  test(
    'account switch invalidates candidates and cannot reuse an old association',
    () async {
      await service.login();
      await service.refresh();
      final key = service.candidates.single.key;
      node.current = const NodeStatus(
        sessionEpoch: 'new-session',
        state: NodeState.connected,
        networkScope: 'different-network',
        selfNodeId: 'different-self',
      );
      await service.refresh();
      expect(service.candidates, isEmpty);
      await expectLater(
        service.confirmCandidate(key),
        throwsA(isA<TailscaleException>()),
      );
      expect(service.bindings, isEmpty);
    },
  );

  test(
    'media publication defaults to deny and association/revoke updates its policy',
    () async {
      sharingAvailable = true;
      await service.login();
      await service.refresh();
      final mediaLease = node.publications.singleWhere(
        (lease) => lease.port == tailscaleMediaPort,
      );
      final identityLease = node.publications.singleWhere(
        (lease) => lease.port == tailscaleIdentityPort,
      );
      expect(identityLease.allowed, {_ref});
      expect(mediaLease.allowed, isEmpty);
      await service.confirmCandidate(service.candidates.single.key);
      expect(mediaLease.allowed, {_ref});
      final active = service.createClient(_peer);
      await active.identity();
      await service.forgetDevice(_peer.id);
      await expectLater(active.listMediaPage(), throwsA(isA<GrpcError>()));
      await active.close();
      expect(mediaLease.allowed, isEmpty);
      await service.refresh();
      expect(service.candidates, isEmpty);
      expect(service.bindings, isEmpty);
      node.visible = [];
      await service.refresh();
      node.visible = [
        const TailscalePeer(
          ref: _ref,
          name: 'Remote',
          addresses: [],
          online: true,
        ),
      ];
      await service.refresh();
      expect(service.candidates, hasLength(1));
    },
  );

  test(
    'a publication completing after sharing stops is immediately closed',
    () async {
      sharingAvailable = true;
      node.publishGate = Completer<void>();
      await service.login();
      await node.publishStarted.future;
      final inFlight = service.refresh();
      await service.setSharing(false);
      node.publishGate!.complete();
      await inFlight;
      expect(node.publications, hasLength(1));
      expect(node.publications.single.closes, 1);
      expect(service.candidates, isEmpty);
    },
  );

  test(
    'polling waits until an association command finishes its host writes',
    () async {
      await service.login();
      await service.refresh();
      peerGate = Completer<void>();
      final confirming = service.confirmCandidate(
        service.candidates.single.key,
      );
      await peerNotified.future;
      expect(service.busy, true);
      final attempts = node.dialedPorts.length;
      await service.refresh();
      expect(node.dialedPorts.length, attempts);
      peerGate!.complete();
      await confirming;
      await service.refresh();
      expect(service.onlineDeviceIds, contains(_peer.id));
    },
  );

  test(
    'failed native revoke closes publications and keeps the durable revocation',
    () async {
      sharingAvailable = true;
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      await Future<void>.delayed(Duration.zero);
      await service.refresh();
      final mediaLease = node.publications.singleWhere(
        (lease) => lease.port == tailscaleMediaPort,
      );
      mediaLease.failPolicy = true;
      await expectLater(
        service.forgetDevice(_peer.id),
        throwsA(isA<TailscaleException>()),
      );
      expect(mediaLease.closes, 1);
      expect(service.bindings, isEmpty);
      expect(
        TailscaleBindings.decode(
          await repository.getSetting(TailscaleBindings.settingKey),
        ),
        isEmpty,
      );
    },
  );

  test('versioned bindings reject duplicate node and device associations', () {
    const binding = TailscaleBinding(
      deviceId: 'device',
      name: 'Device',
      ref: _ref,
    );
    expect(
      TailscaleBindings.decode(TailscaleBindings.encode([binding])).single.ref,
      _ref,
    );
    expect(
      () => TailscaleBindings.decode(
        TailscaleBindings.encode([binding, binding]),
      ),
      throwsFormatException,
    );
    expect(
      () => TailscaleBindings.decode(
        jsonEncode({
          'version': 1,
          'bindings': [
            {'deviceId': 'device'},
          ],
        }),
      ),
      throwsFormatException,
    );
  });
}
