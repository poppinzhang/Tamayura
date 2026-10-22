import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/update/update_platform.dart';
import 'package:tamayura/update/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('macOS only opens a version page in the official repository', () async {
    const platform = UpdatePlatform(
      channel: channel,
      targetOverride: UpdateTarget.macos,
    );
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final url = Uri.parse(
      'https://github.com/poppinzhang/Tamayura/releases/tag/v0.8.0',
    );
    await platform.openRelease(url);
    expect(calls.single.method, 'openRelease');
    expect(calls.single.arguments, {'url': url.toString()});
    for (final invalid in [
      'http://github.com/poppinzhang/Tamayura/releases/tag/v0.8.0',
      'https://github.com/other/Tamayura/releases/tag/v0.8.0',
      '${url.toString()}?token=value',
      'file:///tmp/test.app',
      'https://github.com/poppinzhang/Tamayura/releases/latest',
    ]) {
      await expectLater(
        platform.openRelease(Uri.parse(invalid)),
        throwsA(isA<UpdateException>()),
      );
    }
    expect(calls.length, 1);
  });

  test('Linux also opens only an official version page', () async {
    const platform = UpdatePlatform(
      channel: channel,
      targetOverride: UpdateTarget.linux,
    );
    expect(platform.target.opensReleasePage, isTrue);
    expect(UpdateTarget.windows.opensReleasePage, isFalse);
    expect(UpdateTarget.android.opensReleasePage, isFalse);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final url = Uri.parse(
      'https://github.com/poppinzhang/Tamayura/releases/tag/v1.0.0',
    );
    await platform.openRelease(url);
    expect(calls.single.arguments, {'url': url.toString()});
    await expectLater(
      platform.openRelease(
        Uri.parse('https://github.com/poppinzhang/Tamayura/releases'),
      ),
      throwsA(isA<UpdateException>()),
    );
    expect(calls, hasLength(1));
  });

  test(
    'native installer receives verified package metadata and rejects unknown responses',
    () async {
      final release = UpdateRelease(
        version: '0.8.0',
        buildNumber: 12,
        notes: '',
        pageUrl: Uri.parse(
          'https://github.com/poppinzhang/Tamayura/releases/tag/v0.8.0',
        ),
        asset: UpdateAsset(
          filename: 'package.apk',
          url: Uri.parse('https://github.com/package.apk'),
          sizeBytes: 100,
          sha256: 'a' * 64,
        ),
      );
      const platform = UpdatePlatform(
        channel: channel,
        targetOverride: UpdateTarget.android,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'installUpdate');
        expect(call.arguments, {
          'path': 'updates/package.apk',
          'sha256': 'a' * 64,
          'version': '0.8.0',
          'buildNumber': 12,
        });
        return 'started';
      });
      expect(
        await platform.install(File('updates/package.apk'), release),
        'started',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => 'unexpected');
      await expectLater(
        platform.install(File('updates/package.apk'), release),
        throwsA(isA<UpdateException>()),
      );
    },
  );

  test(
    'unavailable update directory and native failures surface to caller',
    () async {
      const platform = UpdatePlatform(
        channel: channel,
        targetOverride: UpdateTarget.android,
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await expectLater(platform.directory(), throwsA(isA<UpdateException>()));
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'NO_SPACE');
      });
      await expectLater(
        platform.directory(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
