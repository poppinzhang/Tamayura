import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';

/// Capacity is advisory: document providers may not expose their backing volume.
class TransferSpaceInfo {
  const TransferSpaceInfo({
    this.stagingAvailableBytes,
    this.destinationAvailableBytes,
    this.sameVolume,
  });
  final int? stagingAvailableBytes, destinationAvailableBytes;
  final bool? sameVolume;
}

class SharingStatus {
  const SharingStatus({
    required this.enabled,
    required this.running,
    required this.batteryExempt,
    this.starting = false,
    this.sessionId,
    this.error,
  });

  factory SharingStatus.fromMap(Map<dynamic, dynamic> value) {
    if (value['enabled'] is! bool ||
        value['running'] is! bool ||
        value['batteryExempt'] is! bool ||
        (value.containsKey('starting') && value['starting'] is! bool) ||
        (value['sessionId'] != null && value['sessionId'] is! String) ||
        (value['error'] != null && value['error'] is! String) ||
        (value['starting'] == true && value['running'] == true)) {
      throw const FormatException('无法读取后台共享状态，请重试');
    }
    return SharingStatus(
      enabled: value['enabled'] as bool,
      running: value['running'] as bool,
      batteryExempt: value['batteryExempt'] as bool,
      starting: value['starting'] as bool? ?? false,
      sessionId: value['sessionId'] as String?,
      error: value['error'] as String?,
    );
  }

  final bool enabled, running, batteryExempt, starting;
  final String? sessionId, error;
}

/// Native storage, media and DNS-SD contract shared by supported platforms.
/// Local URIs never travel to peers: remote reads use opaque scanned IDs.
abstract class PlatformBridge {
  const PlatformBridge({
    MethodChannel methods = const MethodChannel('tamayura/platform'),
    EventChannel events = const EventChannel('tamayura/discovery'),
    EventChannel sharing = const EventChannel('tamayura/sharing'),
  }) : _methods = methods,
       _events = events,
       _sharing = sharing;

  /// macOS workers live in the application process; Android uses JobService.
  bool get usesInProcessTransfers => false;
  String get platformName;
  bool isValidDeviceId(String id);

  final MethodChannel _methods;
  final EventChannel _events;
  final EventChannel _sharing;

  @protected
  MethodChannel get methodChannel => _methods;

  Stream<SharingStatus> get sharingEvents => _sharing
      .receiveBroadcastStream()
      .map((event) => SharingStatus.fromMap(event as Map));

  Future<SharingStatus> sharingStatus() async => SharingStatus.fromMap(
    await _methods.invokeMapMethod<String, dynamic>('sharingStatus') ?? {},
  );

  Future<SharingStatus> setBackgroundSharing(bool enabled) async =>
      SharingStatus.fromMap(
        await _methods.invokeMapMethod<String, dynamic>(
              'setBackgroundSharing',
              {'enabled': enabled},
            ) ??
            {},
      );

  /// Android acknowledges a specific service start only after Dart is ready.
  /// Desktop sharing is owned by its application process and needs no handshake.
  Future<bool> reportSharingReady(String sessionId) async => false;

  Future<bool> reportSharingFailure(String sessionId, String error) async =>
      false;

  Future<void> openBatteryOptimizationSettings() =>
      _methods.invokeMethod<void>('openBatteryOptimizationSettings');

  Stream<Map<String, dynamic>> get discoveryEvents => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  Future<Map<String, dynamic>?> pickDirectory() async {
    final value = await _methods.invokeMapMethod<String, dynamic>(
      'pickDirectory',
    );
    return value;
  }

  Future<void> validateSharedDirectory(String uri, List<String> existingUris) =>
      _methods.invokeMethod<void>('validateSharedDirectory', {
        'uri': uri,
        'existingUris': existingUris,
      });

  Future<List<Map<String, dynamic>>> scanDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    final values = await _methods.invokeListMethod<dynamic>(
      'scanDirectoriesMetadata',
      {'directories': directories.map((folder) => folder.toJson()).toList()},
    );
    return (values ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
  }

  Future<Uint8List> thumbnail(String id) async =>
      await _methods.invokeMethod<Uint8List>('thumbnail', {'id': id}) ??
      Uint8List(0);

  Future<void> scheduleTransfer(String taskId) =>
      _methods.invokeMethod<void>('scheduleTransfer', {'taskId': taskId});

  Future<void> cancelTransfer(String taskId) =>
      _methods.invokeMethod<void>('cancelTransfer', {'taskId': taskId});

  /// Platforms may keep process-owned transfers active while their worker runs.
  /// Only platforms requiring an activity assertion override this hook.
  Future<void> setTransferActivity(
    String taskId, {
    required bool active,
  }) async {}

  Future<String> transferDirectory() async {
    final path = await _methods.invokeMethod<String>('transferDirectory');
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'STAGING_UNAVAILABLE',
        message: '下载暂存目录不可用',
      );
    }
    return path;
  }

  Future<List<String>> scheduledTransferIds() async =>
      await _methods.invokeListMethod<String>('scheduledTransferIds') ??
      const <String>[];

  Future<Uint8List> readPreview(String uri, {int maxDimension = 2560}) async {
    if (maxDimension < 1 || maxDimension > 2560) {
      throw ArgumentError.value(
        maxDimension,
        'maxDimension',
        'Must be between 1 and 2560',
      );
    }
    return await _methods.invokeMethod<Uint8List>('readPreview', {
          'uri': uri,
          'maxDimension': maxDimension,
        }) ??
        Uint8List(0);
  }

  Future<void> clearSharedDirectory() =>
      _methods.invokeMethod<void>('clearSharedDirectory');

  Future<Uint8List> readRange(String id, int offset, int length) async {
    if (offset < 0 || length < 0 || length > mediaReadChunkBytes) {
      throw ArgumentError(
        'Range must have offset >= 0 and 0 <= length <= '
        '$mediaReadChunkBytes bytes',
      );
    }
    return await _methods.invokeMethod<Uint8List>('readRange', {
          'id': id,
          'offset': offset,
          'length': length,
        }) ??
        Uint8List(0);
  }

  Future<String> saveDownload({
    required List<String> sourcePaths,
    required int expectedSize,
    required String directoryUri,
    required String name,
    required String mimeType,
    required List<String> directories,
  }) async {
    final uri = await _methods.invokeMethod<String>('saveDownload', {
      'sourcePaths': sourcePaths,
      'expectedSize': expectedSize,
      'directoryUri': directoryUri,
      'name': name,
      'mimeType': mimeType,
      'directories': directories,
    });
    if (uri == null || uri.isEmpty) {
      throw PlatformException(code: 'SAVE_FAILED', message: '未能保存文件');
    }
    return uri;
  }

  /// Missing files are already deleted; other storage errors must be surfaced.
  Future<void> deleteDownload(String uri) =>
      _methods.invokeMethod<void>('deleteDownload', {'uri': uri});

  Future<TransferSpaceInfo> transferSpace({
    required String directoryUri,
  }) async {
    Map<String, dynamic>? value;
    try {
      value = await _methods.invokeMapMethod<String, dynamic>('transferSpace', {
        'directoryUri': directoryUri,
      });
    } on MissingPluginException {
      return const TransferSpaceInfo();
    }
    int? capacity(String key) {
      final bytes = value?[key];
      return bytes is int && bytes >= 0 ? bytes : null;
    }

    return TransferSpaceInfo(
      stagingAvailableBytes: capacity('stagingAvailableBytes'),
      destinationAvailableBytes: capacity('destinationAvailableBytes'),
      sameVolume: value?['sameVolume'] is bool
          ? value!['sameVolume'] as bool
          : null,
    );
  }

  Future<void> share(String uri, String mimeType) =>
      _methods.invokeMethod<void>('share', {'uri': uri, 'mimeType': mimeType});

  Future<void> open(String uri, String mimeType) =>
      _methods.invokeMethod<void>('open', {'uri': uri, 'mimeType': mimeType});

  Future<String> temporaryDirectory() async {
    final path = await _methods.invokeMethod<String>('temporaryDirectory');
    if (path == null || path.isEmpty) {
      throw PlatformException(code: 'CACHE_UNAVAILABLE', message: '临时目录不可用');
    }
    return path;
  }

  Future<Map<String, dynamic>> localInfo() async =>
      await _methods.invokeMapMethod<String, dynamic>('localInfo') ??
      <String, dynamic>{'name': platformName, 'addresses': <String>[]};

  /// System-scoped identity, independent of application data and device name.
  Future<String> deviceId() async {
    final id = await _methods.invokeMethod<String>('deviceId');
    if (id == null || !isValidDeviceId(id)) {
      throw PlatformException(
        code: 'DEVICE_ID_UNAVAILABLE',
        message: '无法读取 $platformName 设备标识，请重启应用后重试',
      );
    }
    return id;
  }

  Future<void> startDiscovery({
    required String id,
    required String name,
    required int port,
  }) => _methods.invokeMethod<void>('startDiscovery', {
    'id': id,
    'name': name,
    'port': port,
  });

  Future<void> stopDiscovery() => _methods.invokeMethod<void>('stopDiscovery');
}
