import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/platform/android_bridge.dart';
import 'package:tamayura/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/tamayura/platform');
  const events = EventChannel('test/tamayura/discovery');
  const sharing = EventChannel('test/tamayura/sharing');
  const bridge = AndroidBridge(
    methods: methods,
    events: events,
    sharing: sharing,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  const folder = SharedFolder(
    id: 'photos',
    uri: 'content://documents/tree/photos',
    name: 'Photos',
  );

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/tamayura/discovery'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/tamayura/sharing'),
      null,
    );
  });

  test('device identity comes from Android on each request', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      expect(call.method, 'deviceId');
      expect(call.arguments, isNull);
      return 'android-a1b2c3d4e5f60708';
    });
    expect(await bridge.deviceId(), 'android-a1b2c3d4e5f60708');
    expect(await bridge.deviceId(), 'android-a1b2c3d4e5f60708');
    expect(calls, hasLength(2));
  });

  test(
    'sharing uses acknowledged native state and forwards failures',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return {'enabled': true, 'running': true, 'batteryExempt': false};
      });
      final enabled = await bridge.setBackgroundSharing(true);
      expect(calls.single.method, 'setBackgroundSharing');
      expect(calls.single.arguments, {'enabled': true});
      expect(enabled.enabled, isTrue);
      expect(enabled.running, isTrue);
      expect(enabled.starting, isFalse);
      expect(enabled.sessionId, isNull);
      expect(enabled.batteryExempt, isFalse);
      await bridge.sharingStatus();
      expect(calls.last.method, 'sharingStatus');
      await bridge.openBatteryOptimizationSettings();
      expect(calls.last.method, 'openBatteryOptimizationSettings');

      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'BACKGROUND_SHARING_FAILED');
      });
      await expectLater(
        bridge.setBackgroundSharing(true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'BACKGROUND_SHARING_FAILED',
          ),
        ),
      );
    },
  );

  test(
    'sharing startup reports are scoped to the native service session',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return true;
      });
      expect(await bridge.reportSharingReady('start-1'), isTrue);
      expect(calls.last.method, 'reportSharingReady');
      expect(calls.last.arguments, {'sessionId': 'start-1'});
      expect(await bridge.reportSharingFailure('start-2', '无法监听共享端口'), isTrue);
      expect(calls.last.method, 'reportSharingFailure');
      expect(calls.last.arguments, {
        'sessionId': 'start-2',
        'error': '无法监听共享端口',
      });
      messenger.setMockMethodCallHandler(methods, (_) async => false);
      expect(await bridge.reportSharingReady('stale-start'), isFalse);
      expect(await bridge.reportSharingFailure('stale-start', '启动失败'), isFalse);
      messenger.setMockMethodCallHandler(methods, (_) async => null);
      expect(await bridge.reportSharingReady('missing-response'), isFalse);
      expect(
        await bridge.reportSharingFailure('missing-response', '启动失败'),
        isFalse,
      );
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'SHARING_REPORT_FAILED');
      });
      await expectLater(
        bridge.reportSharingReady('start-1'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        bridge.reportSharingFailure('start-1', '启动失败'),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'sharing startup events preserve readiness, session and failure',
    () async {
      messenger.setMockMethodCallHandler(
        const MethodChannel('test/tamayura/sharing'),
        (_) async => null,
      );
      final states = <SharingStatus>[];
      final subscription = bridge.sharingEvents.listen(states.add);
      await Future<void>.delayed(Duration.zero);
      for (final state in [
        {'starting': true, 'running': false, 'sessionId': 'start-1'},
        {'starting': false, 'running': true, 'sessionId': 'start-1'},
        {'starting': false, 'running': false, 'error': '共享初始化失败'},
      ]) {
        await messenger.handlePlatformMessage(
          'test/tamayura/sharing',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'enabled': true,
            'batteryExempt': true,
            ...state,
          }),
          (_) {},
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(states, hasLength(3));
      expect(states[0].starting, isTrue);
      expect(states[0].running, isFalse);
      expect(states[0].sessionId, 'start-1');
      expect(states[1].starting, isFalse);
      expect(states[1].running, isTrue);
      expect(states[2].enabled, isTrue);
      expect(states[2].running, isFalse);
      expect(states[2].error, '共享初始化失败');
      await subscription.cancel();
    },
  );

  test(
    'missing native state never silently reports successful sharing',
    () async {
      for (final value in [
        null,
        <String, Object>{},
        {'enabled': true, 'running': 'yes', 'batteryExempt': true},
        {
          'enabled': true,
          'running': false,
          'batteryExempt': true,
          'starting': null,
        },
        {
          'enabled': true,
          'running': false,
          'batteryExempt': true,
          'starting': 'yes',
        },
        {
          'enabled': true,
          'running': true,
          'batteryExempt': true,
          'starting': true,
        },
        {
          'enabled': true,
          'running': false,
          'batteryExempt': true,
          'sessionId': 42,
        },
        {'enabled': true, 'running': false, 'batteryExempt': true, 'error': 42},
      ]) {
        messenger.setMockMethodCallHandler(methods, (_) async => value);
        await expectLater(bridge.sharingStatus(), throwsFormatException);
        await expectLater(
          bridge.setBackgroundSharing(true),
          throwsFormatException,
        );
      }
      final status = SharingStatus.fromMap({
        'enabled': false,
        'running': false,
        'batteryExempt': true,
        'error': '后台共享启动失败',
      });
      expect(status.error, '后台共享启动失败');
    },
  );

  test(
    'missing or malformed identities fail without a random fallback',
    () async {
      for (final id in <String?>[
        null,
        '',
        ' ',
        'random-uuid',
        'android-not-hex',
        'android-0123456789abcdef0',
      ]) {
        messenger.setMockMethodCallHandler(methods, (_) async => id);
        await expectLater(
          bridge.deviceId(),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'DEVICE_ID_UNAVAILABLE',
            ),
          ),
        );
      }
    },
  );

  test('system identity read errors reach the caller', () async {
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(
        code: 'DEVICE_ID_UNAVAILABLE',
        message: '无法读取 Android 设备标识，请重启应用后重试',
      );
    });
    await expectLater(
      bridge.deviceId(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'DEVICE_ID_UNAVAILABLE',
        ),
      ),
    );
  });

  test(
    'local info keeps a human-readable name separate from identity',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'localInfo');
        return {
          'name': '我的手机',
          'addresses': ['192.168.1.2'],
        };
      });
      expect(await bridge.localInfo(), {
        'name': '我的手机',
        'addresses': ['192.168.1.2'],
      });
    },
  );

  test('cache directory requires a usable native path', () async {
    await expectLater(
      bridge.temporaryDirectory(),
      throwsA(isA<PlatformException>()),
    );
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'temporaryDirectory');
      return '/data/user/0/dev.tamayura.app/cache';
    });
    expect(
      await bridge.temporaryDirectory(),
      '/data/user/0/dev.tamayura.app/cache',
    );
  });

  test('directory picker cancellation stays null', () async {
    expect(await bridge.pickDirectory(), isNull);
    expect(calls.single.method, 'pickDirectory');
  });

  test(
    'overlap validation forwards every existing root and preserves native rejection',
    () async {
      await bridge.validateSharedDirectory('content://new', [
        'content://one',
        'content://two',
      ]);
      expect(calls.single.method, 'validateSharedDirectory');
      expect(calls.single.arguments, {
        'uri': 'content://new',
        'existingUris': ['content://one', 'content://two'],
      });
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(
          code: 'DIR_OVERLAP',
          message: '此目录与现有共享目录存在父子关系',
        );
      });
      await expectLater(
        bridge.validateSharedDirectory('content://child', ['content://parent']),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'DIR_OVERLAP',
          ),
        ),
      );
    },
  );

  test(
    'metadata scan preserves integer sizes without eager thumbnails',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'scanDirectoriesMetadata');
        expect(call.arguments, {
          'directories': [folder.toJson()],
        });
        return [
          {
            'id': 'opaque-id',
            'name': 'photo.jpg',
            'sharedFolderId': 'photos',
            'sharedFolderName': 'Photos',
            'relativePath': '旅行/photo.jpg',
            'mimeType': 'image/jpeg',
            'size': 9000000000,
            'modifiedMs': 123,
          },
        ];
      });
      final entries = await bridge.scanDirectoriesMetadata([folder]);
      expect(entries.single['size'], 9000000000);
      expect(entries.single['relativePath'], '旅行/photo.jpg');
      expect(entries.single['sharedFolderId'], 'photos');
      expect(entries.single.containsKey('thumbnail'), isFalse);
    },
  );

  test('range requests preserve 64-bit offsets and raw bytes', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'readRange');
      expect(call.arguments, {
        'id': 'opaque-id',
        'offset': 9000000000,
        'length': 3,
      });
      return Uint8List.fromList([0, 128, 255]);
    });
    expect(
      await bridge.readRange('opaque-id', 9000000000, 3),
      Uint8List.fromList([0, 128, 255]),
    );
  });

  test('invalid ranges never cross the platform channel', () async {
    await expectLater(bridge.readRange('id', -1, 1), throwsArgumentError);
    await expectLater(bridge.readRange('id', 0, -1), throwsArgumentError);
    await expectLater(bridge.readRange('id', 0, 262145), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('thumbnail is requested individually by its opaque media id', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'thumbnail');
      expect(call.arguments, {'id': 'media-id'});
      return Uint8List.fromList([1, 2, 3]);
    });
    expect(await bridge.thumbnail('media-id'), Uint8List.fromList([1, 2, 3]));
  });

  test(
    'background scheduling, cancellation and recovery use stable task ids',
    () async {
      await bridge.scheduleTransfer('task-id');
      await bridge.cancelTransfer('task-id');
      expect(calls.map((call) => call.method), [
        'scheduleTransfer',
        'cancelTransfer',
      ]);
      expect(
        calls.every((call) => call.arguments['taskId'] == 'task-id'),
        isTrue,
      );
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'scheduledTransferIds');
        return ['running-task', 'waiting-task'];
      });
      expect(await bridge.scheduledTransferIds(), [
        'running-task',
        'waiting-task',
      ]);
    },
  );

  test('system scheduling failures remain visible to the caller', () async {
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(code: 'TRANSFER_SCHEDULE_FAILED');
    });
    await expectLater(
      bridge.scheduleTransfer('task'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'TRANSFER_SCHEDULE_FAILED',
        ),
      ),
    );
  });

  test('persistent transfer directory must be provided by Android', () async {
    await expectLater(
      bridge.transferDirectory(),
      throwsA(isA<PlatformException>()),
    );
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'transferDirectory');
      return '/app/files/transfer-staging';
    });
    expect(await bridge.transferDirectory(), '/app/files/transfer-staging');
  });

  test(
    'saved photo preview is bounded before it reaches native decoding',
    () async {
      await expectLater(
        bridge.readPreview('content://photo', maxDimension: 2561),
        throwsArgumentError,
      );
      await expectLater(
        bridge.readPreview('content://photo', maxDimension: 0),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
      messenger.setMockMethodCallHandler(methods, (call) async {
        expect(call.method, 'readPreview');
        expect(call.arguments, {
          'uri': 'content://photo',
          'maxDimension': 2560,
        });
        return Uint8List.fromList([255, 216, 255]);
      });
      expect(
        await bridge.readPreview('content://photo'),
        Uint8List.fromList([255, 216, 255]),
      );
    },
  );

  test('lost permission errors propagate for the app to handle', () async {
    messenger.setMockMethodCallHandler(methods, (_) async {
      throw PlatformException(code: 'PERMISSION_LOST', message: '目录授权已失效');
    });
    await expectLater(
      bridge.scanDirectoriesMetadata([folder]),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'PERMISSION_LOST',
        ),
      ),
    );
  });

  test('save forwards destination and requires a resulting URI', () async {
    await expectLater(
      bridge.saveDownload(
        sourcePaths: ['/private/cache/0.part', '/private/cache/1.part'],
        expectedSize: 42,
        directoryUri: 'content://documents/tree/downloads',
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        directories: ['手机', 'Photos', '旅行'],
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(calls.single.method, 'saveDownload');
    expect(calls.single.arguments, {
      'directories': ['手机', 'Photos', '旅行'],
      'sourcePaths': ['/private/cache/0.part', '/private/cache/1.part'],
      'expectedSize': 42,
      'directoryUri': 'content://documents/tree/downloads',
      'name': 'photo.jpg',
      'mimeType': 'image/jpeg',
    });
  });

  test('deleted saved documents propagate errors before sharing', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'share');
      throw PlatformException(
        code: 'FILE_NOT_FOUND',
        message: '已下载文件已不可用，请重新下载',
      );
    });
    await expectLater(
      bridge.share('content://saved/deleted-photo', 'image/jpeg'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'FILE_NOT_FOUND',
        ),
      ),
    );
  });

  test('share, open, revoke and discovery forward their arguments', () async {
    await bridge.share('content://saved/photo', 'image/jpeg');
    await bridge.open('content://saved/photo', 'image/jpeg');
    await bridge.clearSharedDirectory();
    await bridge.startDiscovery(id: 'device-id', name: '手机', port: 50051);
    await bridge.stopDiscovery();
    expect(calls.map((call) => call.method), [
      'share',
      'open',
      'clearSharedDirectory',
      'startDiscovery',
      'stopDiscovery',
    ]);
    expect(calls[0].arguments, {
      'uri': 'content://saved/photo',
      'mimeType': 'image/jpeg',
    });
    expect(calls[3].arguments, {
      'id': 'device-id',
      'name': '手机',
      'port': 50051,
    });
  });

  test(
    'DNS-SD events preserve host, device identity and service port',
    () async {
      messenger.setMockMethodCallHandler(
        const MethodChannel('test/tamayura/discovery'),
        (_) async => null,
      );
      final first = bridge.discoveryEvents.first;
      await Future<void>.delayed(Duration.zero);
      final event = <String, dynamic>{
        'type': 'found',
        'id': 'remote-id',
        'name': '另一部手机',
        'host': '192.168.1.2',
        'port': 50051,
      };
      await messenger.handlePlatformMessage(
        'test/tamayura/discovery',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
      expect(await first, event);
    },
  );
}
