import 'dart:convert';
import 'dart:io';

import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_tailscale/src/control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final helper = Platform.environment['FLUTTER_TAILSCALE_HELPER'];
  test(
    'compiled helper initializes without login and keeps a unique state owner',
    () async {
      final state = await Directory.systemTemp.createTemp(
        'flutter-tailscale-sdk-',
      );
      TailscaleNode? node;
      try {
        node = await TailscaleNode.open(
          stateDirectory: state.path,
          hostname: 'sdk-smoke',
          executablePath: helper,
        );
        final first = await node.status();
        expect(first.signedIn, isFalse);
        expect(first.authUrl, isNull);
        await expectLater(
          node.start(),
          throwsA(
            isA<TailscaleException>().having(
              (error) => error.code,
              'code',
              'loginRequired',
            ),
          ),
        );
        await expectLater(
          TailscaleNode.open(
            stateDirectory: state.path,
            hostname: 'sdk-smoke',
            executablePath: helper,
          ),
          throwsA(
            isA<TailscaleException>().having(
              (error) => error.code,
              'code',
              'stateInUse',
            ),
          ),
        );
        await node.stop();
        expect((await node.status()).sessionEpoch, isNot(first.sessionEpoch));
        await node.logout();
        expect(await File('${state.path}/resume-enabled').exists(), isFalse);
        await Future.wait([node.dispose(), node.dispose()]);
        node = await TailscaleNode.open(
          stateDirectory: state.path,
          hostname: 'sdk-smoke',
          executablePath: helper,
        );
        expect((await node.status()).signedIn, isFalse);
      } finally {
        await node?.dispose();
        await state.delete(recursive: true);
      }
    },
    skip: helper == null
        ? 'Set FLUTTER_TAILSCALE_HELPER to a freshly built native helper.'
        : false,
  );

  test(
    'shared native owner disposal leaves the other owner attached',
    () async {
      final state = await Directory.systemTemp.createTemp(
        'flutter-tailscale-owners-',
      );
      final control = await ProcessBridgeControl.start(helper!);
      try {
        final first = await control.request('initialize', {
          'stateDirectory': state.path,
          'hostname': 'sdk-owners',
          'protocolVersion': 1,
        });
        final second = await control.request('initialize', {
          'stateDirectory': state.path,
          'hostname': 'sdk-owners',
          'protocolVersion': 1,
        });
        expect(first['ownerId'], isNot(second['ownerId']));
        expect(first['sessionEpoch'], second['sessionEpoch']);
        await control.request('dispose', {'ownerId': first['ownerId']});
        final status = await control.request('status', {
          'ownerId': second['ownerId'],
        });
        expect(status['sessionEpoch'], second['sessionEpoch']);
        await expectLater(
          control.request('status', {'ownerId': first['ownerId']}),
          throwsA(
            isA<TailscaleException>().having(
              (error) => error.code,
              'code',
              'invalidOwner',
            ),
          ),
        );
        await control.request('dispose', {'ownerId': second['ownerId']});
      } finally {
        await control.close();
        await state.delete(recursive: true);
      }
    },
    skip: helper == null
        ? 'Set FLUTTER_TAILSCALE_HELPER to a freshly built native helper.'
        : false,
  );

  test(
    'session certificate passes strict mutual TLS and does not expire while a node runs',
    () async {
      final state = await Directory.systemTemp.createTemp(
        'flutter-tailscale-certificate-',
      );
      final control = await ProcessBridgeControl.start(helper!);
      SecureServerSocket? listener;
      SecureSocket? client;
      try {
        final session = await control.request('initialize', {
          'stateDirectory': state.path,
          'hostname': 'sdk-certificate',
          'protocolVersion': 1,
        });
        final certificate = utf8.encode(session['certificatePem'] as String);
        final key = utf8.encode(session['privateKeyPem'] as String);
        // The same strict configuration as a published service: no
        // onBadCertificate, so the validity period is enforced on both ends.
        SecurityContext context() => SecurityContext(withTrustedRoots: false)
          ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
          ..useCertificateChainBytes(certificate)
          ..usePrivateKeyBytes(key)
          ..setTrustedCertificatesBytes(certificate);
        listener = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          context(),
          requireClientCertificate: true,
          requestClientCertificate: true,
        );
        final accepted = listener.first;
        client = await SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          listener.port,
          context: context(),
          timeout: const Duration(seconds: 5),
        );
        final server = await accepted.timeout(const Duration(seconds: 5));
        final presented = server.peerCertificate!;
        server.destroy();
        expect(presented.der, client.peerCertificate!.der);
        // A node may run for months; a wall clock may also be corrected.
        expect(presented.startValidity.isBefore(DateTime.utc(2001)), isTrue);
        expect(
          presented.endValidity.isAfter(
            DateTime.now().add(const Duration(days: 365 * 50)),
          ),
          isTrue,
        );
        await control.request('dispose', {'ownerId': session['ownerId']});
      } finally {
        client?.destroy();
        await listener?.close();
        await control.close();
        await state.delete(recursive: true);
      }
    },
    skip: helper == null
        ? 'Set FLUTTER_TAILSCALE_HELPER to a freshly built native helper.'
        : false,
  );
}
