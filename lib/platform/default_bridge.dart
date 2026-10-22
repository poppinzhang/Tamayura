import 'dart:io';
import '../l10n/app_locale.dart';
import 'android_bridge.dart';
import 'linux_bridge.dart';
import 'macos_bridge.dart';
import 'platform_bridge.dart';
import 'windows_bridge.dart';

PlatformBridge defaultPlatformBridge({String? operatingSystem}) =>
    switch (operatingSystem ?? Platform.operatingSystem) {
      'macos' => const MacOSBridge(),
      'windows' => const WindowsBridge(),
      'linux' => const LinuxBridge(),
      'android' => const AndroidBridge(),
      final platform => throw UnsupportedError(
        AppLocale.strings.errorPlatformUnsupported(platform),
      ),
    };
