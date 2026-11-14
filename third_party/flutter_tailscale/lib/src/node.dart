import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'control.dart';
import 'models.dart';
import 'transport.dart';

class TailscaleNode {
  TailscaleNode._(this._control);
  final BridgeControl _control;
  String? _ownerId;
  String? _sessionEpoch;
  String? _certificatePem;
  String? _privateKeyPem;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _disposeFuture;
  int _stateGeneration = 0;
  final _services = <ServiceLease>{};
  final _connections = <BridgeConnection>{};
  StreamSubscription<Object?>? _networkChanges;
  static const _android = MethodChannel('dev.fluttertailscale/network');
  static const _androidChanges = EventChannel(
    'dev.fluttertailscale/network_changes',
  );

  /// Attaches an owner without starting a node or registering an identity.
  /// [stateDirectory] must be an application-private persistent directory.
  static Future<TailscaleNode> open({
    required String stateDirectory,
    required String hostname,
    String? executablePath,
  }) async {
    if (!Directory(stateDirectory).isAbsolute || hostname.isEmpty) {
      throw const TailscaleException('invalidConfiguration');
    }
    final BridgeControl control;
    if (Platform.isAndroid) {
      control = NativeBridgeControl();
    } else if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final path =
          executablePath ??
          '${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.pathSeparator}flutter-tailscale-bridge${Platform.isWindows ? '.exe' : ''}';
      control = await ProcessBridgeControl.start(path);
    } else {
      throw const TailscaleException('unsupportedPlatform');
    }
    return initializeBridgeControl(
      control,
      stateDirectory: stateDirectory,
      hostname: hostname,
      observeAndroidNetwork: Platform.isAndroid,
    );
  }

  Future<void> _updateAndroidNetwork() async {
    if (_disposed || _closing) return;
    final value = await _android.invokeMapMethod<String, dynamic>('snapshot');
    if (value == null) throw const TailscaleException('networkUnavailable');
    await _request('networkChanged', Map<String, Object?>.from(value));
  }

  void _acceptMaterials(Map<String, dynamic> value) {
    final session = requiredString(value, 'sessionEpoch');
    if (_sessionEpoch != null && _sessionEpoch != session) {
      for (final connection in _connections.toList()) {
        unawaited(connection.close().catchError((_) {}));
      }
      for (final service in _services.toList()) {
        unawaited(service.close().catchError((_) {}));
      }
      _certificatePem = null;
      _privateKeyPem = null;
    }
    _sessionEpoch = session;
    if (value['certificatePem'] is String && value['privateKeyPem'] is String) {
      _certificatePem = value['certificatePem'] as String;
      _privateKeyPem = value['privateKeyPem'] as String;
    }
  }

  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    if (_disposed ||
        (_closing &&
            !{'dispose', 'unpublish', 'closeForward'}.contains(method))) {
      throw const TailscaleException('disposed');
    }
    return _control.request(method, {'ownerId': _ownerId, ...params});
  }

  Future<NodeStatus> _stateOperation(String method) async {
    final generation = ++_stateGeneration;
    final value = await _request(method);
    if (_disposed || _closing || generation != _stateGeneration) {
      throw const TailscaleException('sessionChanged');
    }
    _acceptMaterials(value);
    return NodeStatus.fromJson(value);
  }

  Future<NodeStatus> start() => _stateOperation('start');
  Future<NodeStatus> login() => _stateOperation('login');
  Future<NodeStatus> status() => _stateOperation('status');

  Future<List<TailscalePeer>> peers() async {
    final value = await _request('peers');
    if (value['sessionEpoch'] != _sessionEpoch) {
      throw const TailscaleException('sessionChanged');
    }
    try {
      return List.unmodifiable(
        (value['peers'] as List).map(
          (item) =>
              TailscalePeer.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      );
    } catch (_) {
      throw const TailscaleException('invalidResponse');
    }
  }

  Future<BridgeConnection> openTcp(PeerRef peer, {required int port}) async {
    _checkPort(port);
    final session = _sessionEpoch;
    final value = await _request('openForward', {
      'peer': peer.toJson(),
      'port': port,
      'sessionEpoch': session,
    });
    final descriptor = ForwardDescriptor.fromJson(value);
    Future<void> release() async {
      if (_disposed) return;
      try {
        await _request('closeForward', {
          'forwardId': descriptor.forwardId,
          'sessionEpoch': descriptor.sessionEpoch,
        });
      } on TailscaleException catch (error) {
        if (error.code != 'sessionChanged' &&
            error.code != 'invalidSession' &&
            error.code != 'runtimeStopped') {
          rethrow;
        }
      }
    }

    if (_disposed ||
        _closing ||
        descriptor.sessionEpoch != session ||
        session != _sessionEpoch) {
      await release();
      throw const TailscaleException('sessionChanged');
    }
    final connection = await connectForward(descriptor, release: release);
    if (_disposed || _closing || session != _sessionEpoch) {
      await connection.close();
      throw const TailscaleException('sessionChanged');
    }
    _connections.add(connection);
    unawaited(
      connection.done.whenComplete(() => _connections.remove(connection)),
    );
    return connection;
  }

  /// Publishes an mTLS-protected local listener. Only Go's current session may
  /// deliver streams; Go verifies the real tailnet source against [allowedPeers].
  Future<ServiceLease> publishTcp({
    required int port,
    required Set<PeerRef> allowedPeers,
    required void Function(BridgeConnection) onConnection,
  }) async {
    _checkPort(port);
    if (_certificatePem == null || _privateKeyPem == null) {
      throw const TailscaleException('sessionChanged');
    }
    final session = _sessionEpoch!;
    final certificate = _certificatePem!;
    final digest = certificateDigest(certificate);
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(_privateKeyPem!))
      ..setTrustedCertificatesBytes(utf8.encode(certificate));
    final listener = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requireClientCertificate: true,
      requestClientCertificate: true,
    );
    final connections = <BridgeConnection>{};
    var accepting = true;
    final subscription = listener.listen((socket) {
      if (!accepting ||
          _disposed ||
          _closing ||
          _sessionEpoch != session ||
          socket.peerCertificate == null ||
          sha256.convert(socket.peerCertificate!.der).toString() != digest) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      final connection = BridgeConnection.fromSocket(socket);
      connections.add(connection);
      unawaited(
        connection.done.whenComplete(() => connections.remove(connection)),
      );
      try {
        onConnection(connection);
      } catch (_) {
        unawaited(connection.close());
      }
    }, onError: (_) {});
    try {
      final value = await _request('publish', {
        'sessionEpoch': session,
        'port': port,
        'targetPort': listener.port,
        'targetCertificatePem': certificate,
        'allowedPeers': allowedPeers.map((peer) => peer.toJson()).toList(),
      });
      final lease = ServiceLease._(
        this,
        requiredString(value, 'serviceId'),
        session,
        listener,
        subscription,
        connections,
        () => accepting = false,
      );
      if (_disposed ||
          _closing ||
          session != _sessionEpoch ||
          value['sessionEpoch'] != session) {
        await lease.close();
        throw const TailscaleException('sessionChanged');
      }
      _services.add(lease);
      return lease;
    } catch (_) {
      await listener.close();
      await subscription.cancel();
      for (final connection in connections.toList()) {
        await connection.close();
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    ++_stateGeneration;
    try {
      await _closeResources();
    } finally {
      _acceptMaterials(await _request('stop'));
    }
  }

  Future<void> logout() async {
    ++_stateGeneration;
    try {
      await _closeResources();
    } finally {
      _acceptMaterials(await _request('logout'));
    }
  }

  Future<void> _closeResources() async {
    await Future.wait([
      ..._services.toList().map((s) => s.close()),
      ..._connections.toList().map((s) => s.close()),
    ]);
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _closing = true;
    ++_stateGeneration;
    try {
      await _networkChanges?.cancel();
      try {
        await _closeResources();
      } finally {
        await _request('dispose');
      }
    } finally {
      _disposed = true;
      _certificatePem = null;
      _privateKeyPem = null;
      await _control.close();
    }
  }
}

void _checkPort(int port) {
  if (port < 1 || port > 65535) throw const TailscaleException('invalidPort');
}

class ServiceLease {
  ServiceLease._(
    this._node,
    this._id,
    this._session,
    this._listener,
    this._subscription,
    this._connections,
    this._stopAccepting,
  );
  final TailscaleNode _node;
  final String _id, _session;
  final SecureServerSocket _listener;
  final StreamSubscription<SecureSocket> _subscription;
  final Set<BridgeConnection> _connections;
  final void Function() _stopAccepting;
  Future<void>? _closing;

  Future<void> updatePolicy(Set<PeerRef> allowedPeers) async {
    if (_closing != null) throw const TailscaleException('leaseClosed');
    await _node._request('updatePolicy', {
      'serviceId': _id,
      'sessionEpoch': _session,
      'allowedPeers': allowedPeers.map((peer) => peer.toJson()).toList(),
    });
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    // Stop exposing the service locally before a native control response. The
    // helper may be stalled, but revocation cannot leave app streams alive.
    _stopAccepting();
    final localClose = Future.wait([
      _listener.close(),
      _subscription.cancel(),
      ..._connections.toList().map((connection) => connection.close()),
    ]);
    try {
      try {
        await localClose;
      } finally {
        if (!_node._disposed) {
          await _node._request('unpublish', {
            'serviceId': _id,
            'sessionEpoch': _session,
          });
        }
      }
    } on TailscaleException catch (error) {
      if (!{
        'sessionChanged',
        'invalidSession',
        'runtimeStopped',
        'invalidOwner',
      }.contains(error.code)) {
        rethrow;
      }
    } finally {
      _node._services.remove(this);
    }
  }
}

/// Internal initialization seam shared with native-control contract tests.
/// The public library exports only TailscaleNode and ServiceLease.
Future<TailscaleNode> initializeBridgeControl(
  BridgeControl control, {
  required String stateDirectory,
  required String hostname,
  bool observeAndroidNetwork = false,
}) async {
  final node = TailscaleNode._(control);
  try {
    final initialized = await control.request('initialize', {
      'protocolVersion': 1,
      'stateDirectory': stateDirectory,
      'hostname': hostname,
    });
    node._ownerId = requiredString(initialized, 'ownerId');
    final capabilities = initialized['capabilities'];
    if (initialized['protocolVersion'] != 1 ||
        capabilities is! List ||
        !{
          'tcp',
          'localMutualTls',
          'explicitPeerPolicy',
          'owners',
        }.every(capabilities.contains)) {
      throw const TailscaleException('incompatibleProtocol');
    }
    node._acceptMaterials(initialized);
    if (observeAndroidNetwork) {
      await node._updateAndroidNetwork();
      node._networkChanges = TailscaleNode._androidChanges
          .receiveBroadcastStream()
          .listen(
            (_) => unawaited(node._updateAndroidNetwork().catchError((_) {})),
            onError: (_) {},
          );
    }
    return node;
  } catch (_) {
    if (node._ownerId != null) {
      try {
        await node._request('dispose');
      } catch (_) {}
    }
    await control.close();
    rethrow;
  }
}
