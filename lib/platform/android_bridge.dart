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

  @override
  Future<bool> reportSharingReady(String sessionId) async =>
      await methodChannel.invokeMethod<bool>('reportSharingReady', {
        'sessionId': sessionId,
      }) ??
      false;

  @override
  Future<bool> reportSharingFailure(String sessionId, String error) async =>
      await methodChannel.invokeMethod<bool>('reportSharingFailure', {
        'sessionId': sessionId,
        'error': error,
      }) ??
      false;
}
