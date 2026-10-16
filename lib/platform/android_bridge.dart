import 'platform_bridge.dart';
export 'platform_bridge.dart' show SharingStatus;

/// Android Storage Access Framework, DNS-SD and JobService adapter.
class AndroidBridge extends PlatformBridge {
  const AndroidBridge({super.methods, super.events, super.sharing});

  @override
  String get platformName => 'Android';

  @override
  bool isValidDeviceId(String id) =>
      RegExp(r'^android-[0-9a-f]{1,16}$').hasMatch(id);
}
