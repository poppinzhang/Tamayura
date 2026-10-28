import 'package:flutter/services.dart';

import '../core/models.dart';
import 'platform_bridge.dart';
export 'platform_bridge.dart' show SharingStatus;

/// Win32 folders, Shell previews and DNS-SD, with process-owned downloads.
class WindowsBridge extends PlatformBridge {
  const WindowsBridge({super.methods, super.events, super.sharing});

  @override
  String get platformName => 'Windows';

  @override
  bool get usesInProcessTransfers => true;

  @override
  bool get supportsBackgroundCatalog => true;

  @override
  Future<List<Map<String, dynamic>>?> restoreDirectoriesMetadata(
    List<SharedFolder> directories,
  ) async {
    final values = await methodChannel.invokeListMethod<dynamic>(
      'restoreDirectoriesMetadata',
      {'directories': directories.map((folder) => folder.toJson()).toList()},
    );
    return values == null ? null : metadataMaps(values);
  }

  @override
  Future<PlatformException?> getLocalCatalogWarning() async {
    final warning = await methodChannel.invokeMapMethod<String, dynamic>(
      'getLocalCatalogWarning',
    );
    return warning == null
        ? null
        : PlatformException(
            code: warning['code'] as String,
            message: warning['message'] as String?,
          );
  }

  @override
  bool isValidDeviceId(String id) => RegExp(
    r'^windows-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id);
}
