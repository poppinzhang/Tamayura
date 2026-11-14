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
}
