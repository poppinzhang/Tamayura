import 'dart:async';
import 'dart:io';

import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_tailscale/src/control.dart';
import 'package:flutter_tailscale/src/node.dart';
import 'package:flutter_test/flutter_test.dart';

class _BlockedUnpublish implements BridgeControl {
  _BlockedUnpublish(this.certificate, this.key);
  final String certificate, key;
  final unpublishing = Completer<void>();
  final acknowledged = Completer<void>();
  int? targetPort;
  int unpublishCalls = 0;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    switch (method) {
      case 'initialize':
        return {
          'protocolVersion': 1,
          'ownerId': 'test-owner',
          'sessionEpoch': 'test-session',
          'certificatePem': certificate,
          'privateKeyPem': key,
          'capabilities': [
            'tcp',
            'localMutualTls',
            'explicitPeerPolicy',
            'owners',
          ],
        };
      case 'publish':
        targetPort = params['targetPort'] as int;
        return {'serviceId': 'test-service', 'sessionEpoch': 'test-session'};
      case 'unpublish':
        unpublishCalls++;
        if (!unpublishing.isCompleted) unpublishing.complete();
        await acknowledged.future;
        return {'closed': true};
      case 'dispose':
        return {'disposed': true};
      default:
        throw StateError('Unexpected test operation');
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('local service revocation precedes a blocked native unpublish', () async {
    final control = _BlockedUnpublish(
      await File('test/fixtures/test-cert.pem').readAsString(),
      await File('test/fixtures/test-key.pem').readAsString(),
    );
    final node = await initializeBridgeControl(
      control,
      stateDirectory: '/test-private-state',
      hostname: 'test-node',
    );
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain('test/fixtures/test-cert.pem')
      ..usePrivateKey('test/fixtures/test-key.pem')
      ..setTrustedCertificates('test/fixtures/test-cert.pem');
    final accepted = Completer<BridgeConnection>();
    var delivered = 0;
    final lease = await node.publishTcp(
      port: 50728,
      allowedPeers: {},
      onConnection: (connection) {
        delivered++;
        if (!accepted.isCompleted) accepted.complete(connection);
      },
    );
    SecureSocket? client;
    Socket? pending;
    SecureSocket? lateHandshake;
    StreamSubscription<List<int>>? subscription;
    try {
      client = await SecureSocket.connect(
        '127.0.0.1',
        control.targetPort!,
        context: context,
        onBadCertificate: (certificate) =>
            certificate.pem.trim() == control.certificate.trim(),
      ).timeout(const Duration(seconds: 2));
      await accepted.future.timeout(const Duration(seconds: 2));
      final disconnected = Completer<void>();
      void ended() {
        if (!disconnected.isCompleted) disconnected.complete();
      }

      subscription = client.listen(
        (_) {},
        onError: (_) => ended(),
        onDone: ended,
      );
      // A TCP connection accepted before revocation has not authenticated yet.
      pending = await Socket.connect('127.0.0.1', control.targetPort!);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      var finished = false;
      final closing = lease.close().then((_) => finished = true);
      final duplicate = lease.close();
      await control.unpublishing.future.timeout(const Duration(seconds: 2));
      await disconnected.future.timeout(const Duration(seconds: 2));
      expect(
        finished,
        isFalse,
        reason: 'The native acknowledgement is still withheld.',
      );
      await expectLater(
        Socket.connect('127.0.0.1', control.targetPort!),
        throwsA(isA<SocketException>()),
      );
      try {
        lateHandshake = await SecureSocket.secure(
          pending,
          context: context,
          onBadCertificate: (certificate) =>
              certificate.pem.trim() == control.certificate.trim(),
        ).timeout(const Duration(milliseconds: 500));
        await lateHandshake.drain<void>().timeout(
          const Duration(milliseconds: 500),
        );
      } catch (_) {
        /* A pending TLS handshake may be rejected or closed. */
      }
      expect(
        delivered,
        1,
        reason:
            'An already pending handshake must never deliver an app stream.',
      );
      control.acknowledged.complete();
      await closing;
      await duplicate;
      expect(control.unpublishCalls, 1);
    } finally {
      if (!control.acknowledged.isCompleted) control.acknowledged.complete();
      client?.destroy();
      lateHandshake?.destroy();
      pending?.destroy();
      await subscription?.cancel();
      await node.dispose();
    }
  });
}
