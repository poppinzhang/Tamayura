import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/platform/android_bridge.dart';
import 'package:tamayura/platform/default_bridge.dart';
import 'package:tamayura/platform/macos_bridge.dart';
import 'package:tamayura/platform/windows_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tamayura/windows');
  const bridge = WindowsBridge(methods: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('platform selection uses Windows process-owned downloads', () {
    expect(
      defaultPlatformBridge(operatingSystem: 'windows'),
      isA<WindowsBridge>(),
    );
    expect(defaultPlatformBridge(operatingSystem: 'macos'), isA<MacOSBridge>());
    expect(
      defaultPlatformBridge(operatingSystem: 'android'),
      isA<AndroidBridge>(),
    );
    expect(
      () => defaultPlatformBridge(operatingSystem: 'linux'),
      throwsUnsupportedError,
    );
    expect(bridge.usesInProcessTransfers, isTrue);
    expect(bridge.platformName, 'Windows');
  });

  test('every platform receives the interface language preference', () async {
    for (final platform in [
      WindowsBridge(methods: channel),
      MacOSBridge(methods: channel),
      AndroidBridge(methods: channel),
    ]) {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await platform.setLanguage('ja');
      expect(calls.single.method, 'setLanguage');
      expect(calls.single.arguments, {'language': 'ja'});
    }
  });

  test('Windows identity must be a persisted lowercase UUID', () async {
    const identity = 'windows-aabbccdd-1234-5678-abcd-123456789abc';
    messenger.setMockMethodCallHandler(channel, (_) async => identity);
    expect(await bridge.deviceId(), identity);
    expect(await bridge.deviceId(), identity);
    for (final invalid in [
      null,
      '',
      'windows-invalid',
      'macos-aabbccdd-1234-5678-abcd-123456789abc',
      identity.toUpperCase(),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      await expectLater(bridge.deviceId(), throwsA(isA<PlatformException>()));
    }
  });

  test(
    'Unicode Windows paths and 64-bit metadata retain the shared RPC contract',
    () async {
      const root = SharedFolder(
        id: 'pictures',
        uri: r'C:\Users\照片\Pictures',
        name: '照片',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return {'uri': root.uri, 'name': root.name};
          case 'scanDirectoriesMetadata':
            expect(call.arguments, {
              'directories': [root.toJson()],
            });
            return [
              {
                'id': 'opaque-id',
                'name': '旅行.mp4',
                'mimeType': 'video/mp4',
                'size': 9000000000,
                'modifiedMs': 1790000000000,
                'sharedFolderId': root.id,
                'sharedFolderName': root.name,
                'relativePath': '2026/旅行.mp4',
              },
            ];
          case 'saveDownload':
            expect(call.arguments['directories'], ['Phone', '相册', '2026']);
            expect(call.arguments['sourcePaths'], [
              r'C:\Users\test\AppData\Local\Tamayura\transfers\task\0.part',
            ]);
            return r'C:\Photos\Phone\相册\2026\旅行.mp4';
          default:
            fail('Unexpected call ${call.method}');
        }
      });
      expect((await bridge.pickDirectory())!['uri'], root.uri);
      final metadata = (await bridge.scanDirectoriesMetadata([root])).single;
      expect(metadata['size'], 9000000000);
      expect(metadata['relativePath'], '2026/旅行.mp4');
      expect(
        await bridge.saveDownload(
          sourcePaths: [
            r'C:\Users\test\AppData\Local\Tamayura\transfers\task\0.part',
          ],
          expectedSize: 9000000000,
          directoryUri: r'C:\Photos',
          name: '旅行.mp4',
          mimeType: 'video/mp4',
          directories: ['Phone', '相册', '2026'],
        ),
        startsWith(r'C:\Photos\'),
      );
    },
  );

  test(
    'cancelled picker and native permission errors stay distinguishable',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await bridge.pickDirectory(), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'PERMISSION_LOST', message: '目录不可访问');
      });
      await expectLater(
        bridge.scanDirectoriesMetadata([]),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'PERMISSION_LOST',
          ),
        ),
      );
    },
  );

  test('ranges validate before dispatch and preserve large offsets', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'readRange');
      expect(call.arguments, {'id': 'id', 'offset': 5000000000, 'length': 3});
      return Uint8List.fromList([1, 2, 3]);
    });
    await expectLater(bridge.readRange('id', -1, 3), throwsArgumentError);
    await expectLater(
      bridge.readRange('id', 0, mediaReadChunkBytes + 1),
      throwsArgumentError,
    );
    expect(calls, 0);
    expect(await bridge.readRange('id', 5000000000, 3), [1, 2, 3]);
  });

  test(
    'background sharing and service port are forwarded without job scheduling',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'setBackgroundSharing') {
          final enabled = call.arguments['enabled'] as bool;
          return {
            'enabled': enabled,
            'running': enabled,
            'batteryExempt': true,
          };
        }
        if (call.method == 'startDiscovery') {
          expect(call.arguments, {'id': 'id', 'name': 'PC', 'port': 50729});
        }
        return null;
      });
      expect((await bridge.setBackgroundSharing(true)).running, isTrue);
      expect((await bridge.setBackgroundSharing(false)).running, isFalse);
      await bridge.startDiscovery(id: 'id', name: 'PC', port: 50729);
      await bridge.stopDiscovery();
      await bridge.setTransferActivity('task', active: true);
      await bridge.setTransferActivity('task', active: false);
      expect(calls, [
        'setBackgroundSharing',
        'setBackgroundSharing',
        'startDiscovery',
        'stopDiscovery',
      ]);
    },
  );
}
