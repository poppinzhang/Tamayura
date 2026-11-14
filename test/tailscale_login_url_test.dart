import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/platform/android_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'browser launcher accepts only an official authentication link',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tamayura/platform'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('tamayura/platform'),
              null,
            ),
      );
      const bridge = AndroidBridge();
      for (final url in [
        'http://login.tailscale.com/a/test',
        'https://login.tailscale.com.evil.test/a/test',
        'https://user@login.tailscale.com/a/test',
        'https://login.tailscale.com:8443/a/test',
        'https://example.test/a/test',
        'file:///tmp/test',
        'https://login.tailscale.com/admin',
      ]) {
        expect(
          () => bridge.openTailscaleLogin(Uri.parse(url)),
          throwsFormatException,
        );
      }
      expect(calls, isEmpty);
      await bridge.openTailscaleLogin(
        Uri.parse('https://login.tailscale.com/a/test'),
      );
      expect(calls.single.method, 'openTailscaleLogin');
    },
  );
}
