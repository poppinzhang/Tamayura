import 'dart:io';
import 'android_bridge.dart';
import 'macos_bridge.dart';
import 'platform_bridge.dart';
import 'windows_bridge.dart';

PlatformBridge defaultPlatformBridge({String? operatingSystem}) =>
    switch (operatingSystem ?? Platform.operatingSystem) {
      'macos' => const MacOSBridge(),
      'windows' => const WindowsBridge(),
      'android' => const AndroidBridge(),
      final platform => throw UnsupportedError('尚未支持 $platform 平台'),
    };
