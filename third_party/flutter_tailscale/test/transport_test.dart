import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter_tailscale/flutter_tailscale.dart';
import 'package:flutter_tailscale/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SecureServerSocket listener;
  late String certificate;
  late Set<Socket> sockets;
  late int releases;
  late StreamSubscription<SecureSocket> subscription;

  Future<ForwardDescriptor> serve(
    Future<void> Function(SecureSocket) handler,
  ) async {
    certificate = await File('test/fixtures/test-cert.pem').readAsString();
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/test-cert.pem')
      ..usePrivateKey('test/fixtures/test-key.pem');
    listener = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    subscription = listener.listen((socket) {
      sockets.add(socket);
      unawaited(handler(socket));
    });
    return ForwardDescriptor.fromJson({
      'host': '127.0.0.1',
      'port': listener.port,
      'authority': '100.64.0.1:50728',
      'forwardId': 'test-forward',
      'capability': 'test-capability',
      'certificatePem': certificate,
      'sessionEpoch': 'test-session',
    });
  }

  Future<String> header(StreamQueue<List<int>> input) async {
    final bytes = <int>[];
    while (!utf8.decode(bytes).endsWith('\r\n\r\n')) {
      bytes.addAll(await input.next);
    }
    return utf8.decode(bytes);
  }

  setUp(() {
    sockets = {};
    releases = 0;
  });
  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.close();
    await subscription.cancel();
  });

  test('CONNECT split headers preserve coalesced application bytes', () async {
    final request = Completer<String>();
    final forward = await serve((socket) async {
      request.complete(await header(StreamQueue<List<int>>(socket)));
      socket.write('HTTP/1.1 200 Connection');
      await socket.flush();
      socket.write(' Established\r\n\r\nfirst-payload');
      await socket.flush();
    });
    final connection = await connectForward(
      forward,
      release: () async {
        releases++;
      },
    );
    expect(await request.future, contains('CONNECT 100.64.0.1:50728 HTTP/1.1'));
    expect(
      await request.future,
      contains(base64.encode(utf8.encode('test-forward:test-capability'))),
    );
    final data = StreamQueue<List<int>>(connection.incoming);
    expect(utf8.decode(await data.next), 'first-payload');
    await connection.close();
    await connection.close();
    expect(releases, 1);
    await data.cancel(immediate: true);
  });

  test(
    'full duplex byte transport does not replay CONNECT to target',
    () async {
      final forward = await serve((socket) async {
        final input = StreamQueue<List<int>>(socket);
        await header(input);
        socket.write('HTTP/1.1 200 OK\r\n\r\n');
        await socket.flush();
        await for (final bytes in input.rest) {
          socket.add(bytes);
          await socket.flush();
        }
      });
      final connection = await connectForward(
        forward,
        release: () async {
          releases++;
        },
      );
      final received = StreamQueue<List<int>>(connection.incoming);
      final payload = List.generate(128 * 1024, (index) => index % 251);
      connection.outgoing.add(payload);
      final result = <int>[];
      while (result.length < payload.length) {
        result.addAll(await received.next);
      }
      expect(result, payload);
      await connection.close();
      await received.cancel(immediate: true);
      expect(releases, 1);
    },
  );

  test('wrong certificate rejects before sending capability', () async {
    final received = <int>[];
    final forward = await serve((socket) async {
      try {
        await for (final bytes in socket) {
          received.addAll(bytes);
        }
      } catch (_) {}
    });
    final wrong = ForwardDescriptor.fromJson({
      'host': forward.host,
      'port': forward.port,
      'authority': forward.authority,
      'forwardId': forward.forwardId,
      'capability': forward.capability,
      'sessionEpoch': forward.sessionEpoch,
      'certificatePem':
          '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----',
    });
    await expectLater(
      connectForward(
        wrong,
        release: () async {
          releases++;
        },
      ),
      throwsA(
        isA<TailscaleException>().having(
          (e) => e.code,
          'code',
          'serverIdentityMismatch',
        ),
      ),
    );
    expect(received, isEmpty);
    expect(releases, 1);
  });

  test('rejected target never yields a business connection', () async {
    final forward = await serve((socket) async {
      await header(StreamQueue<List<int>>(socket));
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      await socket.flush();
    });
    await expectLater(
      connectForward(
        forward,
        release: () async {
          releases++;
        },
      ),
      throwsA(
        isA<TailscaleException>().having(
          (e) => e.code,
          'code',
          'identityRejected',
        ),
      ),
    );
    expect(releases, 1);
  });

  test('slow handshake times out and releases its native lease', () async {
    final forward = await serve((socket) async {
      await header(StreamQueue<List<int>>(socket));
    });
    await expectLater(
      connectForward(
        forward,
        timeout: const Duration(milliseconds: 100),
        release: () async {
          releases++;
        },
      ),
      throwsA(isA<TailscaleException>()),
    );
    expect(releases, 1);
  });

  test('oversized CONNECT response is bounded', () async {
    final forward = await serve((socket) async {
      await header(StreamQueue<List<int>>(socket));
      socket.write('HTTP/1.1 200 OK\r\nX-Fill: ${'x' * 9000}\r\n\r\n');
      await socket.flush();
    });
    await expectLater(
      connectForward(
        forward,
        release: () async {
          releases++;
        },
      ),
      throwsA(
        isA<TailscaleException>().having(
          (e) => e.code,
          'code',
          'headerTooLarge',
        ),
      ),
    );
    expect(releases, 1);
  });
}
