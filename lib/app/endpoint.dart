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
      throw const FormatException('请输入局域网 IPv4 地址，或扫描 Tamayura 二维码');
    }
    final octets = match[1]!.split('.').map(int.parse).toList();
    if (octets.any((part) => part > 255)) {
      throw const FormatException(
        '请输入有效的局域网 IPv4 地址，例如 192.168.1.8:$defaultPort',
      );
    }
    final a = octets[0], b = octets[1];
    if (!(a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254))) {
      throw const FormatException('当前原型仅支持局域网私有 IPv4 地址');
    }
    final port = match[2] == null ? defaultPort : int.tryParse(match[2]!);
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('端口应为 1 到 65535');
    }
    return LanEndpoint(octets.join('.'), port);
  }

  String get pairingUri => 'tamayura://$host:$port?v=1';
}
