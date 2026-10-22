import 'platform_bridge.dart';
export 'platform_bridge.dart' show SharingStatus;

/// GTK folders, gdk-pixbuf previews and Avahi DNS-SD, with process-owned
/// downloads.
class LinuxBridge extends PlatformBridge {
  const LinuxBridge({super.methods, super.events, super.sharing});

  @override
  String get platformName => 'Linux';

  @override
  bool get usesInProcessTransfers => true;

  @override
  bool isValidDeviceId(String id) => RegExp(
    r'^linux-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id);
}
