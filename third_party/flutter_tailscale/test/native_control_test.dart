import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_tailscale/src/control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android initialize goes through engine-owned platform registration',
    () async {
      const channel = MethodChannel('dev.fluttertailscale/network');
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'initialize') {
              final request = jsonDecode(call.arguments as String) as Map;
              expect(request['method'], 'initialize');
              return jsonEncode({
                'id': request['id'],
                'result': {'ownerId': 'test-owner'},
              });
            }
            expect(call.arguments, 'test-owner');
            return null;
          });
      final control = NativeBridgeControl();
      try {
        expect((await control.request('initialize'))['ownerId'], 'test-owner');
        await control.close();
        await control.close();
        expect(methods, ['initialize', 'unregisterOwner']);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
