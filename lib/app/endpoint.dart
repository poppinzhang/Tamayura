import '../l10n/app_locale.dart';

/// First prototype uses IPv4 LAN addresses, including private hotspot networks.
class LanEndpoint {
  const LanEndpoint(this.host, this.port);
  final String host;
  final int port;
  static const defaultPort = 50728;

  static LanEndpoint parse(String value) {
    // Parse the port before Uri normalization: an unknown URI scheme normalizes
    // an explicit :0 away, which must not silently become our default port.
    final match = RegExp(
      r'^(?:tamayura://)?(\d{1,3}(?:\.\d{1,3}){3})(?::(\d+))?/?(?:\?v=1)?$',
    ).firstMatch(value.trim());
    if (match == null) {
      throw FormatException(AppLocale.strings.errorAddressRequired);
    }
    final octets = match[1]!.split('.').map(int.parse).toList();
    if (octets.any((part) => part > 255)) {
      throw FormatException(AppLocale.strings.errorAddressInvalid(defaultPort));
    }
    final a = octets[0], b = octets[1];
    if (!(a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254))) {
      throw FormatException(AppLocale.strings.errorAddressNotPrivate);
    }
    final port = match[2] == null ? defaultPort : int.tryParse(match[2]!);
    if (port == null || port < 1 || port > 65535) {
      throw FormatException(AppLocale.strings.errorPortRange);
    }
    return LanEndpoint(octets.join('.'), port);
  }

  String get pairingUri => 'tamayura://$host:$port?v=1';
}
