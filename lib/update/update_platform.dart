import 'dart:io';

import 'package:flutter/services.dart';

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
    throw const UpdateException('当前平台尚不支持应用更新');
  }

  Future<Directory> directory() async {
    final path = await channel.invokeMethod<String>('updateDirectory');
    if (path == null || path.isEmpty) {
      throw const UpdateException('无法创建更新暂存目录，请检查磁盘空间后重试');
    }
    return Directory(path);
  }

  Future<String> install(File file, UpdateRelease release) async {
    final asset = release.asset;
    final buildNumber = release.buildNumber;
    if (asset == null || buildNumber == null) {
      throw const UpdateException('此版本缺少有效的安装信息');
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
      throw const UpdateException('无法确认安装是否已启动，请重试');
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
      throw const UpdateException('更新页面地址无效');
    }
    await channel.invokeMethod<void>('openRelease', {'url': url.toString()});
  }

  Future<Map<String, dynamic>> status() async =>
      await channel.invokeMapMethod<String, dynamic>('updateStatus') ??
      const {'state': 'idle'};

  Future<void> exitForUpdate() => channel.invokeMethod<void>('exitForUpdate');
}
