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

  /// Nodes other than [_ref] that answer, by virtual port.
  final Map<PeerRef, Map<int, int>> otherNodes = {};

  /// False once the node behind [_ref] is gone, as after it signed out.
  bool refAnswers = true;
  final List<int> dialedPorts = [];
  int starts = 0, logouts = 0, disposed = 0, statusReads = 0;
  bool startBroken = false;
  TailscaleException? connectionFailure;

  /// Thrown by the next status read only.
  TailscaleException? statusFailure;
  Completer<NodeStatus>? statusGate;
  Completer<void>? peersGate;
  int peerReads = 0;

  /// Replaces [current] while set: a node that is starting or signing in.
  NodeStatus Function()? liveStatus;
  NodeStatus get _status => liveStatus?.call() ?? current;
  Completer<void>? publishGate;
  final publishStarted = Completer<void>();
  final List<_Lease> publications = [];

  @override
  Future<NodeStatus> start() async {
    starts++;
    if (startBroken) throw const TailscaleException('runtimeStopped');
    return _status;
  }

  @override
  Future<NodeStatus> login() async => _status;
  @override
  Future<NodeStatus> status() async {
    statusReads++;
    final failure = statusFailure;
    statusFailure = null;
    if (failure != null) throw failure;
    return statusGate == null ? _status : statusGate!.future;
  }

  @override
  Future<List<TailscalePeer>> peers() async {
    peerReads++;
    final snapshot = visible;
    await peersGate?.future;
    return snapshot;
  }

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
    final ports = ref == _ref ? (refAnswers ? targets : null) : otherNodes[ref];
    if (ports == null || ref.networkScope != current.networkScope) {
      throw const TailscaleException('peerUnavailable');
    }
    dialedPorts.add(port);
    final target = ports[port];
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

const _successor = PeerRef(networkScope: 'test-network', nodeId: 'new-node');
const _starting = NodeStatus(
  sessionEpoch: 'session-one',
  state: NodeState.connecting,
);
const _registeredStarting = NodeStatus(
  sessionEpoch: 'session-one',
  state: NodeState.connecting,
  networkScope: 'test-network',
  selfNodeId: 'local-node',
  controlState: NodeControlState.connected,
);

Future<void> _eventually(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('The expected state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
  final lanUnanswered = <String>[];
  Completer<void>? peerGate;
  late Completer<void> peerNotified;

  TamayuraTailscaleService build({
    Duration settle = const Duration(milliseconds: 500),
    Duration route = const Duration(seconds: 15),
    bool transferEngine = false,
  }) => TamayuraTailscaleService(
    repository: repository,
    openNode: () async {
      opens++;
      return node;
    },
    identity: () => const Peer(id: 'local', name: 'Local', host: '', port: 0),
    server: () => sharingAvailable ? media : null,
    // A transfer engine has checked no LAN address: it tries them first.
    lanFirst: (_) => transferEngine || lanReachable,
    onLanUnanswered: lanUnanswered.add,
    onPeer: (peer, online) async {
      observations.add((peer, online));
      if (!peerNotified.isCompleted) peerNotified.complete();
      await peerGate?.future;
    },
    onChanged: () {},
    pollInterval: const Duration(hours: 1),
    settleInterval: settle,
    routeTimeout: route,
    // As lib/background/transfer_worker.dart builds it.
    discoveryEnabled: !transferEngine,
  );

  /// Replaces the service of [setUp]; [tearDown] shuts the new one down.
  Future<void> rebuild({
    Duration settle = const Duration(milliseconds: 20),
    Duration route = const Duration(seconds: 15),
    bool transferEngine = false,
  }) async {
    await service.shutdown();
    service = build(
      settle: settle,
      route: route,
      transferEngine: transferEngine,
    );
  }

  /// A node that reports no registration scope until [ready] has passed.
  ///
  /// Only for tests whose assertions hold whether or not the node has
  /// registered by the time they run: a slow machine can overtake any delay on
  /// the wall clock. A test that asserts the starting state uses
  /// [holdRegistration].
  void startCold(Duration ready) {
    final watch = Stopwatch()..start();
    node.liveStatus = () => watch.elapsed < ready ? _starting : node.current;
  }

  /// A node that reports no registration scope, as while it starts, until the
  /// returned function is called. The test decides when the network map
  /// arrives, so no assertion about the starting state depends on how long the
  /// code under test takes to run.
  void Function() holdRegistration() {
    var registered = false;
    node.liveStatus = () => registered ? node.current : _starting;
    return () {
      registered = true;
    };
  }

  Future<void> saveAssociation() async {
    await repository.setSetting(TailscaleBindings.enabledKey, 'true');
    await repository.setSetting(
      TailscaleBindings.settingKey,
      TailscaleBindings.encode([
        TailscaleBinding(deviceId: _peer.id, name: _peer.name, ref: _ref),
      ]),
    );
  }

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
    lanUnanswered.clear();
    peerGate = null;
    peerNotified = Completer<void>();
    media = MediaRpcServer(identity: _peer, source: MemorySource());
    await media.start();
    discovery = media.createTransportServer(identityOnly: true);
    await discovery.serve(address: InternetAddress.loopbackIPv4, port: 0);
    node.targets[tailscaleIdentityPort] = discovery.port!;
    node.targets[tailscaleMediaPort] = media.port;
    service = build();
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

  test(
    'diagnostics count visible nodes separately from actual port responses',
    () async {
      final remote = node.visible.single;
      TailscalePeer controlOnline(String scope, String id) => TailscalePeer(
        ref: PeerRef(networkScope: scope, nodeId: id),
        name: 'Node',
        online: true,
        addresses: const [],
      );
      node.visible = [
        remote,
        remote,
        controlOnline('test-network', 'local-node'),
        controlOnline('test-network', 'ordinary-node'),
        controlOnline('different-network', 'foreign-node'),
      ];
      sharingAvailable = true;
      node.peersGate = Completer();
      node.publishGate = Completer();
      expect(service.diagnostics, isNull);
      await service.login();
      expect(service.diagnostics, (
        visibleNodes: null,
        respondingNodes: null,
        sharingReady: false,
      ));
      node.peersGate!.complete();
      await node.publishStarted.future;
      expect(service.diagnostics, (
        visibleNodes: 2,
        respondingNodes: null,
        sharingReady: false,
      ));
      node.publishGate!.complete();
      await service.refresh();
      expect(service.diagnostics, (
        visibleNodes: 2,
        respondingNodes: 1,
        sharingReady: true,
      ));
      expect(service.onlineDeviceIds, isEmpty);

      // Once associated, only the media port's response counts. Its remote
      // policy may still deny us until the other device confirms.
      node.peersGate = Completer();
      node.targets.remove(tailscaleMediaPort);
      await service.confirmCandidate(service.candidates.single.key);
      expect(service.diagnostics?.respondingNodes, isNull);
      node.peersGate!.complete();
      await service.refresh();
      expect(service.diagnostics?.respondingNodes, 0);
      expect(service.onlineDeviceIds, isEmpty);
      node.targets[tailscaleMediaPort] = media.port;
      await service.refresh();
      expect(service.diagnostics?.respondingNodes, 1);

      // A bound node absent from the map can still answer a direct probe.
      node.visible = [];
      await service.refresh();
      expect(service.onlineDeviceIds, contains(_peer.id));
      expect(service.diagnostics, (
        visibleNodes: 0,
        respondingNodes: 0,
        sharingReady: true,
      ));
      await service.setSharing(false);
      expect(service.diagnostics?.sharingReady, isFalse);
      await service.logout();
      expect(service.diagnostics, isNull);
    },
  );

  test(
    'a delayed scan cannot expose results from a previous session',
    () async {
      sharingAvailable = true;
      await service.login();
      await service.refresh();
      expect(service.diagnostics?.respondingNodes, 1);

      final oldScan = Completer<void>();
      node.peersGate = oldScan;
      final previousReads = node.peerReads;
      final oldRefresh = service.refresh();
      await _eventually(() => node.peerReads > previousReads);
      node.current = const NodeStatus(
        sessionEpoch: 'new-session',
        state: NodeState.connected,
        networkScope: 'another-network',
        selfNodeId: 'another-local-node',
      );
      node.visible = [];
      node.peersGate = Completer();
      await service.retry();
      expect(service.diagnostics, (
        visibleNodes: null,
        respondingNodes: null,
        sharingReady: false,
      ));
      oldScan.complete();
      await oldRefresh;
      expect(service.diagnostics?.visibleNodes, isNull);
      expect(service.diagnostics?.respondingNodes, isNull);
      node.peersGate!.complete();
      await service.refresh();
      expect(service.diagnostics, (
        visibleNodes: 0,
        respondingNodes: 0,
        sharingReady: true,
      ));
    },
  );

  test(
    'identity deadlines allow cold Tailscale connections on both ports',
    () async {
      final deadlines = <Duration?>[];
      final endpoint = Server.create(
        services: [discovery.lookupService('tamayura.v1.MediaLibrary')!],
        interceptors: [
          (call, method) {
            deadlines.add(
              fromTimeoutString(call.clientMetadata?['grpc-timeout']),
            );
            return null;
          },
        ],
      );
      await endpoint.serve(address: InternetAddress.loopbackIPv4, port: 0);
      addTearDown(endpoint.shutdown);
      final lan = MediaRpcClient(
        _peer.copyWith(host: '127.0.0.1', port: endpoint.port!),
      );
      addTearDown(lan.close);
      await lan.identity();
      expect(deadlines.single, const Duration(seconds: 8));
      deadlines.clear();

      node.targets[tailscaleIdentityPort] = endpoint.port!;
      node.targets[tailscaleMediaPort] = endpoint.port!;
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      await service.refresh();
      expect(service.onlineDeviceIds, contains(_peer.id));
      final remote = service.createClient(_peer);
      addTearDown(remote.close);
      await remote.identity();
      expect(deadlines, isNotEmpty);
      expect(deadlines, everyElement(const Duration(seconds: 40)));
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

  test('without a remote route the LAN failure is the result', () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    var fallbacks = 0;
    final client = MediaRpcClient(
      _peer.copyWith(host: '127.0.0.1', port: port),
      fallbackChannel: () async {
        fallbacks++;
        return null;
      },
    );
    await expectLater(
      client.identity(),
      throwsA(
        isA<GrpcError>()
            .having((error) => error.code, 'status', StatusCode.unavailable)
            .having(isTransientTransferError, 'retryable', true),
      ),
    );
    expect(fallbacks, 1);
    expect(client.usesTailscale, false);
    await client.close();
  });

  test('a remote-only client never dials the LAN address', () async {
    // If the LAN address were dialed, its different identity would fail the
    // attempt instead of the approved route answering.
    final other = MediaRpcServer(
      identity: const Peer(id: 'another', name: 'Another', host: '', port: 0),
      source: MemorySource(),
    );
    await other.start();
    addTearDown(other.stop);
    final client = MediaRpcClient(
      _peer.copyWith(host: '127.0.0.1', port: other.port),
      remoteOnly: true,
      fallbackChannel: () async => ClientChannel(
        '127.0.0.1',
        port: media.port,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      ),
    );
    expect(client.usesTailscale, false);
    final identity = await client.identity();
    expect(identity.id, _peer.id);
    expect(identity.port, other.port);
    expect(client.usesTailscale, true);
    expect((await client.listMediaPage()).items, isNotEmpty);
    await client.close();
    // Closing before any route was resolved must not fail either.
    final idle = MediaRpcClient(
      _peer.copyWith(host: ''),
      remoteOnly: true,
      fallbackChannel: () => null,
    );
    await idle.close();
    await expectLater(idle.identity(), throwsA(isA<GrpcError>()));
  });

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

  test(
    'a node that registered again succeeds its association only once confirmed',
    () async {
      await repository.upsertPeer(_peer);
      sharingAvailable = true;
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      await Future<void>.delayed(Duration.zero);
      await service.refresh();
      expect(service.onlineDeviceIds, contains(_peer.id));
      final mediaLease = node.publications.singleWhere(
        (lease) => lease.port == tailscaleMediaPort,
      );
      final previousRoute = service.createClient(_peer);
      await previousRoute.identity();
      expect(previousRoute.usesTailscale, true);

      // The remote device signed in again: the same Tamayura identity behind
      // a new node, while the associated node is gone.
      node.refAnswers = false;
      node.otherNodes[_successor] = Map.of(node.targets);
      node.visible = [
        const TailscalePeer(
          ref: _successor,
          name: 'Remote',
          addresses: ['100.64.0.2'],
          online: true,
        ),
      ];
      await service.refresh();
      expect(service.error, isNull);
      expect(service.onlineDeviceIds, isEmpty);
      final candidate = service.candidates.single;
      expect(candidate.ref, _successor);
      expect(candidate.replaces, _ref);
      expect(candidate.existingDevice, true);
      // Reporting the identity moves nothing by itself.
      expect(service.bindings.single.ref, _ref);
      expect(mediaLease.allowed, {_ref});
      await service.refresh();
      expect(service.candidates.single.key, candidate.key);

      await service.confirmCandidate(candidate.key);
      expect(service.bindings.single.ref, _successor);
      expect(service.bindings.single.deviceId, _peer.id);
      expect(mediaLease.allowed, {_successor});
      await expectLater(
        previousRoute.listMediaPage(),
        throwsA(isA<GrpcError>()),
      );
      await previousRoute.close();
      expect(
        TailscaleBindings.decode(
          await repository.getSetting(TailscaleBindings.settingKey),
        ).single.ref,
        _successor,
      );
      await Future<void>.delayed(Duration.zero);
      await service.refresh();
      expect(service.candidates, isEmpty);
      expect(service.error, isNull);
      expect(service.onlineDeviceIds, contains(_peer.id));
      final client = service.createClient(_peer);
      expect((await client.identity()).id, _peer.id);
      expect(client.usesTailscale, true);
      await client.close();
      expect((await repository.listPeers()).single.host, _peer.host);
    },
  );

  test(
    'a second node reporting an associated identity is a conflict while the first answers',
    () async {
      await service.login();
      await service.refresh();
      await service.confirmCandidate(service.candidates.single.key);
      await Future<void>.delayed(Duration.zero);
      await service.refresh();
      node.otherNodes[_successor] = Map.of(node.targets);
      node.visible = [
        ...node.visible,
        const TailscalePeer(
          ref: _successor,
          name: 'Other',
          addresses: ['100.64.0.2'],
          online: true,
        ),
      ];
      await service.refresh();
      expect((service.error as TailscaleException).code, 'identityConflict');
      // It is not offered: the associated node is demonstrably still there.
      expect(service.candidates, isEmpty);
      expect(service.bindings.single.ref, _ref);
      expect(service.onlineDeviceIds, contains(_peer.id));
      await service.refresh();
      expect((service.error as TailscaleException).code, 'identityConflict');

      // The report ends with the condition, without a manual retry.
      node.visible = [node.visible.first];
      node.otherNodes.clear();
      await service.refresh();
      expect(service.error, isNull);
      expect(service.onlineDeviceIds, contains(_peer.id));
    },
  );

  test(
    'start-up is followed closely until the node reports its registration',
    () async {
      await rebuild();
      final register = holdRegistration();
      await service.login();
      expect(service.status?.registered, false);
      register();
      // No manual refresh: the regular interval of this service is an hour.
      await _eventually(() => service.status?.registered ?? false);
      await _eventually(() => service.candidates.isNotEmpty);
      final settled = node.statusReads;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(node.statusReads, settled);
    },
  );

  test(
    'a registered node waits for Running before discovery and publication',
    () async {
      await rebuild();
      node.liveStatus = () => _registeredStarting;
      sharingAvailable = true;
      await service.login();
      await service.refresh();
      expect(service.status?.registered, true);
      expect(node.peerReads, 0);
      expect(node.publications, isEmpty);
      expect(service.error, isNull);

      // A running data plane can discover and share using its network map
      // even while its connection to control is interrupted.
      node.current = const NodeStatus(
        sessionEpoch: 'session-one',
        state: NodeState.connected,
        networkScope: 'test-network',
        selfNodeId: 'local-node',
        controlState: NodeControlState.disconnected,
      );
      node.liveStatus = null;
      // With a regular poll interval of one hour, only fast polling can
      // discover the device in time.
      await _eventually(() => service.candidates.isNotEmpty);
      expect(node.publications.map((lease) => lease.port), [
        tailscaleIdentityPort,
        tailscaleMediaPort,
      ]);
    },
  );

  test(
    'an authentication URL is noticed without waiting for the regular interval',
    () async {
      await rebuild();
      // The sign-in page is announced when the test says so, not after a delay
      // that a slow machine could overtake.
      var announced = false;
      node.liveStatus = () => NodeStatus(
        sessionEpoch: 'session-one',
        state: NodeState.authorizing,
        authUrl: announced
            ? Uri.parse('https://login.tailscale.com/a/test')
            : null,
      );
      await service.login();
      expect(service.status?.authUrl, isNull);
      announced = true;
      await _eventually(() => service.status?.authUrl != null);
      // Signing in is noticed the same way.
      node.liveStatus = null;
      await _eventually(() => service.status?.registered ?? false);
    },
  );

  test(
    'a failure before sign-in completes ends with the next status read',
    () async {
      await rebuild();
      node.liveStatus = () => const NodeStatus(
        sessionEpoch: 'session-one',
        state: NodeState.authorizing,
      );
      await service.login();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      node.statusFailure = const TailscaleException('statusUnavailable');
      await _eventually(() => service.error != null);
      await _eventually(() => service.error == null);
      expect(service.status?.state, NodeState.authorizing);
    },
  );

  test(
    'a transfer engine waits for Running even after the scope arrives',
    () async {
      await saveAssociation();
      await rebuild(transferEngine: true);
      node.liveStatus = () => _starting;
      await service.initialize();
      expect(service.status?.networkScope, isNull);
      // The scope is unknown, so the association cannot be matched yet. The
      // job may still be scheduled, and the route must not fail outright.
      expect(service.hasAssociation(_peer.id), true);
      final remoteOnly = service.createClient(_peer.copyWith(host: ''));
      expect(remoteOnly.usesTailscale, false);
      final identity = remoteOnly.identity();
      node.liveStatus = () => _registeredStarting;
      await _eventually(() => service.status?.registered == true);
      expect(service.hasAssociation(_peer.id), true);
      final reads = node.statusReads;
      await _eventually(() => node.statusReads > reads);
      expect(node.dialedPorts, isEmpty);
      node.liveStatus = null;
      expect((await identity).id, _peer.id);
      expect(remoteOnly.usesTailscale, true);
      expect((await remoteOnly.listMediaPage()).items, isNotEmpty);
      await remoteOnly.close();
      expect(service.status?.registered, true);
      expect(node.dialedPorts, everyElement(tailscaleMediaPort));
    },
  );

  test('a starting node is also awaited after the LAN address fails', () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    await saveAssociation();
    await rebuild(transferEngine: true);
    startCold(const Duration(milliseconds: 300));
    await service.initialize();
    final client = service.createClient(
      _peer.copyWith(host: '127.0.0.1', port: port),
    );
    final identity = await client.identity();
    expect(identity.id, _peer.id);
    // The remembered LAN address is kept; only the route changed.
    expect(identity.port, port);
    expect(client.usesTailscale, true);
    await client.close();
    // The host learns that the address did not answer, so that it can route
    // the device's next operation directly.
    expect(lanUnanswered, [_peer.id]);
    lanUnanswered.clear();
    await rebuild();
    await service.initialize();
    expect(service.status?.registered, true);
    final direct = service.createClient(
      _peer.copyWith(host: '127.0.0.1', port: port),
    );
    expect((await direct.identity()).id, _peer.id);
    expect(direct.usesTailscale, true);
    // No LAN attempt was made this time, so there is nothing to report.
    expect(lanUnanswered, isEmpty);
    await direct.close();
  });

  test(
    'an operation begun while the saved sign-in resumes still finds its remote route',
    () async {
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      await saveAssociation();
      await rebuild();
      startCold(const Duration(milliseconds: 150));
      // Not awaited, as the app's start-up does: its first synchronization
      // creates its connections before the saved state has even been read.
      final restoring = service.initialize();
      final remoteOnly = service.createClient(_peer.copyWith(host: ''));
      final lanFirst = service.createClient(
        _peer.copyWith(host: '127.0.0.1', port: port),
      );
      expect(opens, 0);
      expect((await remoteOnly.identity()).id, _peer.id);
      expect(remoteOnly.usesTailscale, true);
      expect((await lanFirst.identity()).port, port);
      expect(lanFirst.usesTailscale, true);
      expect(lanUnanswered, [_peer.id]);
      await remoteOnly.close();
      await lanFirst.close();
      await restoring;
    },
  );

  test(
    'an operation begun before a signed-out service has loaded keeps its LAN result',
    () async {
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      await rebuild();
      final restoring = service.initialize();
      final reachable = service.createClient(
        _peer.copyWith(host: '127.0.0.1', port: media.port),
      );
      final unreachable = service.createClient(
        _peer.copyWith(host: '127.0.0.1', port: port),
      );
      final remoteOnly = service.createClient(_peer.copyWith(host: ''));
      expect((await reachable.identity()).id, _peer.id);
      expect(reachable.usesTailscale, false);
      final unavailable = throwsA(
        isA<GrpcError>()
            .having((error) => error.code, 'status', StatusCode.unavailable)
            .having(isTransientTransferError, 'retryable', true),
      );
      await expectLater(unreachable.identity(), unavailable);
      expect(unreachable.usesTailscale, false);
      await expectLater(remoteOnly.identity(), unavailable);
      await reachable.close();
      await unreachable.close();
      await remoteOnly.close();
      await restoring;
      // Signed out: no node was started for any of them.
      expect(opens, 0);
      expect(service.enabled, false);
    },
  );

  for (final starting in [_starting, _registeredStarting]) {
    test(
      'a starting node times out without dialing with scope ${starting.networkScope}',
      () async {
        await saveAssociation();
        await rebuild(
          route: const Duration(milliseconds: 150),
          transferEngine: true,
        );
        node.liveStatus = () => starting;
        await service.initialize();
        final client = service.createClient(_peer.copyWith(host: ''));
        final watch = Stopwatch()..start();
        await expectLater(
          client.identity(),
          throwsA(
            isA<GrpcError>()
                .having((error) => error.code, 'status', StatusCode.unavailable)
                .having(isTransientTransferError, 'retryable', true),
          ),
        );
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 150)),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(node.dialedPorts, isEmpty);
        expect(client.usesTailscale, false);
        await client.close();
      },
    );
  }

  test('closing a client ends its wait for a starting node', () async {
    await saveAssociation();
    await rebuild(route: const Duration(minutes: 1), transferEngine: true);
    node.liveStatus = () => _starting;
    await service.initialize();
    final client = service.createClient(_peer.copyWith(host: ''));
    final watch = Stopwatch()..start();
    final waiting = expectLater(
      client.identity(),
      throwsA(
        isA<GrpcError>().having(
          (error) => error.code,
          'status',
          StatusCode.cancelled,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.close();
    await waiting;
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
    'an association made under another registration is not routable',
    () async {
      await repository.setSetting(TailscaleBindings.enabledKey, 'true');
      await repository.setSetting(
        TailscaleBindings.settingKey,
        TailscaleBindings.encode([
          TailscaleBinding(
            deviceId: _peer.id,
            name: _peer.name,
            ref: const PeerRef(networkScope: 'earlier-login', nodeId: 'node'),
          ),
        ]),
      );
      await rebuild(transferEngine: true);
      final register = holdRegistration();
      await service.initialize();
      expect(service.hasAssociation(_peer.id), true);
      final client = service.createClient(_peer.copyWith(host: ''));
      final unavailable = expectLater(
        client.identity(),
        throwsA(
          isA<GrpcError>().having(
            (error) => error.code,
            'status',
            StatusCode.unavailable,
          ),
        ),
      );
      // The route waits on the starting node; only then does it register.
      final reads = node.statusReads;
      await _eventually(() => node.statusReads > reads);
      register();
      await unavailable;
      await client.close();
      // Once the scope is known the stale association no longer counts.
      expect(service.status?.registered, true);
      expect(service.hasAssociation(_peer.id), false);
      expect(node.dialedPorts, isEmpty);
      expect(
        () => service.createClient(_peer.copyWith(host: '')),
        throwsA(isA<GrpcError>()),
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
