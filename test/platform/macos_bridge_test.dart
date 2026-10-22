import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/background/transfer_scheduler.dart';
import 'package:tamayura/core/models.dart';
import 'package:tamayura/platform/android_bridge.dart';
import 'package:tamayura/platform/default_bridge.dart';
import 'package:tamayura/platform/linux_bridge.dart';
import 'package:tamayura/platform/macos_bridge.dart';
import 'package:tamayura/platform/windows_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/tamayura/macos');
  const bridge = MacOSBridge(methods: methods);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('main-window visibility uses native window state', () async {
    for (final visible in [true, false, null]) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'isMainWindowVisible');
        return visible;
      });
      expect(await bridge.isMainWindowVisible(), visible ?? false);
    }
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(code: 'WINDOW_UNAVAILABLE');
    });
    await expectLater(
      bridge.isMainWindowVisible(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('macOS selects the desktop bridge and process-owned transfers', () {
    expect(bridge.usesInProcessTransfers, isTrue);
    expect(const AndroidBridge().usesInProcessTransfers, isFalse);
    if (Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid) {
      expect(
        defaultPlatformBridge(),
        Platform.isMacOS
            ? isA<MacOSBridge>()
            : Platform.isWindows
            ? isA<WindowsBridge>()
            : Platform.isLinux
            ? isA<LinuxBridge>()
            : isA<AndroidBridge>(),
      );
    } else {
      expect(defaultPlatformBridge, throwsUnsupportedError);
    }
  });

  test(
    'download activity forwards task identity and surfaces native errors',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      });
      await bridge.setTransferActivity('download-1', active: true);
      await bridge.setTransferActivity('download-1', active: false);
      expect(calls.map((call) => call.method), [
        'setTransferActivity',
        'setTransferActivity',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'taskId': 'download-1', 'active': true},
        {'taskId': 'download-1', 'active': false},
      ]);
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'ACTIVITY_FAILED', message: '后台下载不可用');
      });
      await expectLater(
        bridge.setTransferActivity('download-1', active: true),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'default transfer activity does not invoke a native platform method',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      });
      const defaultBridge = AndroidBridge(methods: methods);
      await defaultBridge.setTransferActivity('download-1', active: true);
      await defaultBridge.setTransferActivity('download-1', active: false);
      expect(calls, isEmpty);
    },
  );

  test(
    'Android job scheduling never requests macOS transfer activity',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'scheduledTransferIds') return ['download-1'];
        expect(call.arguments, {'taskId': 'download-1'});
        return null;
      });
      const scheduler = NativeTransferScheduler(
        AndroidBridge(methods: methods),
      );
      await scheduler.scheduleTransfer('download-1');
      expect(await scheduler.scheduledTransferIds(), ['download-1']);
      await scheduler.cancelTransfer('download-1');
      await scheduler.shutdown();
      expect(calls, [
        'scheduleTransfer',
        'scheduledTransferIds',
        'cancelTransfer',
      ]);
    },
  );

  test(
    'macOS identity is native, stable and validated without fallback',
    () async {
      const identity = 'macos-aabbccdd-1234-5678-abcd-123456789abc';
      var reads = 0;
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'deviceId');
        reads++;
        return identity;
      });
      expect(await bridge.deviceId(), identity);
      expect(await bridge.deviceId(), identity);
      expect(reads, 2);
      for (final invalid in [
        null,
        '',
        'macos-invalid',
        'android-1234',
        'macos-AABBCCDD-1234-5678-ABCD-123456789ABC',
      ]) {
        messenger.setMockMethodCallHandler(methods, (_) async => invalid);
        await expectLater(bridge.deviceId(), throwsA(isA<PlatformException>()));
      }
    },
  );

  test(
    'file URLs and shared folder identity retain the Android wire contract',
    () async {
      const folder = SharedFolder(
        id: 'photos',
        uri: 'file:///Users/test/Pictures/',
        name: 'Pictures',
      );
      messenger.setMockMethodCallHandler(methods, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return {'uri': folder.uri, 'name': folder.name};
          case 'scanDirectoriesMetadata':
            expect(call.arguments, {
              'directories': [folder.toJson()],
            });
            return [
              {
                'id': 'opaque-local-id',
                'name': 'photo.heic',
                'sharedFolderId': folder.id,
                'sharedFolderName': folder.name,
                'relativePath': '旅行/photo.heic',
                'mimeType': 'image/heic',
                'size': 9000000000,
                'modifiedMs': 1234,
              },
            ];
          case 'saveDownload':
            expect(call.arguments['directoryUri'], folder.uri);
            expect(call.arguments['sourcePaths'], [
              '/private/tmp/transfer/0.part',
            ]);
            expect(call.arguments['expectedSize'], 9000000000);
            expect(call.arguments['directories'], ['Phone', 'Camera', '旅行']);
            return '${folder.uri}Phone/Camera/photo.heic';
          default:
            fail('Unexpected platform call: ${call.method}');
        }
      });
      expect((await bridge.pickDirectory())!['uri'], folder.uri);
      final metadata = (await bridge.scanDirectoriesMetadata([folder])).single;
      expect(metadata['size'], 9000000000);
      expect(metadata['relativePath'], '旅行/photo.heic');
      expect(
        await bridge.saveDownload(
          sourcePaths: ['/private/tmp/transfer/0.part'],
          expectedSize: 9000000000,
          directoryUri: folder.uri,
          name: 'photo.heic',
          mimeType: 'image/heic',
          directories: ['Phone', 'Camera', '旅行'],
        ),
        '${folder.uri}Phone/Camera/photo.heic',
      );
    },
  );

  test(
    'background sharing reports native preference and no battery exemption UI',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'setBackgroundSharing');
        final enabled = call.arguments['enabled'] as bool;
        return {'enabled': enabled, 'running': enabled, 'batteryExempt': true};
      });
      final enabled = await bridge.setBackgroundSharing(true);
      expect(enabled.enabled, isTrue);
      expect(enabled.running, isTrue);
      expect(enabled.batteryExempt, isTrue);
      expect((await bridge.setBackgroundSharing(false)).running, isFalse);
    },
  );
}
