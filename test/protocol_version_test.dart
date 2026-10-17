import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/network/media_rpc.dart';

void main() {
  test('every platform advertises the current gRPC protocol version', () {
    final version = '$mediaProtocolVersion';
    String read(String path) => File(path).readAsStringSync();
    expect(
      read('android/app/src/main/kotlin/dev/tamayura/app/LanDiscovery.kt'),
      contains('setAttribute("version", "$version")'),
    );
    expect(
      read('macos/Runner/LanDiscovery.swift'),
      contains('"version": Data("$version".utf8)'),
    );
    expect(
      read('windows/runner/discovery_core.h'),
      contains('kProtocolVersion[] = "$version"'),
    );
    expect(read('proto/media.proto'), contains('// Protocol v$version.'));
  });
}
