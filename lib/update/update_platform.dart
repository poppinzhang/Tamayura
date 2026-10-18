import 'dart:io';

import 'package:flutter/services.dart';

import '../l10n/app_locale.dart';
import 'update_service.dart';

class UpdatePlatform {
  const UpdatePlatform({
    this.targetOverride,
    this.channel = const MethodChannel('tamayura/updates'),
  });

  final UpdateTarget? targetOverride;
  final MethodChannel channel;

  UpdateTarget get target {
    if (targetOverride != null) return targetOverride!;
    if (Platform.isAndroid) return UpdateTarget.android;
    if (Platform.isWindows) return UpdateTarget.windows;
    if (Platform.isMacOS) return UpdateTarget.macos;
    throw UpdateException(AppLocale.strings.updateErrorPlatform);
  }

  Future<Directory> directory() async {
    final path = await channel.invokeMethod<String>('updateDirectory');
    if (path == null || path.isEmpty) {
      throw UpdateException(AppLocale.strings.updateErrorStagingDirectory);
    }
    return Directory(path);
  }

  Future<String> install(File file, UpdateRelease release) async {
    final asset = release.asset;
    final buildNumber = release.buildNumber;
    if (asset == null || buildNumber == null) {
      throw UpdateException(AppLocale.strings.updateErrorInstallInfo);
    }
    final result = await channel.invokeMethod<String>('installUpdate', {
      'path': file.path,
      'sha256': asset.sha256,
      'version': release.version,
      'buildNumber': buildNumber,
    });
    final allowed = target == UpdateTarget.windows
        ? const ['readyToExit']
        : const ['started', 'pendingUserAction'];
    if (!allowed.contains(result)) {
      throw UpdateException(AppLocale.strings.updateErrorInstallStart);
    }
    return result!;
  }

  Future<void> openRelease(Uri url) async {
    if (url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.hasPort ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !RegExp(
          r'^/poppinzhang/Tamayura/releases/tag/v\d+\.\d+\.\d+$',
        ).hasMatch(url.path)) {
      throw UpdateException(AppLocale.strings.updateErrorReleaseUrl);
    }
    await channel.invokeMethod<void>('openRelease', {'url': url.toString()});
  }

  Future<Map<String, dynamic>> status() async =>
      await channel.invokeMapMethod<String, dynamic>('updateStatus') ??
      const {'state': 'idle'};

  Future<void> exitForUpdate() => channel.invokeMethod<void>('exitForUpdate');
}
