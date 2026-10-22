import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/platform/default_bridge.dart';
import 'package:tamayura/platform/linux_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tamayura/linux');
  const bridge = LinuxBridge(methods: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Linux uses process-owned downloads like the other desktops', () {
    expect(defaultPlatformBridge(operatingSystem: 'linux'), isA<LinuxBridge>());
    expect(bridge.usesInProcessTransfers, isTrue);
    expect(bridge.platformName, 'Linux');
  });

  test('Linux identity must be a persisted lowercase UUID', () async {
    const identity = 'linux-aabbccdd-1234-5678-abcd-123456789abc';
    messenger.setMockMethodCallHandler(channel, (_) async => identity);
    expect(await bridge.deviceId(), identity);
    for (final invalid in [
      null,
      '',
      'linux-invalid',
      'windows-aabbccdd-1234-5678-abcd-123456789abc',
      'linux-aabbccdd-1234-5678-abcd-123456789abcd',
      identity.toUpperCase(),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      await expectLater(bridge.deviceId(), throwsA(isA<PlatformException>()));
    }
  });

  test(
    'POSIX paths with Unicode and 64-bit metadata keep the shared contract',
    () async {
      const root = SharedFolder(id: 'pictures', uri: '/home/用户/图片', name: '图片');
      const staged = '/home/用户/.local/share/tamayura/transfers/task/0.part';
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return {'uri': root.uri, 'name': root.name};
          case 'validateSharedDirectory':
            expect(call.arguments, {
              'uri': root.uri,
              'existingUris': ['/media/用户/相机'],
            });
            return null;
          case 'scanDirectoriesMetadata':
            expect(call.arguments, {
              'directories': [root.toJson()],
            });
            return [
              {
                'id': 'opaque-id',
                'name': '旅行.mkv',
                'mimeType': 'video/x-matroska',
                'size': 9000000000,
                'modifiedMs': 1790000000000,
                'sharedFolderId': root.id,
                'sharedFolderName': root.name,
                'relativePath': '2026/旅行.mkv',
              },
            ];
          case 'saveDownload':
            expect(call.arguments['sourcePaths'], [staged]);
            expect(call.arguments['directories'], ['Phone', '相册', '2026']);
            return '/home/用户/图片/Phone/相册/2026/旅行 (1).mkv';
          case 'deleteDownload':
          case 'open':
          case 'share':
            expect(
              call.arguments['uri'],
              '/home/用户/图片/Phone/相册/2026/旅行 (1).mkv',
            );
            return null;
          default:
            fail('Unexpected call ${call.method}');
        }
      });
      expect((await bridge.pickDirectory())!['uri'], root.uri);
      await bridge.validateSharedDirectory(root.uri, ['/media/用户/相机']);
      final metadata = (await bridge.scanDirectoriesMetadata([root])).single;
      expect(metadata['size'], 9000000000);
      expect(metadata['relativePath'], '2026/旅行.mkv');
      final saved = await bridge.saveDownload(
        sourcePaths: [staged],
        expectedSize: 9000000000,
        directoryUri: root.uri,
        name: '旅行.mkv',
        mimeType: 'video/x-matroska',
        directories: ['Phone', '相册', '2026'],
      );
      expect(saved, startsWith('${root.uri}/'));
      await bridge.open(saved, 'video/x-matroska');
      await bridge.share(saved, 'video/x-matroska');
      await bridge.deleteDownload(saved);
    },
  );

  test('native errors keep their codes for the controller', () async {
    for (final code in [
      'PERMISSION_LOST',
      'FILE_NOT_FOUND',
      'DIR_OVERLAP',
      'OPEN_FAILED',
      'REVEAL_FAILED',
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code, message: 'native message');
      });
      await expectLater(
        bridge.open('/home/user/a.jpg', 'image/jpeg'),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
      );
    }
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await bridge.pickDirectory(), isNull);
  });

  test('ranges and preview sizes validate before dispatch', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      if (call.method == 'readPreview') {
        expect(call.arguments, {
          'uri': '/home/user/a.jpg',
          'maxDimension': 2560,
        });
      } else {
        expect(call.arguments, {'id': 'id', 'offset': 5000000000, 'length': 3});
      }
      return Uint8List.fromList([1, 2, 3]);
    });
    await expectLater(bridge.readRange('id', -1, 3), throwsArgumentError);
    await expectLater(
      bridge.readRange('id', 0, mediaReadChunkBytes + 1),
      throwsArgumentError,
    );
    await expectLater(
      bridge.readPreview('/home/user/a.jpg', maxDimension: 2561),
      throwsArgumentError,
    );
    expect(calls, 0);
    expect(await bridge.readRange('id', 5000000000, 3), [1, 2, 3]);
    expect(await bridge.readPreview('/home/user/a.jpg'), [1, 2, 3]);
  });

  test(
    'background sharing and discovery are forwarded without job scheduling',
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
          expect(call.arguments, {
            'id': 'linux-id',
            'name': '工作站',
            'port': 50728,
          });
        }
        if (call.method == 'transferSpace') {
          return {
            'stagingAvailableBytes': 1 << 40,
            'destinationAvailableBytes': 1 << 30,
            'sameVolume': false,
          };
        }
        return null;
      });
      expect((await bridge.setBackgroundSharing(true)).running, isTrue);
      expect((await bridge.setBackgroundSharing(false)).running, isFalse);
      await bridge.startDiscovery(id: 'linux-id', name: '工作站', port: 50728);
      await bridge.stopDiscovery();
      await bridge.setTransferActivity('task', active: true);
      final space = await bridge.transferSpace(directoryUri: '/media/disk');
      expect(space.stagingAvailableBytes, 1 << 40);
      expect(space.sameVolume, isFalse);
      expect(calls, [
        'setBackgroundSharing',
        'setBackgroundSharing',
        'startDiscovery',
        'stopDiscovery',
        'transferSpace',
      ]);
    },
  );
}
