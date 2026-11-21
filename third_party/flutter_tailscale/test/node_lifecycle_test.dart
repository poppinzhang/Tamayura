import 'dart:async';

import 'package:flutter_tailscale/src/control.dart';
import 'package:flutter_tailscale/src/models.dart';
import 'package:flutter_tailscale/src/node.dart';
import 'package:flutter_test/flutter_test.dart';

const _capabilities = ['tcp', 'localMutualTls', 'explicitPeerPolicy', 'owners'];
const _handshake = {
  'protocolVersion': 1,
  'ownerId': 'test-owner',
  'sessionEpoch': 'first-session',
  'capabilities': _capabilities,
};

class _Control implements BridgeControl {
  final replies = <String, FutureOr<Map<String, dynamic>>>{
    'initialize': _handshake,
    'dispose': {},
  };
  final calls = <(String, Object?)>[];

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add((method, params['ownerId']));
    return replies[method] ?? (throw StateError('Unexpected $method request'));
  }

  @override
  Future<void> close() async => calls.add(('close', null));
}

Future<TailscaleNode> _open(_Control control) => initializeBridgeControl(
  control,
  stateDirectory: '/test-private-state',
  hostname: 'test-node',
);

Matcher _throwsCode(String code) =>
    throwsA(isA<TailscaleException>().having((e) => e.code, 'code', code));

void main() {
  final incompatibleReplies = {
    'unsupported protocol version': {'protocolVersion': 2},
    for (final missing in _capabilities)
      'missing $missing capability': {
        'capabilities': _capabilities.where((c) => c != missing).toList(),
      },
  };
  for (final entry in incompatibleReplies.entries) {
    test('handshake releases its owner on ${entry.key}', () async {
      final control = _Control()
        ..replies['initialize'] = {..._handshake, ...entry.value};

      await expectLater(_open(control), _throwsCode('incompatibleProtocol'));
      expect(control.calls, [
        ('initialize', null),
        ('dispose', 'test-owner'),
        ('close', null),
      ]);
    });
  }

  test(
    'late status and peer snapshots cannot restore a stopped session',
    () async {
      final oldStatus = Completer<Map<String, dynamic>>();
      final oldPeers = Completer<Map<String, dynamic>>();
      final control = _Control()
        ..replies['status'] = oldStatus.future
        ..replies['peers'] = oldPeers.future
        ..replies['stop'] = {'sessionEpoch': 'second-session'};
      final node = await _open(control);
      addTearDown(node.dispose);

      final status = expectLater(node.status(), _throwsCode('sessionChanged'));
      final peers = expectLater(node.peers(), _throwsCode('sessionChanged'));
      await node.stop();
      oldStatus.complete({
        'sessionEpoch': 'first-session',
        'state': 'connected',
      });
      await status;
      oldPeers.complete({'sessionEpoch': 'first-session', 'peers': []});
      await peers;

      control.replies['peers'] = {
        'sessionEpoch': 'second-session',
        'peers': [],
      };
      expect(await node.peers(), isEmpty);
    },
  );

  test(
    'dispose rejects pending and future status calls and releases once',
    () async {
      final oldStatus = Completer<Map<String, dynamic>>();
      final control = _Control()..replies['status'] = oldStatus.future;
      final node = await _open(control);

      final pending = expectLater(node.status(), _throwsCode('sessionChanged'));
      await Future.wait([node.dispose(), node.dispose()]);
      oldStatus.complete({
        'sessionEpoch': 'first-session',
        'state': 'connected',
      });
      await pending;
      await expectLater(node.status(), _throwsCode('disposed'));
      expect(control.calls, [
        ('initialize', null),
        ('status', 'test-owner'),
        ('dispose', 'test-owner'),
        ('close', null),
      ]);
    },
  );
}
