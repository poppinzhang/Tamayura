import 'dart:convert';

import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_tailscale/src/control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('peer identity includes network scope', () {
    const a = PeerRef(networkScope: 'one', nodeId: 'node');
    const b = PeerRef(networkScope: 'two', nodeId: 'node');
    expect(a, PeerRef.fromJson(a.toJson()));
    expect(a, isNot(b));
    expect({a, b}.length, 2);
  });

  test('control online is not application service reachability', () {
    final peer = TailscalePeer.fromJson({
      'networkScope': 'one',
      'nodeId': 'node',
      'name': 'Device',
      'addresses': ['100.64.0.1'],
      'online': true,
    });
    expect(peer.online, isTrue);
    expect(() => peer.addresses.add('100.64.0.2'), throwsUnsupportedError);
  });

  test('unknown native state cannot grant registered status', () {
    final status = NodeStatus.fromJson({
      'sessionEpoch': 'epoch',
      'state': 'future',
      'networkScope': 'scope',
    });
    expect(status.state, NodeState.unknown);
    expect(status.registered, isFalse);
  });

  test('connecting with an authenticated scope retains login identity', () {
    expect(
      NodeStatus.fromJson({
        'sessionEpoch': 'epoch',
        'state': 'connecting',
        'networkScope': 'scope',
      }).registered,
      isTrue,
    );
    expect(
      NodeStatus.fromJson({
        'sessionEpoch': 'epoch',
        'state': 'connecting',
      }).registered,
      isFalse,
    );
  });

  test(
    'control disconnect does not discard registered data-plane identity',
    () {
      final status = NodeStatus.fromJson({
        'sessionEpoch': 'epoch',
        'state': 'connected',
        'networkScope': 'scope',
        'controlState': 'disconnected',
      });
      expect(status.controlState, NodeControlState.disconnected);
      expect(status.registered, isTrue);
    },
  );

  test('authentication URLs require official HTTPS origin', () {
    for (final url in [
      'http://login.tailscale.com/a/test',
      'https://login.tailscale.com.evil.invalid/a/test',
      'https://user:secret@login.tailscale.com/a/test',
      'https://login.tailscale.com:444/a/test',
      'file:///private/test',
    ]) {
      expect(
        () => NodeStatus.fromJson({
          'sessionEpoch': 'epoch',
          'state': 'authorizing',
          'authUrl': url,
        }),
        throwsA(isA<TailscaleException>()),
      );
    }
    final status = NodeStatus.fromJson({
      'sessionEpoch': 'epoch',
      'state': 'authorizing',
      'authUrl': 'https://login.tailscale.com/a/test-token',
    });
    expect(status.authUrl?.host, 'login.tailscale.com');
    expect(status.toString(), isNot(contains('test-token')));
  });

  test('control responses reject ambiguous or mismatched envelopes', () {
    for (final json in [
      {'id': 2, 'result': <String, dynamic>{}},
      {'id': 1, 'result': <String, dynamic>{}, 'error': <String, dynamic>{}},
      {'id': 1},
      {'id': 1, 'result': []},
    ]) {
      expect(
        () => decodeResponse(jsonEncode(json), 1),
        throwsA(isA<TailscaleException>()),
      );
    }
    expect(decodeResponse('{"id":1,"result":{"ok":true}}', 1)['ok'], isTrue);
  });

  test('native error detail never leaks secrets', () {
    try {
      decodeResponse(
        '{"id":1,"error":{"code":"loginFailed",'
        '"message":"https://login.tailscale.com/a/secret"}}',
        1,
      );
      fail('Must fail');
    } on TailscaleException catch (error) {
      expect(error.code, 'loginFailed');
      expect(error.toString(), isNot(contains('secret')));
    }
    expect(
      () => decodeResponse('{"id":1,"error":{"code":"secret/path"}}', 1),
      throwsA(
        isA<TailscaleException>().having(
          (e) => e.code,
          'code',
          'nativeFailure',
        ),
      ),
    );
  });
}
