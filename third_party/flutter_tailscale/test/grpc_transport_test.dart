import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter_tailscale/grpc.dart';
import 'package:flutter_tailscale/src/grpc_transport.dart';
import 'package:flutter_tailscale/src/models.dart';
import 'package:flutter_tailscale/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:grpc/service_api.dart' as api;

List<int> _bytes(List<int> value) => value;

class _EchoService extends Service {
  _EchoService() {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Unary',
        _unary,
        false,
        false,
        _bytes,
        _bytes,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'ServerStream',
        _server,
        false,
        true,
        _bytes,
        _bytes,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'ClientStream',
        _client,
        true,
        false,
        _bytes,
        _bytes,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Duplex',
        _duplex,
        true,
        true,
        _bytes,
        _bytes,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Slow',
        _slow,
        false,
        false,
        _bytes,
        _bytes,
      ),
    );
  }
  @override
  String get $name => 'test.Echo';
  Future<List<int>> _unary(ServiceCall call, Future<List<int>> request) =>
      request;
  Stream<List<int>> _server(
    ServiceCall call,
    Future<List<int>> request,
  ) async* {
    final bytes = await request;
    for (var i = 0; i < 4; i++) {
      yield [...bytes, i];
    }
  }

  Future<List<int>> _client(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async => requests.fold<List<int>>(
    [],
    (result, request) => result..addAll(request),
  );
  Stream<List<int>> _duplex(ServiceCall call, Stream<List<int>> requests) =>
      requests;
  Future<List<int>> _slow(ServiceCall call, Future<List<int>> request) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return request;
  }
}

class _EchoClient extends api.Client {
  _EchoClient(super.channel);
  api.ClientMethod<List<int>, List<int>> method(String name) =>
      api.ClientMethod('/test.Echo/$name', _bytes, _bytes);
  ResponseFuture<List<int>> unary(List<int> data) =>
      $createUnaryCall(method('Unary'), data);
  ResponseStream<List<int>> stream(String name, Stream<List<int>> requests) =>
      $createStreamingCall(method(name), requests);
  ResponseFuture<List<int>> slow() => $createUnaryCall(method('Slow'), [
    1,
  ], options: CallOptions(timeout: const Duration(milliseconds: 30)));
}

void main() {
  late SecureServerSocket listener;
  late StreamSubscription<SecureSocket> subscription;
  late Server server;
  late ClientTransportConnectorChannel channel;
  late _EchoClient client;
  late Set<Socket> sockets;
  late int opens;
  late int releases;
  late BridgeGrpcConnector connector;
  TailscaleException? pendingFailure;

  setUp(() async {
    sockets = {};
    opens = 0;
    releases = 0;
    pendingFailure = null;
    final certificate = await File(
      'test/fixtures/test-cert.pem',
    ).readAsString();
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/test-cert.pem')
      ..usePrivateKey('test/fixtures/test-key.pem');
    server = Server.create(services: [_EchoService()]);
    listener = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    subscription = listener.listen((socket) async {
      socket.setOption(SocketOption.tcpNoDelay, true);
      sockets.add(socket);
      final input = StreamQueue<List<int>>(socket);
      final header = <int>[];
      while (!utf8.decode(header).endsWith('\r\n\r\n')) {
        header.addAll(await input.next);
      }
      expect(utf8.decode(header), contains('Proxy-Authorization: Basic '));
      socket.write('HTTP/1.1 200 OK\r\n\r\n');
      await socket.flush();
      await serveGrpcConnection(
        server,
        BridgeConnection(
          incoming: input.rest,
          outgoing: socket,
          done: socket.done.then<void>((_) {}),
          close: () async {
            socket.destroy();
          },
        ),
      );
    });
    connector = BridgeGrpcConnector(() async {
      if (pendingFailure != null) throw pendingFailure!;
      opens++;
      return connectForward(
        ForwardDescriptor.fromJson({
          'host': '127.0.0.1',
          'port': listener.port,
          'authority': '100.64.0.1:50728',
          'forwardId': 'grpc-test',
          'capability': 'grpc-test-capability',
          'sessionEpoch': 'grpc-test-session',
          'certificatePem': certificate,
        }),
        release: () async {
          releases++;
        },
      );
    }, authority: 'tailscale:50728');
    channel = ClientTransportConnectorChannel(
      connector,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    client = _EchoClient(channel);
  });

  tearDown(() async {
    await channel.terminate();
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.close();
    await subscription.cancel();
    await server.shutdown();
  });

  test(
    'typed connector rejection survives gRPC unavailable wrapping',
    () async {
      pendingFailure = const TailscaleException('identityRejected');
      await expectLater(
        client.unary([1]),
        throwsA(
          isA<GrpcError>().having(
            (e) => e.code,
            'code',
            StatusCode.unavailable,
          ),
        ),
      );
      expect(connector.lastConnectionFailure?.code, 'identityRejected');
      pendingFailure = null;
      expect(await client.unary([2]), [2]);
      expect(connector.lastConnectionFailure, isNull);
    },
  );

  test('unary and all streaming modes share authenticated HTTP/2', () async {
    expect(await client.unary([1, 2, 3]), [1, 2, 3]);
    expect(await client.stream('ServerStream', Stream.value([4])).toList(), [
      [4, 0],
      [4, 1],
      [4, 2],
      [4, 3],
    ]);
    expect(
      await client
          .stream(
            'ClientStream',
            Stream.fromIterable([
              [1],
              [2],
              [3],
            ]),
          )
          .single,
      [1, 2, 3],
    );
    final requests = StreamController<List<int>>();
    final responses = StreamQueue<List<int>>(
      client.stream('Duplex', requests.stream),
    );
    requests.add([5]);
    expect(await responses.next, [5]);
    requests.add([6]);
    expect(await responses.next, [6]);
    await requests.close();
    expect(await responses.hasNext, isFalse);
    expect(opens, 1);
  });

  test(
    'RPC cancellation and deadline are visible and new calls can recover',
    () async {
      expect(await client.unary([0]), [0]);
      await expectLater(
        client.slow(),
        throwsA(
          isA<GrpcError>().having(
            (e) => e.code,
            'code',
            StatusCode.deadlineExceeded,
          ),
        ),
      );
      // grpc 4.2/http2 2.3.1 can close a transport if deadline trailers cross a
      // client RST. Let that close propagate before testing a fresh operation;
      // the adapter never replays an in-flight application RPC.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final requests = StreamController<List<int>>();
      final response = client.stream('Duplex', requests.stream);
      final received = StreamQueue<List<int>>(response);
      requests.add([1]);
      expect(await received.next, [1]);
      await response.cancel();
      await received.cancel(immediate: true);
      await requests.close();
      expect(await client.unary([9]), [9]);
      expect(opens, greaterThanOrEqualTo(1));
    },
  );

  test(
    'closing transport frees lease and a fresh RPC establishes a new tunnel',
    () async {
      expect(await client.unary([0]), [0]);
      for (final socket in sockets) {
        socket.destroy();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await client.unary([7]), [7]);
      expect(opens, 2);
      expect(releases, 1);
    },
  );
}
