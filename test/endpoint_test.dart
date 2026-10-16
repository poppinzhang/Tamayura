import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/app/endpoint.dart';

void main() {
  test('accepts private LAN, hotspot and QR endpoints', () {
    for (final host in [
      '192.168.1.8',
      '10.0.0.2',
      '172.16.0.1',
      '172.31.255.1',
      '169.254.2.3',
    ]) {
      final endpoint = LanEndpoint.parse(' $host ');
      expect(endpoint.host, host);
      expect(endpoint.port, 50728);
      expect(endpoint.pairingUri, 'tamayura://$host:50728?v=1');
      final decoded = LanEndpoint.parse(endpoint.pairingUri);
      expect(decoded.host, host);
      expect(decoded.port, 50728);
    }
    expect(LanEndpoint.parse('192.168.1.1:1234').port, 1234);
  });
  test(
    'QR endpoints use the default or preserve an advertised custom port',
    () {
      expect(LanEndpoint.parse('tamayura://192.168.1.8?v=1').port, 50728);
      const custom = LanEndpoint('192.168.1.8', 54321);
      expect(LanEndpoint.parse(custom.pairingUri).port, 54321);
    },
  );
  test('rejects invalid, public, unsupported and malicious endpoints', () {
    for (final input in [
      '',
      '8.8.8.8',
      '127.0.0.1',
      '172.32.0.1',
      '192.168.1.256',
      '192.168.1',
      'localhost',
      '::1',
      'https://192.168.1.1',
      'tamayura://user@192.168.1.1',
      '192.168.1.1/path',
      '192.168.1.1:0',
      '192.168.1.1:65536',
      '192.168.1.1:abc',
      'tamayura://192.168.1.1?v=2',
      'tamayura://192.168.1.1?bad=1',
    ]) {
      expect(
        () => LanEndpoint.parse(input),
        throwsFormatException,
        reason: input,
      );
    }
  });
}
