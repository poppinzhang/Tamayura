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
  bool isValidDeviceId(String id) => RegExp(
    r'^windows-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id);
}
