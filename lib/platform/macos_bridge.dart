import 'platform_bridge.dart';
export 'platform_bridge.dart' show SharingStatus;

/// Native macOS folders, previews and Bonjour, with Dart-managed downloads.
class MacOSBridge extends PlatformBridge {
  const MacOSBridge({super.methods, super.events, super.sharing});

  @override
  String get platformName => 'Mac';

  @override
  bool get usesInProcessTransfers => true;

  Future<bool> isMainWindowVisible() async =>
      await methodChannel.invokeMethod<bool>('isMainWindowVisible') ?? false;

  @override
  Future<void> setTransferActivity(String taskId, {required bool active}) =>
      methodChannel.invokeMethod<void>('setTransferActivity', {
        'taskId': taskId,
        'active': active,
      });

  @override
  bool isValidDeviceId(String id) => RegExp(
    r'^macos-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id);
}
