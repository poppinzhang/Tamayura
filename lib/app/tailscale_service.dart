import 'dart:async';
import 'dart:convert';

import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_tailscale/grpc.dart';
import 'package:grpc/grpc.dart';

import '../core/models.dart';
import '../data/repository.dart';
import '../network/media_rpc.dart';
import 'tailscale_bindings.dart';

export 'tailscale_bindings.dart' show TailscaleBinding;

const tailscaleMediaPort = 50728;
const tailscaleIdentityPort = 50729;

Object _transportError(Object error, TailscaleChannel? channel) {
  if (error is! GrpcError ||
      !const {
        StatusCode.unavailable,
        StatusCode.unknown,
        StatusCode.deadlineExceeded,
      }.contains(error.code)) {
    return error;
  }
  final failure = channel?.lastConnectionFailure;
  if (failure != null &&
      const {
        'identityRejected',
        'localAuthorizationFailed',
        'serverIdentityMismatch',
        'targetIdentityMismatch',
        'invalidCertificate',
      }.contains(failure.code)) {
    return const GrpcError.permissionDenied(
      'Tailscale identity or authorization was rejected',
    );
  }
  return error;
}

class TailscaleCandidate {
  const TailscaleCandidate({
    required this.peer,
    required this.ref,
    required this.existingDevice,
    this.replaces,
  });
  final Peer peer;
  final PeerRef ref;
  final bool existingDevice;

  /// The node this device is associated with at present. It does not answer
  /// as the device any more, as after the remote device signed in again and
  /// registered a new node. Confirming moves the association to [ref] and
  /// revokes this node; nothing is moved without that confirmation.
  final PeerRef? replaces;
  String get key => jsonEncode([ref.networkScope, ref.nodeId, peer.id]);
}

/// What one discovery pass established, applied once all its probes finish.
class _Sweep {
  /// Keys of the candidates found, so that vanished ones are dropped.
  final seen = <String>{};

  /// Devices whose associated node answered with the expected identity.
  final verified = <String>{};

  /// Unassociated nodes reporting a device associated with another node.
  final claims = <TailscaleCandidate>[];
  var conflict = false;
}

/// Optional Tailscale lifecycle, explicit device associations and RPC routing.
/// The host retains its LAN discovery, synchronization policy and media data.
class TamayuraTailscaleService {
  TamayuraTailscaleService({
    required this.repository,
    required this.openNode,
    required this.identity,
    required this.server,
    required this.lanFirst,
    this.onLanUnanswered,
    required this.onPeer,
    required this.onChanged,
    this.pollInterval = const Duration(seconds: 15),
    this.settleInterval = const Duration(milliseconds: 500),
    this.routeTimeout = const Duration(seconds: 15),
    this.discoveryEnabled = true,
  });

  final TamayuraRepository repository;
  final Future<TailscaleNode> Function() openNode;
  final Peer Function() identity;
  final MediaRpcServer? Function() server;

  /// Whether a new operation tries the device's LAN address before its remote
  /// route: it answered there, or has not been tried there yet. A device that
  /// did not answer goes straight to the remote route, without the timeout.
  final bool Function(String deviceId) lanFirst;

  /// A device's LAN address was tried and its remote route takes over. The
  /// host records it, so that [lanFirst] spares later operations the wait.
  final void Function(String deviceId)? onLanUnanswered;
  final Future<void> Function(Peer peer, bool online) onPeer;
  final void Function() onChanged;
  final Duration pollInterval;

  /// The first interval between status reads while the node starts or signs
  /// in. See [_pollDelay].
  final Duration settleInterval;

  /// How long a new route waits for a starting node. See [_awaitRegistration].
  final Duration routeTimeout;
  final bool discoveryEnabled;

  TailscaleNode? _node;
  NodeStatus? _status;
  NodeStatus? get status => _status;
  bool _enabled = false;
  bool get enabled => _enabled;
  bool _busy = false;
  bool get busy => _busy;
  Object? _error;
  Object? get error => _error;
  bool _validConfiguration = true;
  bool _sharing = true;
  bool _closed = false;
  int _generation = 0;
  Timer? _timer;
  int _settlingPolls = 0;

  /// Set while [initialize] runs.
  Future<void>? _restoring;
  Future<void>? _refreshing;
  Future<void> _commands = Future.value();
  final List<TailscaleBinding> _bindings = [];
  final Map<String, TailscaleCandidate> _candidates = {};
  final Set<String> _online = {};
  final Set<PeerRef> _suppressed = {};
  final Set<MediaRpcClient> _clients = {};
  List<TailscaleBinding> get bindings => List.unmodifiable(_bindings);
  List<TailscaleCandidate> get candidates =>
      List.unmodifiable(_candidates.values);
  Set<String> get onlineDeviceIds => Set.unmodifiable(_online);
  ServiceLease? _identityLease, _mediaLease;
  Server? _identityServer, _mediaServer;
  MediaRpcServer? _publishedSource;

  /// Loads the saved associations and resumes a saved sign-in. The host does
  /// not wait for it before its own start-up work; see [createClient].
  Future<void> initialize() =>
      _restoring ??= _restore().whenComplete(() => _restoring = null);

  Future<void> _restore() async {
    try {
      _bindings.addAll(
        TailscaleBindings.decode(
          await repository.getSetting(TailscaleBindings.settingKey),
        ),
      );
      final enabled = await repository.getSetting(TailscaleBindings.enabledKey);
      if (enabled != null && enabled != 'true' && enabled != 'false') {
        throw const TailscaleException('invalidConfiguration');
      }
      _enabled = enabled == 'true';
    } catch (_) {
      _validConfiguration = false;
      _error = const TailscaleException('invalidConfiguration');
      _changed();
      return;
    }
    if (!_enabled || _closed) return;
    try {
      await retry();
    } catch (_) {
      // Tailscale startup never prevents the host's LAN startup.
    }
  }

  Future<void> _command(Future<void> Function() action) {
    final operation = _commands.then((_) async {
      if (_closed) throw const TailscaleException('closed');
      if (!_validConfiguration) {
        throw const TailscaleException('invalidConfiguration');
      }
      _busy = true;
      _error = null;
      _changed();
      try {
        await action();
      } catch (error) {
        _error = error is TailscaleException
            ? error
            : const TailscaleException('operationFailed');
        rethrow;
      } finally {
        _busy = false;
        _changed();
        if (_enabled && !_closed) unawaited(_refreshAfterCurrent());
      }
    });
    _commands = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<TailscaleNode> _getNode() async {
    final existing = _node;
    if (existing != null) return existing;
    final node = await openNode();
    if (_closed) {
      await node.dispose();
      throw const TailscaleException('closed');
    }
    return _node = node;
  }

  Future<void> _withRuntimeRecovery(
    Future<void> Function(TailscaleNode) action,
  ) async {
    try {
      await action(await _getNode());
    } on TailscaleException catch (error) {
      if (!const {
        'runtimeStopped',
        'controlTimeout',
        'runtimeUnavailable',
      }.contains(error.code)) {
        rethrow;
      }
      // A dead desktop helper cannot be repaired by reusing its closed pipes.
      // Release this owner and attach a fresh runtime to the same private state.
      _generation++;
      _online.clear();
      _candidates.clear();
      await _closePublications();
      await _closeRemoteClients();
      final previous = _node;
      _node = null;
      _status = null;
      try {
        await previous?.dispose();
      } catch (_) {
        /* process already exited */
      }
      await action(await _getNode());
    }
  }

  Future<void> login() => _command(() async {
    await repository.setSetting(TailscaleBindings.enabledKey, 'true');
    _enabled = true;
    await _withRuntimeRecovery((node) async {
      // login is the explicit interactive start operation. A resumable start
      // intentionally rejects fresh state until the user has authorized login.
      await node.login();
      await _updateStatus(await node.status());
    });
    _startPolling();
    // Authentication completion is observed independently of LAN and the
    // caller opening the system browser. No authentication URL is persisted.
    unawaited(_safeRefresh());
  });

  Future<void> retry() => _command(() async {
    if (!_enabled) return;
    await _withRuntimeRecovery((node) async {
      await node.start();
      await _updateStatus(await node.status());
    });
    _startPolling();
    unawaited(_safeRefresh());
  });

  Future<void> logout() => _command(() async {
    await repository.setSetting(TailscaleBindings.enabledKey, 'false');
    _enabled = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _candidates.clear();
    _suppressed.clear();
    _online.clear();
    await _closeRemoteClients();
    await _closePublications();
    final node = _node;
    if (node != null) {
      await node.logout();
      _status = await node.status();
    } else {
      _status = null;
    }
  });

  /// A started node has no registration scope until its first network map
  /// arrives, and sign-in ends when the person in the browser finishes.
  bool get _settling {
    final status = _status;
    return status == null ||
        !status.registered &&
            (status.state == NodeState.connecting ||
                status.state == NodeState.authorizing);
  }

  /// Start-up and sign-in change state within seconds. At the regular interval
  /// an authentication URL would open that much later, and a ready node would
  /// publish and be routable that much later. They are followed closely at
  /// first; a node that stays unsettled falls back to the regular interval.
  Duration _pollDelay() {
    if (!_settling) {
      _settlingPolls = 0;
      return pollInterval;
    }
    final attempt = _settlingPolls++;
    final Duration delay;
    if (_status?.state == NodeState.authorizing) {
      // The URL arrives in moments; the sign-in itself may take minutes.
      if (attempt >= 150) return pollInterval;
      delay = settleInterval * (attempt < 4 ? 1 : 4);
    } else {
      delay = settleInterval * (1 << (attempt < 6 ? attempt : 6));
    }
    return delay < pollInterval ? delay : pollInterval;
  }

  void _startPolling() {
    _settlingPolls = 0;
    _schedulePoll();
  }

  void _schedulePoll() {
    _timer?.cancel();
    if (_closed || !_enabled) {
      _timer = null;
      return;
    }
    late final Timer timer;
    timer = Timer(_pollDelay(), () async {
      await _safeRefresh();
      // A later command or logout owns the schedule now.
      if (identical(_timer, timer)) _schedulePoll();
    });
    _timer = timer;
  }

  Future<void> _safeRefresh() async {
    try {
      await refresh();
    } catch (error) {
      if (!_closed && _enabled) {
        _error = error is TailscaleException
            ? error
            : const TailscaleException('operationFailed');
        _changed();
      }
    }
  }

  Future<void> refresh() {
    // A poll must not start while a trust mutation is awaiting storage. Its
    // generation would otherwise be new while its bindings are still old.
    if (_closed || _busy || !_enabled || _node == null) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _updateStatus(NodeStatus next) async {
    final previous = _status;
    _status = next;
    if (previous != null &&
        (previous.sessionEpoch != next.sessionEpoch ||
            previous.networkScope != next.networkScope)) {
      _generation++;
      _online.clear();
      await _closeRemoteClients();
      _candidates.clear();
      _suppressed.clear();
      await _closePublications();
    }
    _changed();
  }

  Future<void> _refresh() async {
    final node = _node!;
    final previousError = _error;
    var generation = _generation;
    final next = await node.status();
    if (!_current(generation)) return;
    await _updateStatus(next);
    generation = _generation;
    if (!_current(generation)) return;
    if (!next.registered || !discoveryEnabled) {
      // The status was read: a failure recorded before this pass is over.
      if (_error != null && identical(_error, previousError)) {
        _error = null;
        _changed();
      }
      return;
    }
    // A control-plane interruption does not forcibly close existing sockets.
    final visiblePeers = (await node.peers())
        .where(
          (peer) =>
              peer.ref.networkScope == next.networkScope &&
              peer.ref.nodeId != next.selfNodeId,
        )
        .take(256)
        .toList();
    if (!_current(generation)) return;
    await _reconcilePublications(
      visiblePeers.map((peer) => peer.ref).toSet(),
      generation,
    );
    if (!_current(generation)) return;
    final remembered = {
      for (final peer in await repository.listPeers()) peer.id: peer,
    };
    if (!_current(generation)) return;
    final peersByRef = {for (final peer in visiblePeers) peer.ref: peer};
    _suppressed.removeWhere((ref) => !peersByRef.containsKey(ref));
    // Missing from a control snapshot is not an RPC result. Recheck known
    // bindings directly so cached data-plane paths remain usable if possible.
    final peers = <TailscalePeer>[
      for (final binding in _bindings.where(
        (entry) => entry.ref.networkScope == next.networkScope,
      ))
        peersByRef.remove(binding.ref) ??
            TailscalePeer(
              ref: binding.ref,
              name: binding.name,
              addresses: const [],
              online: false,
            ),
      ...peersByRef.values,
    ];
    final sweep = _Sweep();
    var cursor = 0;
    Future<void> worker() async {
      while (_current(generation) && cursor < peers.length) {
        final peer = peers[cursor++];
        await _probe(peer, remembered, sweep, generation);
      }
    }

    await Future.wait(List.generate(peers.length.clamp(0, 4), (_) => worker()));
    if (!_current(generation)) return;
    for (final claim in sweep.claims) {
      if (sweep.verified.contains(claim.peer.id)) {
        // The associated node still answers as this device, so a second node
        // reporting the same identity is a conflict, never a successor.
        sweep.conflict = true;
        continue;
      }
      // The associated node no longer answers as this device, as after the
      // remote device registered a new node. Offer the association to the
      // user; it is never moved without an explicit confirmation.
      sweep.seen.add(claim.key);
      _candidates[claim.key] = claim;
    }
    // Unconfirmed candidates are session-local. Persisted devices and bindings
    // remain available offline even if the current network hides that node.
    _candidates.removeWhere((key, _) => !sweep.seen.contains(key));
    // A conflict lasts as long as a pass observes it, not until a command.
    if (sweep.conflict) {
      _error = const TailscaleException('identityConflict');
    } else if (identical(_error, previousError)) {
      _error = null;
    }
    _changed();
  }

  bool _current(int generation) =>
      !_closed && _enabled && generation == _generation;

  Future<void> _probe(
    TailscalePeer remote,
    Map<String, Peer> remembered,
    _Sweep sweep,
    int generation,
  ) async {
    if (_suppressed.contains(remote.ref)) return;
    final binding = _bindings
        .where((entry) => entry.ref == remote.ref)
        .firstOrNull;
    final expected = binding == null ? null : remembered[binding.deviceId];
    final candidate =
        expected ??
        Peer(
          id: binding?.deviceId ?? '',
          name: binding?.name ?? remote.name,
          host: '',
          port: tailscaleMediaPort,
        );
    final channel = TailscaleChannel(
      _node!,
      remote.ref,
      port: binding == null ? tailscaleIdentityPort : tailscaleMediaPort,
    );
    final client = MediaRpcClient(
      candidate,
      channel: channel,
      translateTransportError: (error) => _transportError(error, channel),
    );
    try {
      final identified = await client.identity();
      if (!_current(generation) || identified.id == identity().id) return;
      if (binding != null) {
        if (identified.id != binding.deviceId) {
          throw const TailscaleException('identityConflict');
        }
        sweep.verified.add(identified.id);
        final changed = _online.add(identified.id);
        if (changed || expected == null || expected.name != identified.name) {
          await onPeer(identified, true);
        }
      } else {
        final sameDevice = _bindings
            .where(
              (entry) =>
                  entry.ref.networkScope == remote.ref.networkScope &&
                  entry.deviceId == identified.id,
            )
            .firstOrNull;
        if (sameDevice != null) {
          // Another node cannot acquire an established binding by reporting
          // the same Tamayura ID, even after an address change. Whether it
          // is a conflict or a successor awaiting the user's confirmation
          // depends on the associated node's own answer in this pass.
          sweep.claims.add(
            TailscaleCandidate(
              peer: identified,
              ref: remote.ref,
              existingDevice: remembered.containsKey(identified.id),
              replaces: sameDevice.ref,
            ),
          );
          return;
        }
        final found = TailscaleCandidate(
          peer: identified,
          ref: remote.ref,
          existingDevice: remembered.containsKey(identified.id),
        );
        sweep.seen.add(found.key);
        _candidates[found.key] = found;
      }
    } catch (error) {
      if (_current(generation) && binding != null) {
        if (_online.remove(binding.deviceId)) {
          await onPeer(candidate, false);
        }
        if (error is FormatException ||
            error is TailscaleException && error.code == 'identityConflict') {
          sweep.conflict = true;
        }
      }
      // An ordinary Tailscale node without Tamayura is not a discovered device.
    } finally {
      await client.close();
    }
  }

  Future<void> confirmCandidate(String key) => _command(() async {
    final candidate = _candidates[key];
    if (candidate == null ||
        !_enabled ||
        candidate.ref.networkScope != _status?.networkScope) {
      throw const TailscaleException('staleCandidate');
    }
    _generation++;
    // The device's present association in this network, which the candidate
    // may succeed only as the pass that found it established: the associated
    // node did not answer as the device.
    final replaced = _bindings
        .where(
          (entry) =>
              entry.ref.networkScope == candidate.ref.networkScope &&
              entry.deviceId == candidate.peer.id,
        )
        .toList();
    if (_bindings.any((entry) => entry.ref == candidate.ref) ||
        replaced.isNotEmpty &&
            (candidate.replaces == null ||
                _online.contains(candidate.peer.id))) {
      throw const TailscaleException('identityConflict');
    }
    final next = [
      ..._bindings.where((entry) => !replaced.contains(entry)),
      TailscaleBinding(
        deviceId: candidate.peer.id,
        name: candidate.peer.name,
        ref: candidate.ref,
      ),
    ];
    await repository.setSetting(
      TailscaleBindings.settingKey,
      TailscaleBindings.encode(next),
    );
    _bindings
      ..clear()
      ..addAll(next);
    _candidates.remove(key);
    if (replaced.isNotEmpty) await _closeRemoteClients(candidate.peer.id);
    // Association approval permits incoming sharing. Album sync approval stays
    // with the host's existing pending/approved/declined device decision.
    try {
      await _mediaLease?.updatePolicy(_currentAllowedPeers());
    } catch (_) {
      // The node that lost its association must not keep its access while
      // native control is unavailable; see forgetDevice.
      if (replaced.isNotEmpty) await _closePublications();
      rethrow;
    }
    await onPeer(candidate.peer, false);
    unawaited(_refreshAfterCurrent());
  });

  Future<void> _refreshAfterCurrent() async {
    try {
      await _refreshing;
    } catch (_) {
      /* retry with current identity */
    }
    await _safeRefresh();
  }

  Future<void> forgetDevice(String deviceId) => _command(() async {
    _generation++;
    // A callback may already be writing the remembered peer. Drain it before
    // the host deletes that row, so a late write cannot resurrect the device.
    try {
      await _refreshing;
    } catch (_) {
      /* its generation is already obsolete */
    }
    final revoked = _bindings
        .where((entry) => entry.deviceId == deviceId)
        .map((entry) => entry.ref)
        .toSet();
    final next = _bindings
        .where((entry) => entry.deviceId != deviceId)
        .toList();
    // Persist removal first: a failed native policy reply must not cause a
    // later refresh or process restart to silently grant access again.
    await repository.setSetting(
      TailscaleBindings.settingKey,
      TailscaleBindings.encode(next),
    );
    _bindings
      ..clear()
      ..addAll(next);
    _online.remove(deviceId);
    await _closeRemoteClients(deviceId);
    _suppressed.addAll(revoked);
    _candidates.removeWhere((_, value) => value.peer.id == deviceId);
    try {
      await _mediaLease?.updatePolicy(_currentAllowedPeers());
    } catch (_) {
      // Closing the SDK's mTLS target also closes its active streams even if
      // native control is unavailable; keep LAN serving independently.
      await _closePublications();
      rethrow;
    }
  });

  Future<void> revokeDevice(String deviceId) => forgetDevice(deviceId);

  Set<PeerRef> _currentAllowedPeers() => _bindings
      .where((entry) => entry.ref.networkScope == _status?.networkScope)
      .map((entry) => entry.ref)
      .toSet();

  Future<void> setSharing(bool enabled) async {
    if (_sharing != enabled) _generation++;
    _sharing = enabled;
    if (!enabled) {
      await _closePublications();
    } else {
      await _refreshAfterCurrent();
    }
  }

  Future<void> _reconcilePublications(
    Set<PeerRef> visible,
    int generation,
  ) async {
    final source = server();
    if (!_sharing || source == null || source.port == 0) {
      await _closePublications();
      return;
    }
    if (_publishedSource != source) await _closePublications();
    if (!_current(generation)) return;
    _publishedSource = source;
    if (_identityLease == null) {
      final transport = source.createTransportServer(identityOnly: true);
      _identityServer = transport;
      final lease = await _node!.publishTcp(
        port: tailscaleIdentityPort,
        allowedPeers: visible,
        onConnection: (connection) =>
            serveGrpcConnection(transport, connection),
      );
      if (!_current(generation) || !_sharing) {
        await lease.close();
        await transport.shutdown();
        return;
      }
      _identityLease = lease;
    } else {
      await _identityLease!.updatePolicy(visible);
    }
    if (_mediaLease == null) {
      final transport = source.createTransportServer();
      _mediaServer = transport;
      final lease = await _node!.publishTcp(
        port: tailscaleMediaPort,
        allowedPeers: _currentAllowedPeers(),
        onConnection: (connection) =>
            serveGrpcConnection(transport, connection),
      );
      if (!_current(generation) || !_sharing) {
        await lease.close();
        await transport.shutdown();
        return;
      }
      _mediaLease = lease;
    } else {
      await _mediaLease!.updatePolicy(_currentAllowedPeers());
    }
  }

  /// Called once for each new operation/retry. A live RPC keeps its route;
  /// media streams are never replayed automatically on another connection.
  MediaRpcClient createClient(Peer peer) {
    // The host's first operations begin while the saved sign-in is still
    // resuming. Whether they have a remote route is not known yet, and is
    // decided with the route itself rather than assumed absent.
    final restoring = _restoring;
    if (restoring == null && (_node == null || !hasAssociation(peer.id))) {
      if (peer.host.isEmpty) {
        throw const GrpcError.unavailable('Tailscale is not connected');
      }
      return MediaRpcClient(peer);
    }
    final scope = _status?.networkScope;
    final epoch = _status?.sessionEpoch;
    // While the scope is unknown the remote route may not exist after all,
    // so the LAN address is tried in any case.
    final remoteOnly = peer.host.isEmpty || scope != null && !lanFirst(peer.id);
    TailscaleChannel? selected;
    // Resolved when the route is needed rather than now: a node that has just
    // started, as in a background transfer engine, has no scope to match yet.
    Future<TailscaleChannel?> remote() async {
      if (!remoteOnly) onLanUnanswered?.call(peer.id);
      if (restoring != null) {
        await restoring.timeout(routeTimeout, onTimeout: () {});
      }
      await _awaitRegistration();
      final node = _node;
      final status = _status;
      final associated = _bindings.any((entry) => entry.deviceId == peer.id);
      // An association that existed when the operation began and is gone now
      // was revoked; one that never existed is simply no route.
      if (restoring == null &&
          (!_enabled ||
              _closed ||
              epoch != null && epoch != status?.sessionEpoch ||
              !associated)) {
        throw const GrpcError.permissionDenied(
          'Tailscale association was revoked',
        );
      }
      final binding = _bindings
          .where(
            (entry) =>
                entry.deviceId == peer.id &&
                entry.ref.networkScope == status?.networkScope,
          )
          .firstOrNull;
      if (!_enabled || _closed || node == null || binding == null) {
        // Not signed in, not registered in time, or registered as another
        // node than the one this device was associated with.
        if (peer.host.isEmpty) {
          throw const GrpcError.unavailable('Tailscale is not connected');
        }
        return null;
      }
      return selected = TailscaleChannel(
        node,
        binding.ref,
        port: tailscaleMediaPort,
      );
    }

    late final MediaRpcClient client;
    client = MediaRpcClient(
      peer,
      fallbackChannel: remote,
      remoteOnly: remoteOnly,
      onClosed: () => _clients.remove(client),
      translateTransportError: (error) => _transportError(error, selected),
    );
    _clients.add(client);
    return client;
  }

  /// A started node has not yet received the network map that carries its
  /// registration scope.
  bool get _awaitingScope {
    final status = _status;
    return status == null ||
        !status.registered && status.state == NodeState.connecting;
  }

  /// Whether this device has an association that a new operation may use.
  /// While the scope is unknown any saved association counts, so that a
  /// transfer can be scheduled; the route itself is matched when it is used.
  bool hasAssociation(String deviceId) {
    if (!_enabled) return false;
    final scope = _status?.networkScope;
    return _bindings.any(
      (entry) =>
          entry.deviceId == deviceId &&
          (scope == null ? _awaitingScope : entry.ref.networkScope == scope),
    );
  }

  /// The scope usually arrives within seconds of starting. A route requested
  /// before that waits for it, up to [routeTimeout], instead of failing; an
  /// engine that started the node for one transfer would otherwise give up
  /// first, on every run. The wait reads the status itself, so it does not
  /// depend on the poll schedule, and ends at once in any other state.
  Future<void> _awaitRegistration() async {
    final watch = Stopwatch()..start();
    while (!_closed &&
        _enabled &&
        _node != null &&
        _awaitingScope &&
        watch.elapsed < routeTimeout) {
      // Not awaited: once registered, a pass goes on to probe every peer.
      unawaited(_safeRefresh());
      await Future<void>.delayed(settleInterval);
    }
  }

  Future<void> _closeRemoteClients([String? deviceId]) async {
    await Future.wait(
      _clients
          .where(
            (client) =>
                client.usesTailscale &&
                (deviceId == null || client.peer.id == deviceId),
          )
          .toList()
          .map((client) => client.close()),
    );
  }

  Future<void> _closePublications() async {
    final leases = [_identityLease, _mediaLease];
    final transports = [_identityServer, _mediaServer];
    _identityLease = _mediaLease = null;
    _identityServer = _mediaServer = null;
    _publishedSource = null;
    for (final lease in leases) {
      try {
        await lease?.close();
      } catch (_) {
        // SDK close always destroys its authenticated local listener and
        // streams in finally. Surface the control failure for diagnosis.
        _error = const TailscaleException('unpublishFailed');
        _changed();
      }
    }
    for (final transport in transports) {
      await transport?.shutdown();
    }
  }

  void _changed() {
    if (!_closed) onChanged();
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _timer?.cancel();
    await _commands;
    await _closeRemoteClients();
    await _closePublications();
    await _node?.dispose();
    _node = null;
  }
}
