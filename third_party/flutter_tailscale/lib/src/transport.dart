import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart';

import 'models.dart';

/// One ordered, backpressured byte connection. No RPC retries or replay.
class BridgeConnection {
  BridgeConnection({
    required this.incoming,
    required this.outgoing,
    required Future<void> Function() close,
    required this.done,
  }) : _close = close;
  final Stream<List<int>> incoming;
  final StreamSink<List<int>> outgoing;
  final Future<void> done;
  final Future<void> Function() _close;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();

  static BridgeConnection fromSocket(Socket socket) {
    return BridgeConnection(
      incoming: socket,
      outgoing: socket,
      done: socket.done.then<void>((_) {}, onError: (Object _) {}),
      close: () async {
        socket.destroy();
      },
    );
  }
}

class ForwardDescriptor {
  ForwardDescriptor.fromJson(Map<String, dynamic> json)
    : host = requiredString(json, 'host'),
      port = json['port'] as int,
      authority = requiredString(json, 'authority'),
      forwardId = requiredString(json, 'forwardId'),
      capability = requiredString(json, 'capability'),
      certificatePem = requiredString(json, 'certificatePem'),
      sessionEpoch = requiredString(json, 'sessionEpoch') {
    if (host != '127.0.0.1' ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[\[\]a-zA-Z0-9.:%_-]+$').hasMatch(authority) ||
        forwardId.contains(':') ||
        forwardId.contains('\n')) {
      throw const TailscaleException('invalidForward');
    }
  }
  final String host,
      authority,
      forwardId,
      capability,
      certificatePem,
      sessionEpoch;
  final int port;
}

String certificateDigest(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) throw const TailscaleException('invalidCertificate');
  try {
    return sha256
        .convert(base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')))
        .toString();
  } catch (_) {
    throw const TailscaleException('invalidCertificate');
  }
}

Future<BridgeConnection> connectForward(
  ForwardDescriptor forward, {
  Duration timeout = const Duration(seconds: 25),
  required Future<void> Function() release,
}) async {
  SecureSocket? socket;
  StreamQueue<List<int>>? queue;
  var certificateRejected = false;
  final watch = Stopwatch()..start();
  Duration remaining() {
    final value = timeout - watch.elapsed;
    if (value <= Duration.zero) {
      throw const TailscaleException('connectTimeout');
    }
    return value;
  }

  try {
    final digest = certificateDigest(forward.certificatePem);
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
    socket = await SecureSocket.connect(
      forward.host,
      forward.port,
      context: context,
      timeout: remaining(),
      onBadCertificate: (cert) {
        final valid = sha256.convert(cert.der).toString() == digest;
        certificateRejected = !valid;
        return valid;
      },
    );
    if (socket.peerCertificate == null ||
        sha256.convert(socket.peerCertificate!.der).toString() != digest) {
      throw const TailscaleException('serverIdentityMismatch');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final authorization = base64.encode(
      utf8.encode('${forward.forwardId}:${forward.capability}'),
    );
    socket.write(
      'CONNECT ${forward.authority} HTTP/1.1\r\n'
      'Host: ${forward.authority}\r\n'
      'Proxy-Authorization: Basic $authorization\r\n\r\n',
    );
    await socket.flush().timeout(remaining());
    queue = StreamQueue<List<int>>(socket);
    final header = <int>[];
    List<int> remainder = const [];
    var complete = false;
    while (!complete) {
      if (!await queue.hasNext.timeout(remaining())) {
        throw const TailscaleException('handshakeClosed');
      }
      final chunk = await queue.next.timeout(remaining());
      for (var i = 0; i < chunk.length; i++) {
        header.add(chunk[i]);
        if (header.length > 8192) {
          throw const TailscaleException('headerTooLarge');
        }
        final n = header.length;
        if (n >= 4 &&
            header[n - 4] == 13 &&
            header[n - 3] == 10 &&
            header[n - 2] == 13 &&
            header[n - 1] == 10) {
          remainder = chunk.sublist(i + 1);
          complete = true;
          break;
        }
      }
    }
    final lines = ascii.decode(header).split('\r\n');
    final status = RegExp(
      r'^HTTP/1\.[01] ([0-9]{3})(?: |$)',
    ).firstMatch(lines.first);
    if (status?.group(1) != '200') {
      throw TailscaleException(switch (status?.group(1)) {
        '403' => 'identityRejected',
        '407' => 'localAuthorizationFailed',
        '410' => 'sessionChanged',
        '502' => 'peerUnavailable',
        '503' => 'resourceExhausted',
        _ => 'forwardRejected',
      });
    }
    if (lines
        .skip(1)
        .any(
          (line) =>
              line.toLowerCase().startsWith('transfer-encoding:') ||
              (line.toLowerCase().startsWith('content-length:') &&
                  line.split(':').last.trim() != '0'),
        )) {
      throw const TailscaleException('invalidHandshake');
    }
    final activeSocket = socket;
    final activeQueue = queue;
    final done = Completer<void>();
    var streamTransferred = false;
    Future<void>? closing;
    Future<void> close() => closing ??= () async {
      activeSocket.destroy();
      if (!streamTransferred) await activeQueue.cancel(immediate: true);
      try {
        await release();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }();
    Stream<List<int>> incoming() async* {
      try {
        if (remainder.isNotEmpty) yield remainder;
        streamTransferred = true;
        yield* activeQueue.rest;
      } finally {
        unawaited(close().catchError((_) {}));
      }
    }

    return BridgeConnection(
      incoming: incoming(),
      outgoing: activeSocket,
      done: done.future,
      close: close,
    );
  } catch (error) {
    socket?.destroy();
    await queue?.cancel(immediate: true);
    await release();
    if (error is TailscaleException) rethrow;
    throw TailscaleException(
      certificateRejected
          ? 'serverIdentityMismatch'
          : error is TimeoutException
          ? 'connectTimeout'
          : 'connectionFailed',
    );
  }
}
