import 'package:flutter/services.dart';

import '../core/models.dart';
import 'platform_bridge.dart';
export 'platform_bridge.dart' show SharingStatus;

/// Win32 folders, Shell previews and DNS-SD, with process-owned downloads.
class WindowsBridge extends PlatformBridge {
  const WindowsBridge({
    super.methods,
    super.events,
    super.sharing,
    EventChannel catalog = const EventChannel('tamayura/catalog'),
  }) : _catalog = catalog;

  final EventChannel _catalog;

  @override
  String get platformName => 'Windows';

  @override
  bool get usesInProcessTransfers => true;

  @override
  bool get supportsBackgroundCatalog => true;

  @override
  bool get supportsLocalCatalogScheduling => true;

  @override
  Stream<Map<String, dynamic>> get catalogEvents => _catalog
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  @override
  Future<void> startWatchingDirectories(
    List<SharedFolder> directories, {
    required int generation,
  }) => methodChannel.invokeMethod<void>('startWatchingDirectories', {
    'directories': directories.map((folder) => folder.toJson()).toList(),
    'generation': generation,
  });

  @override
  Future<void> stopWatchingDirectories() =>
      methodChannel.invokeMethod<void>('stopWatchingDirectories');

  @override
  Future<List<Map<String, dynamic>>> scanChangedDirectoriesMetadata(
    List<SharedFolder> directories,
    List<LocalCatalogChange> changes,
  ) async => metadataMaps(
    await methodChannel
            .invokeListMethod<dynamic>('scanChangedDirectoriesMetadata', {
              'directories': directories
                  .map((folder) => folder.toJson())
                  .toList(),
              'changes': changes.map((change) => change.toJson()).toList(),
            }) ??
        const [],
  );

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
